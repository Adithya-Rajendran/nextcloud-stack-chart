#!/usr/bin/env bash
# Pre-create the three Secrets the nextcloud-stack chart references via
# `*.auth.existingSecret`. Run this ONCE before `helm install`. Subsequent
# runs are idempotent: existing Secrets are left alone unless --force is
# passed.
#
# Generated passwords use a YAML/PG/Redis-safe alphabet (alnum + a few
# non-special symbols), 32 chars.
#
# Usage:
#   bootstrap-secrets.sh [--namespace NS] [--release RELEASE] [--force]
#                        [--kubeconfig PATH] [--cloudflare-token TOKEN]
#                        [--whiteboard] [--metrics] [--sso]
#                        [--dhi-username USER --dhi-token PAT [--dhi-email E]
#                         [--dhi-server dhi.io] [--dhi-secret-name dhi-pull]]
#                        [--name-override NAME | --fullname-override FULLNAME]
#                        [--valkey-port 6379]
#
# Defaults:
#   --namespace nextcloud
#   --release   nextcloud-stack
#
# Secrets created (names follow the chart's `existingSecret` convention):
#   <release>-admin       keys: admin-user, admin-password
#   <release>-postgres    keys: nextcloud-db-password (app role),
#                               postgres-admin-password (the `postgres` superuser,
#                               used by postgres.auth.manageAppRole). Re-running
#                               this script PATCHES the admin key into an existing
#                               Secret that predates it (chart <= 0.4 upgrade path).
#   <release>-valkey      keys: valkey-password, valkey.conf
#   <release>-whiteboard  keys: jwt-secret-key, redis-url   (only with --whiteboard)
#   <release>-metrics     key:  token   (only with --metrics)
#   <release>-sso         keys: client-id, client-secret   (only with --sso)
#   <release>-cloudflared key:  tunnel-token   (only with --cloudflare-token)
#   dhi-pull              docker-registry cred for dhi.io  (only with --dhi-username)
#
# --dhi-username/--dhi-token create the imagePullSecret the default DHI images
# need (a FREE Docker account is enough). Reference it via imagePullSecrets in
# your values, e.g. `imagePullSecrets: [{name: dhi-pull}]`.
#
# SAFETY: --force ROTATES every password. On a LIVE release this desyncs Postgres
# (the DB still holds the old password) and breaks auth — the script refuses
# unless the workload is absent (e.g. after `helm uninstall`) or you also pass
# --allow-live-rotation. See README "Secret rotation" for the safe live path.
#
# Admin password is printed once at the end — save it in your password manager.

set -euo pipefail

NAMESPACE="nextcloud"
RELEASE="nextcloud-stack"
FORCE=0
ALLOW_LIVE_ROTATION=0
CF_TOKEN=""
WB=0
MET=0
SSO=0
# DHI imagePullSecret (default images live on dhi.io — a FREE Docker account).
DHI_USER=""
DHI_TOKEN=""
DHI_EMAIL=""
DHI_SERVER="dhi.io"
DHI_SECRET_NAME="dhi-pull"
# Chart naming (mirror templates/_helpers.tpl "nextcloud-stack.fullname"). Only
# the valkey host embedded in the whiteboard redis-url is chart-name-derived.
CHART_NAME="nextcloud-stack"
NAME_OVERRIDE=""
FULLNAME_OVERRIDE=""
VALKEY_PORT="6379"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    --force)        FORCE=1; shift ;;
    --allow-live-rotation) ALLOW_LIVE_ROTATION=1; shift ;;
    --cloudflare-token) CF_TOKEN="$2"; shift 2 ;;
    --whiteboard)   WB=1; shift ;;
    --metrics)      MET=1; shift ;;
    --sso)          SSO=1; shift ;;
    --dhi-username) DHI_USER="$2"; shift 2 ;;
    --dhi-token)    DHI_TOKEN="$2"; shift 2 ;;
    --dhi-email)    DHI_EMAIL="$2"; shift 2 ;;
    --dhi-server)   DHI_SERVER="$2"; shift 2 ;;
    --dhi-secret-name) DHI_SECRET_NAME="$2"; shift 2 ;;
    --name-override)     NAME_OVERRIDE="$2"; shift 2 ;;
    --fullname-override) FULLNAME_OVERRIDE="$2"; shift 2 ;;
    --valkey-port)  VALKEY_PORT="$2"; shift 2 ;;
    --kubeconfig)   export KUBECONFIG="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,/^set -euo/p' "$0" | sed '$d'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Resolve the chart's fullname the way templates/_helpers.tpl does, so the valkey
# Service host baked into the whiteboard redis-url is correct for ANY release name
# (not just ones that already contain "nextcloud-stack").
compute_fullname() {
  if [[ -n "$FULLNAME_OVERRIDE" ]]; then printf '%s' "$FULLNAME_OVERRIDE"; return; fi
  local name="${NAME_OVERRIDE:-$CHART_NAME}"
  if [[ "$RELEASE" == *"$name"* ]]; then printf '%s' "$RELEASE"; else printf '%s-%s' "$RELEASE" "$name"; fi
}
FULLNAME="$(compute_fullname)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need kubectl
need tr

