#!/usr/bin/env bash
# One-command DISASTER RECOVERY for the nextcloud-stack chart.
#
# Turns a bare cluster (or empty namespace) + a backup archive into a working,
# restored Nextcloud in a SINGLE command. It orchestrates the pieces you would
# otherwise run by hand — and reuses the chart's existing, tested restore engine
# (files/backup.sh MODE=restore) verbatim, so no restore logic is duplicated:
#
#   1. re-attach the off-cluster backup archive  (static NFS PV -> PVC)
#   2. bootstrap Secrets                          (scripts/bootstrap-secrets.sh)
#   3. helm install/upgrade the chart  --wait     (postgres + nextcloud healthy)
#   4. health gate                                (rollout + pg_isready)
#   5. run the existing restore Job               (clone the backup CronJob,
#                                                  MODE=restore, initContainers
#                                                  stripped — nothing to dump)
#   6. print post-restore login guidance
#
# It is IDEMPOTENT: re-running converges (existing Secrets are skipped, helm
# upgrades in place, a new timestamped restore Job is created). The static PV is
# reclaimPolicy:Retain, so tearing DR objects down NEVER deletes NFS data; the
# restore opens the archive read-only.
#
# Prereqs on the workstation: kubectl, helm, jq, a kubeconfig, this chart repo,
# and the backup archive reachable on the NAS (default) or a copy you point at.
# You do NOT need the OLD instance's secrets: bootstrap-secrets.sh generates
# fresh ones, the restore converges DB creds to them, and the backed-up
# instanceid/secret/passwordsalt (which key encryption + sessions) ride in from
# the archive.
#
# Usage:
#   scripts/dr-restore.sh --values <captured-values.yaml> [options]
#
# Options:
#   --values PATH        (required) the captured install values overlay
#                        (e.g. .redeploy-state/nextcloud-install-values.yaml)
#   --archive NAME       backup-<TS>.tar | latest        (default: latest)
#   --namespace NS       (default: nextcloud)
#   --release REL        (default: nextcloud-stack)
#   --backup-claim NAME  PVC to bind the archive to      (default: nextcloud-backups)
#   --server HOST        NFS server holding the archive  (default: 10.0.0.13)
#   --share PATH         NFS export                      (default: /mnt/datapool/Shares/k3s)
#   --subdir NAME        subdir under the export         (default: nextcloud-backups)
#   --whiteboard         forwarded to bootstrap-secrets.sh
#   --metrics            forwarded to bootstrap-secrets.sh
#   --cloudflare-token T forwarded to bootstrap-secrets.sh (never logged)
#   --skip-bootstrap     Secrets already exist; don't run bootstrap-secrets.sh
#   --force-rebind       rebind --backup-claim even if bound to another volume
#   --kubeconfig PATH    export KUBECONFIG
#   --dry-run            print every mutating command without running it
#   -h | --help
#
# Example (production defaults — namespace nextcloud, release nextcloud-stack,
# primary NAS 10.0.0.13):
#   scripts/dr-restore.sh \
#     --values ~/claude/kubernetes/.redeploy-state/nextcloud-install-values.yaml \
#     --whiteboard --metrics

set -euo pipefail

VALUES=""
ARCHIVE="latest"
NAMESPACE="nextcloud"
RELEASE="nextcloud-stack"
BACKUP_CLAIM="nextcloud-backups"
NFS_SERVER="10.0.0.13"
NFS_SHARE="/mnt/datapool/Shares/k3s"
NFS_SUBDIR="nextcloud-backups"
WB=0
MET=0
CF_TOKEN=""
SKIP_BOOTSTRAP=0
FORCE_REBIND=0
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --values)        VALUES="$2"; shift 2 ;;
    --archive)       ARCHIVE="$2"; shift 2 ;;
    -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
    -r|--release)    RELEASE="$2"; shift 2 ;;
    --backup-claim)  BACKUP_CLAIM="$2"; shift 2 ;;
    --server)        NFS_SERVER="$2"; shift 2 ;;
    --share)         NFS_SHARE="$2"; shift 2 ;;
    --subdir)        NFS_SUBDIR="$2"; shift 2 ;;
    --whiteboard)    WB=1; shift ;;
    --metrics)       MET=1; shift ;;
    --cloudflare-token) CF_TOKEN="$2"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
    --force-rebind)  FORCE_REBIND=1; shift ;;
    --kubeconfig)    export KUBECONFIG="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) echo "Unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done

log()  { echo "[dr-restore] $*"; }
fail() { echo "[dr-restore] ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"; }
# Run (or, under --dry-run, just print) a mutating command, time-bounded.
run()  { if [[ "$DRY_RUN" -eq 1 ]]; then echo "    + $*"; else timeout 900 "$@"; fi; }
kc()   { kubectl -n "$NAMESPACE" "$@"; }

