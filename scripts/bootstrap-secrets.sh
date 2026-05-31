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
#                        [--whiteboard] [--metrics]
#
# Defaults:
#   --namespace nextcloud
#   --release   nextcloud-stack
#
# Secrets created (names follow the chart's `existingSecret` convention):
#   <release>-admin       keys: admin-user, admin-password
#   <release>-postgres    keys: nextcloud-db-password
#   <release>-valkey      keys: valkey-password, valkey.conf
#   <release>-whiteboard  keys: jwt-secret-key, redis-url   (only with --whiteboard)
#   <release>-metrics     key:  token   (only with --metrics)
#   <release>-cloudflared key:  tunnel-token   (only with --cloudflare-token)
#
# Admin password is printed once at the end — save it in your password manager.

set -euo pipefail

NAMESPACE="nextcloud"
RELEASE="nextcloud-stack"
FORCE=0
CF_TOKEN=""
WB=0
MET=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    --force)        FORCE=1; shift ;;
    --cloudflare-token) CF_TOKEN="$2"; shift 2 ;;
    --whiteboard)   WB=1; shift ;;
    --metrics)      MET=1; shift ;;
    --kubeconfig)   export KUBECONFIG="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,/^set -euo/p' "$0" | sed '$d'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

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

ensure_ns

ADMIN_PW="$(gen_pw 32)"
PG_PW="$(gen_pw 32)"
VALKEY_PW="$(gen_pw 32)"
WB_JWT="$(gen_pw 48)"
MET_TOKEN="$(gen_pw 48)"

# Valkey config with requirepass baked in. Mirror of templates/valkey/secret.yaml
# (the chart no longer renders that template — see SECRET note in values.yaml).
# `bind 0.0.0.0 -::` listens on IPv4-wildcard, optionally on IPv6 (the `-`
# prefix marks the address as "may fail to bind"). The cluster is IPv4-only
# via the pod CIDR, so v6 won't bind and that's fine.
VALKEY_CONF="$(cat <<EOF
bind 0.0.0.0 -::
port 6379
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
printf "%s" "$VALKEY_PW"    > "$TMP/valkey-password"
printf "%s" "$VALKEY_CONF"  > "$TMP/valkey.conf"

create_or_skip "${RELEASE}-admin" \
  --from-file=admin-user="$TMP/admin-user" \
  --from-file=admin-password="$TMP/admin-password"

create_or_skip "${RELEASE}-postgres" \
  --from-file=nextcloud-db-password="$TMP/nextcloud-db-password"

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
  printf "redis://:%s@%s-valkey:6379/1" "$VALKEY_PW_EFF" "$RELEASE" > "$TMP/redis-url"
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

# Cloudflare tunnel token (optional) — consumed by cloudflare.tunnel.existingSecret.
if [[ -n "$CF_TOKEN" ]]; then
  printf "%s" "$CF_TOKEN" > "$TMP/tunnel-token"
  create_or_skip "${RELEASE}-cloudflared" \
    --from-file=tunnel-token="$TMP/tunnel-token"
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