# SIGPIPE-tolerant 32-char password generator.
# tr/head pipeline trips set -euo pipefail when head closes the pipe early;
# wrapping in a subshell with pipefail disabled keeps the script alive.
gen_pw() {
  local len="${1:-32}"
  ( set +o pipefail
    LC_ALL=C tr -dc 'A-Za-z0-9_\-.~+=' < /dev/urandom 2>/dev/null \
      | head -c "$len" )
}

ensure_ns() {
  if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    echo "Creating namespace $NAMESPACE"
    kubectl create ns "$NAMESPACE"
  fi
}

secret_exists() {
  kubectl -n "$NAMESPACE" get secret "$1" >/dev/null 2>&1
}

create_or_skip() {
  local name="$1"; shift
  if secret_exists "$name"; then
    if [[ "$FORCE" -eq 1 ]]; then
      echo "[force] Replacing Secret/$name"
      kubectl -n "$NAMESPACE" delete secret "$name"
    else
      echo "[skip ] Secret/$name already exists (use --force to overwrite)"
      return 0
    fi
  fi
  kubectl -n "$NAMESPACE" create secret generic "$name" "$@"
  echo "[ok   ] Secret/$name created"
}

# Add a key to an EXISTING Secret if (and only if) it's missing — never touches
# present values. Upgrade path for keys introduced after the Secret was created
# (e.g. postgres-admin-password on installs bootstrapped with chart <= 0.4).
ensure_secret_key() {
  local name="$1" key="$2" file="$3" cur b64
  secret_exists "$name" || return 0
  cur="$(kubectl -n "$NAMESPACE" get secret "$name" -o jsonpath="{.data['$key']}" 2>/dev/null || true)"
  [[ -n "$cur" ]] && return 0
  b64="$(base64 < "$file" | tr -d '\n')"
  kubectl -n "$NAMESPACE" patch secret "$name" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/data/$key\",\"value\":\"$b64\"}]" >/dev/null
  echo "[patch] Secret/$name: added missing key $key"
}

ensure_ns

# --force rotates every password. If the release is LIVE (its workload exists),
# rotating the DB password here desyncs Postgres (the running DB keeps the old
# password) and breaks auth. Refuse unless the operator explicitly opts in.
if [[ "$FORCE" -eq 1 && "$ALLOW_LIVE_ROTATION" -eq 0 ]]; then
  if kubectl -n "$NAMESPACE" get statefulset "${RELEASE}-postgres" >/dev/null 2>&1 \
     || kubectl -n "$NAMESPACE" get deploy "$FULLNAME" >/dev/null 2>&1; then
    cat >&2 <<EOF
REFUSING --force: a live '$RELEASE' workload exists in namespace '$NAMESPACE'.
--force regenerates ALL passwords, but the running Postgres still holds the old
one, so Nextcloud would fail to authenticate after you restart it.

Safe options:
  * Rotate a single credential the documented way (README "Secret rotation").
  * For a from-scratch reset (e.g. postgres major upgrade), 'helm uninstall'
    first (the workload goes away), then re-run with --force.
  * If you REALLY mean to rotate every secret on a live release and will fix the
    DB/app yourself, re-run with --force --allow-live-rotation.
EOF
    exit 3
  fi
fi

ADMIN_PW="$(gen_pw 32)"
PG_PW="$(gen_pw 32)"
PG_ADMIN_PW="$(gen_pw 32)"
VALKEY_PW="$(gen_pw 32)"
WB_JWT="$(gen_pw 48)"
MET_TOKEN="$(gen_pw 48)"
SSO_SECRET="$(gen_pw 48)"

# Valkey config with requirepass baked in. Mirror of templates/valkey/secret.yaml
# (the chart no longer renders that template — see SECRET note in values.yaml).
# `bind 0.0.0.0 -::` listens on IPv4-wildcard, optionally on IPv6 (the `-`
# prefix marks the address as "may fail to bind"). The cluster is IPv4-only
# via the pod CIDR, so v6 won't bind and that's fine.
VALKEY_CONF="$(cat <<EOF
bind 0.0.0.0 -::
port $VALKEY_PORT
protected-mode yes
requirepass $VALKEY_PW
save ""
appendonly no
maxmemory 256mb
maxmemory-policy allkeys-lru
loglevel notice
timeout 0
tcp-keepalive 60
databases 16
EOF
)"

TMP="$(mktemp -d)"; trap "rm -rf $TMP" EXIT
chmod 700 "$TMP"
printf "%s" "admin"         > "$TMP/admin-user"
printf "%s" "$ADMIN_PW"     > "$TMP/admin-password"
printf "%s" "$PG_PW"        > "$TMP/nextcloud-db-password"
printf "%s" "$PG_ADMIN_PW"  > "$TMP/postgres-admin-password"
printf "%s" "$VALKEY_PW"    > "$TMP/valkey-password"
printf "%s" "$VALKEY_CONF"  > "$TMP/valkey.conf"

create_or_skip "${RELEASE}-admin" \
  --from-file=admin-user="$TMP/admin-user" \
  --from-file=admin-password="$TMP/admin-password"