# ---- 0. preflight ----------------------------------------------------------
need kubectl; need helm; need jq
[[ -n "$VALUES" ]] || fail "--values is required (the captured install values overlay)"
[[ -f "$VALUES" ]] || fail "values file not found: $VALUES"
[[ -f "$CHART_ROOT/Chart.yaml" ]] || fail "chart not found at $CHART_ROOT (run this from the chart's scripts/ dir)"
[[ -f "$CHART_ROOT/files/backup.sh" ]] || fail "$CHART_ROOT/files/backup.sh missing — wrong chart dir?"
kubectl version --request-timeout=15s >/dev/null 2>&1 || fail "cannot reach the cluster (check --kubeconfig / KUBECONFIG)"

PV_NAME="${RELEASE}-backups-dr"
# nfs.csi.k8s.io volumeHandle format: server#share-without-leading-slash#subDir#pvName#
SHARE_NOSLASH="${NFS_SHARE#/}"
VOL_HANDLE="${NFS_SERVER}#${SHARE_NOSLASH}#${NFS_SUBDIR}#${PV_NAME}#"

log "plan:"
log "  namespace=$NAMESPACE release=$RELEASE values=$VALUES"
log "  archive=$ARCHIVE  source=nfs://$NFS_SERVER$NFS_SHARE/$NFS_SUBDIR -> pvc/$BACKUP_CLAIM"
log "  bootstrap=$([[ $SKIP_BOOTSTRAP -eq 1 ]] && echo skip || echo yes)  dry-run=$DRY_RUN"

# ---- 1. namespace ----------------------------------------------------------
if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  log "creating namespace $NAMESPACE"
  run kubectl create namespace "$NAMESPACE"
fi

# ---- 2. re-attach the off-cluster archive (static NFS PV + PVC) ------------
# Guard: if the claim already exists bound to a DIFFERENT volume, don't hijack
# it (could be a live backup PVC) unless --force-rebind.
EXIST_VOL="$(kc get pvc "$BACKUP_CLAIM" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
if [[ -n "$EXIST_VOL" && "$EXIST_VOL" != "$PV_NAME" && "$FORCE_REBIND" -ne 1 ]]; then
  fail "pvc/$BACKUP_CLAIM already bound to '$EXIST_VOL' (not the DR PV). Re-run with --force-rebind to replace it, or pass a different --backup-claim."
fi
if [[ -n "$EXIST_VOL" && "$EXIST_VOL" != "$PV_NAME" && "$FORCE_REBIND" -eq 1 ]]; then
  log "[force-rebind] deleting pvc/$BACKUP_CLAIM (bound to $EXIST_VOL) — NFS data is untouched (Retain)"
  run kc delete pvc "$BACKUP_CLAIM"
fi

log "re-attaching archive: PV/$PV_NAME -> pvc/$BACKUP_CLAIM (Retain, read of NFS dir only)"
MANIFEST="$(cat <<YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
  labels:
    app.kubernetes.io/managed-by: dr-restore.sh
spec:
  capacity:
    storage: 100Gi
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions: ["nfsvers=4.1", "hard", "timeo=600", "retrans=2"]
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: "${VOL_HANDLE}"
    volumeAttributes:
      server: "${NFS_SERVER}"
      share: "${NFS_SHARE}"
      subDir: "${NFS_SUBDIR}"
  claimRef:
    namespace: ${NAMESPACE}
    name: ${BACKUP_CLAIM}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${BACKUP_CLAIM}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: dr-restore.sh
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  resources:
    requests:
      storage: 100Gi
  volumeName: ${PV_NAME}
YAML
)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "    + kubectl apply -f - <<'EOF'"; echo "$MANIFEST" | sed 's/^/      /'; echo "      EOF"
else
  echo "$MANIFEST" | kubectl apply -f -
  kc wait --for=jsonpath='{.status.phase}'=Bound "pvc/$BACKUP_CLAIM" --timeout=120s
fi

# ---- 3. Secrets (delegate; idempotent) -------------------------------------
if [[ "$SKIP_BOOTSTRAP" -eq 1 ]]; then
  log "skipping bootstrap-secrets.sh (--skip-bootstrap); verifying Secrets exist"
  if [[ "$DRY_RUN" -ne 1 ]]; then
    kc get secret "${RELEASE}-admin" >/dev/null 2>&1 || fail "Secret ${RELEASE}-admin missing — drop --skip-bootstrap"
    kc get secret "${RELEASE}-postgres" >/dev/null 2>&1 || fail "Secret ${RELEASE}-postgres missing — drop --skip-bootstrap"
  fi
