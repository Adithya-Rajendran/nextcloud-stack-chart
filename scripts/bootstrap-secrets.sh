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
#                        [--kubeconfig PATH]
#
# Defaults:
#   --namespace aio-test
#   --release   nextcloud-stack
#
# Secrets created (names follow the chart's `existingSecret` convention):
#   <release>-admin     keys: admin-user, admin-password
#   <release>-postgres  keys: nextcloud-db-password
#   <release>-valkey    keys: valkey-password, valkey.conf
#
# Admin password is printed once at the end — save it in your password manager.

set -euo pipefail

NAMESPACE="aio-test"
RELEASE="nextcloud-stack"
FORCE=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    --force)        FORCE=1; shift ;;
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

# Valkey config with requirepass baked in. Mirror of templates/valkey/secret.yaml
# (the chart no longer renders that template — see SECRET note in values.yaml).
VALKEY_CONF="$(cat <<EOF
bind 0.0.0.0 -::*
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