create_or_skip "${RELEASE}-postgres" \
  --from-file=nextcloud-db-password="$TMP/nextcloud-db-password" \
  --from-file=postgres-admin-password="$TMP/postgres-admin-password"
# Chart <= 0.4 Secrets predate the admin key; add it without touching the rest.
ensure_secret_key "${RELEASE}-postgres" postgres-admin-password "$TMP/postgres-admin-password"

create_or_skip "${RELEASE}-valkey" \
  --from-file=valkey-password="$TMP/valkey-password" \
  --from-file=valkey.conf="$TMP/valkey.conf"

# Whiteboard (optional) — consumed by whiteboard.auth.existingSecret.
# jwt-secret-key is shared with Nextcloud (the db-migrate Job sets it via occ).
# redis-url embeds the EFFECTIVE valkey password (the one actually in the Secret,
# not a freshly-generated one — matters on a non-force re-run where valkey is skipped).
if [[ "$WB" -eq 1 ]]; then
  VALKEY_PW_EFF=$(kubectl -n "$NAMESPACE" get secret "${RELEASE}-valkey" \
    -o jsonpath='{.data.valkey-password}' 2>/dev/null | base64 -d || true)
  VALKEY_PW_EFF="${VALKEY_PW_EFF:-$VALKEY_PW}"
  printf "%s" "$WB_JWT" > "$TMP/jwt-secret-key"
  # Host = the chart's valkey Service (<fullname>-valkey), port from --valkey-port.
  printf "redis://:%s@%s-valkey:%s/1" "$VALKEY_PW_EFF" "$FULLNAME" "$VALKEY_PORT" > "$TMP/redis-url"
  create_or_skip "${RELEASE}-whiteboard" \
    --from-file=jwt-secret-key="$TMP/jwt-secret-key" \
    --from-file=redis-url="$TMP/redis-url"
fi

# Metrics serverinfo token (optional) — consumed by metrics.auth.existingSecret.
# The exporter sends it as NC-Token; the db-migrate Job writes the SAME value
# into Nextcloud via `occ config:app:set serverinfo token`.
if [[ "$MET" -eq 1 ]]; then
  printf "%s" "$MET_TOKEN" > "$TMP/token"
  create_or_skip "${RELEASE}-metrics" \
    --from-file=token="$TMP/token"
fi

# SSO / OIDC client credentials (optional) — consumed by sso.auth.existingSecret.
# client-id defaults to "nextcloud"; register the SAME id/secret at your IdP
# (e.g. an authentik OAuth2 provider blueprint reading the secret via !Env).
if [[ "$SSO" -eq 1 ]]; then
  printf "%s" "nextcloud"   > "$TMP/client-id"
  printf "%s" "$SSO_SECRET" > "$TMP/client-secret"
  create_or_skip "${RELEASE}-sso" \
    --from-file=client-id="$TMP/client-id" \
    --from-file=client-secret="$TMP/client-secret"
fi

# Cloudflare tunnel token (optional) — consumed by cloudflare.tunnel.existingSecret.
if [[ -n "$CF_TOKEN" ]]; then
  printf "%s" "$CF_TOKEN" > "$TMP/tunnel-token"
  create_or_skip "${RELEASE}-cloudflared" \
    --from-file=tunnel-token="$TMP/tunnel-token"
fi

# DHI imagePullSecret (optional) — the default images live on dhi.io, which needs
# a docker-registry credential (a FREE Docker account is enough). Reference the
# resulting Secret via imagePullSecrets in your values.
if [[ -n "$DHI_USER" || -n "$DHI_TOKEN" ]]; then
  if [[ -z "$DHI_USER" || -z "$DHI_TOKEN" ]]; then
    echo "--dhi-username and --dhi-token must be given together" >&2; exit 2
  fi
  if secret_exists "$DHI_SECRET_NAME" && [[ "$FORCE" -eq 0 ]]; then
    echo "[skip ] Secret/$DHI_SECRET_NAME already exists (use --force to overwrite)"
  else
    secret_exists "$DHI_SECRET_NAME" && kubectl -n "$NAMESPACE" delete secret "$DHI_SECRET_NAME"
    kubectl -n "$NAMESPACE" create secret docker-registry "$DHI_SECRET_NAME" \
      --docker-server="$DHI_SERVER" \
      --docker-username="$DHI_USER" \
      --docker-password="$DHI_TOKEN" \
      ${DHI_EMAIL:+--docker-email="$DHI_EMAIL"}
    echo "[ok   ] Secret/$DHI_SECRET_NAME (docker-registry for $DHI_SERVER) created"
    echo "        Reference it: imagePullSecrets: [{name: $DHI_SECRET_NAME}]"
  fi
fi

cat <<EOF

====================================================================
Secrets created in namespace $NAMESPACE.

ADMIN PASSWORD (save in password manager NOW — only shown once):
  Username: admin
  Password: $ADMIN_PW

Re-read it later with:
  kubectl -n $NAMESPACE get secret ${RELEASE}-admin \\
    -o jsonpath='{.data.admin-password}' | base64 -d
====================================================================
EOF