else
  log "bootstrapping Secrets (existing ones are left untouched)"
  BS_ARGS=(--namespace "$NAMESPACE" --release "$RELEASE")
  [[ "$WB" -eq 1 ]] && BS_ARGS+=(--whiteboard)
  [[ "$MET" -eq 1 ]] && BS_ARGS+=(--metrics)
  [[ -n "$CF_TOKEN" ]] && BS_ARGS+=(--cloudflare-token "$CF_TOKEN")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "    + $SCRIPT_DIR/bootstrap-secrets.sh ${BS_ARGS[*]/--cloudflare-token */--cloudflare-token ***}"
  else
    "$SCRIPT_DIR/bootstrap-secrets.sh" "${BS_ARGS[@]}"
  fi
fi

# ---- 4. install / upgrade the chart ----------------------------------------
HELM_ACTION=install
helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 && HELM_ACTION=upgrade
log "helm $HELM_ACTION $RELEASE (--wait; blocks on postgres + nextcloud + db-migrate hook)"
run helm "$HELM_ACTION" "$RELEASE" "$CHART_ROOT" -n "$NAMESPACE" \
  -f "$VALUES" \
  --set backup.enabled=true \
  --set backup.persistence.existingClaim="$BACKUP_CLAIM" \
  --wait --timeout 15m

# ---- 5. health gate (restore execs BOTH pods, so prove both are up) --------
if [[ "$DRY_RUN" -ne 1 ]]; then
  log "waiting for nextcloud + postgres to be ready"
  kc rollout status "deploy/$RELEASE" --timeout=300s
  kc exec "${RELEASE}-postgres-0" -c postgres -- pg_isready -h 127.0.0.1 >/dev/null \
    || fail "postgres not ready"
fi

# ---- 6. run the EXISTING restore engine (clone the backup CronJob) ---------
# Strip initContainers (the pg-dump init has nothing to dump on a restore) and
# inject MODE=restore + RESTORE_ARCHIVE. This is the documented restore Job,
# just parameterized and wrapped.
JOB="dr-restore-$(date +%s)"
log "launching restore Job $JOB (archive=$ARCHIVE)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "    + kubectl -n $NAMESPACE create job $JOB --from=cronjob/${RELEASE}-backup ... (MODE=restore, RESTORE_ARCHIVE=$ARCHIVE, initContainers stripped)"
else
  kc create job "$JOB" --from="cronjob/${RELEASE}-backup" --dry-run=client -o json \
    | jq --arg a "$ARCHIVE" '
        del(.spec.template.spec.initContainers)
        | .spec.template.spec.containers[0].env += [
            {"name":"MODE","value":"restore"},
            {"name":"RESTORE_ARCHIVE","value":$a}]' \
    | kc create -f -
  # stream the restore log, then gate on the Job result
  kc wait --for=condition=Ready "pod" -l "job-name=$JOB" --timeout=120s 2>/dev/null || true
  kc logs -f "job/$JOB" || true
  if kc wait --for=condition=complete "job/$JOB" --timeout=20m 2>/dev/null; then
    log "restore Job completed"
  else
    kc logs "job/$JOB" --tail=40 || true
    fail "restore Job did not complete — see logs above and docs/restore.md (the DB is untouched on a file-verify failure, so it is safe to re-run)"
  fi
  # Best-effort schema reconcile: the pod boot already auto-runs occ upgrade on
  # a version skew; this is a harmless no-op when the versions match.
  kc exec "deploy/$RELEASE" -c php -- php /var/www/html/occ upgrade --no-interaction >/dev/null 2>&1 || true
fi

# ---- 7. report -------------------------------------------------------------
cat <<EOF

====================================================================
[dr-restore] DR RESTORE COMPLETE — $RELEASE in namespace $NAMESPACE

Users sign in via authentik (external SSO); those accounts came back with the
restored database and work immediately.

LOCAL admin account:
  • 'admin' is the BACKED-UP instance's local admin — its password is whatever
    it was at backup time, NOT the fresh password bootstrap-secrets.sh printed
    above (that was overwritten by the restore).
  • Lost it? Reset:
      kubectl -n $NAMESPACE exec deploy/$RELEASE -c php -- \\
        php /var/www/html/occ user:resetpassword admin

authentik is a SEPARATE release — restore it from its own backup if the whole
cluster was lost. Tear down DR-only objects later with (NFS data is safe):
  kubectl -n $NAMESPACE delete pvc $BACKUP_CLAIM   # only if you want a fresh dynamic backup PVC
  kubectl delete pv $PV_NAME
====================================================================
EOF
