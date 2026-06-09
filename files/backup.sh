#!/bin/sh
# Backs up Postgres (pg_dumpall) + the Nextcloud data/config to /backup (a PVC,
# e.g. off-cluster NFS). Runs as a non-root CronJob that `kubectl exec`s into the
# live Pods, so it never multi-attaches the RWO PVCs. Dynamic values come from
# env (set by the CronJob): PG_POD, NC_DEPLOY, BACKUP_NS, PG_ENABLED,
# RETENTION_DAYS, MAINTENANCE_MODE.
set -u
# pipefail where the shell has it (busybox ash, bash); the content-based dump
# verification below covers shells that don't. The subshell PROBE matters: a
# failed bare `set -o pipefail` is a special-builtin error that ABORTS some
# POSIX shells (dash) even with `|| true` — and with exit status 0, i.e. a
# backup job that "succeeds" having done nothing.
(set -o pipefail) 2>/dev/null && set -o pipefail || true
export HOME=/tmp
TS=$(date -u +%Y%m%d-%H%M%S)
PGDIR=/backup/postgres
NCDIR=/backup/nextcloud
mkdir -p "$PGDIR" "$NCDIR"
echo "[$(date -u)] === backup $TS start ==="

# ---- optional maintenance mode (MAINTENANCE_MODE=true) ----------------------
# Freezes writes for the duration of the run so the DB dump and the files tar
# are one consistent point in time (what the Nextcloud manual recommends).
# Costs user-facing downtime for the length of the backup. The trap guarantees
# maintenance mode comes back OFF on ANY exit path, success or failure.
MM_ON=0
occ() { kubectl exec -n "$BACKUP_NS" "deploy/$NC_DEPLOY" -c php -- php /var/www/html/occ "$@"; }
mm_off() {
  if [ "$MM_ON" = 1 ]; then
    occ maintenance:mode --off || echo "WARNING: failed to disable maintenance mode — run 'occ maintenance:mode --off' manually" >&2
    MM_ON=0
  fi
}
if [ "${MAINTENANCE_MODE:-false}" = "true" ]; then
  trap mm_off EXIT
  echo "[$(date -u)] enabling maintenance mode"
  if occ maintenance:mode --on; then MM_ON=1; else
    echo "  FAILED to enable maintenance mode" >&2; exit 1
  fi
fi

# ---- Postgres: pg_dumpall is a single consistent snapshot -------------------
# Verification is content-based, NOT pipe-status-based: without pipefail (not
# every /bin/sh has it) a failed pg_dumpall would still leave a small valid
# gzip from the empty stream and "succeed". A complete dump always ends with
# pg_dump's "PostgreSQL database dump complete" trailer; checking gzip
# integrity + that trailer catches auth failures, truncation, and masked
# kubectl exec errors regardless of shell semantics.
if [ "${PG_ENABLED:-true}" = "true" ]; then
  echo "[$(date -u)] postgres dump -> pg-$TS.sql.gz"
  PGTMP="$PGDIR/pg-$TS.sql.gz.tmp"
  kubectl exec -n "$BACKUP_NS" "$PG_POD" -c postgres -- \
    sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -U "$POSTGRES_USER" -h 127.0.0.1' \
    | gzip > "$PGTMP" || true
  if [ -s "$PGTMP" ] && gzip -t "$PGTMP" 2>/dev/null \
     && zcat "$PGTMP" | tail -c 4096 | grep -q 'PostgreSQL database dump complete'; then
    mv "$PGTMP" "$PGDIR/pg-$TS.sql.gz"
    echo "  ok: $(ls -lh "$PGDIR/pg-$TS.sql.gz" | awk '{print $5}')"
  else
    rm -f "$PGTMP"; echo "  POSTGRES BACKUP FAILED (missing dump trailer or corrupt gzip)" >&2; exit 1
  fi
fi

# ---- Nextcloud files (live tar; tar rc 1 = file changed, tolerated) ---------
# Members: data/ (user files — the data PVC) and config/ (config.php secrets)
# always; custom_apps/ (store-installed apps — the writable apps_paths entry in
# the upstream image) and themes/ when present, so a restore doesn't lose
# admin-installed apps or theming. Core code is NOT backed up — the image
# provides it. Exclude lost+found: it's the root-owned ext4 volume-root
# artifact, not app data, and restoring it trips a noisy chmod error.
echo "[$(date -u)] nextcloud files tar -> files-$TS.tar.gz"
rc=0
kubectl exec -n "$BACKUP_NS" "deploy/$NC_DEPLOY" -c php -- \
  sh -c 'cd /var/www/html && dirs="data config"; for d in custom_apps themes; do [ -d "$d" ] && dirs="$dirs $d"; done; tar czf - --ignore-failed-read --exclude="lost+found" $dirs' \
  > "$NCDIR/files-$TS.tar.gz.tmp" || rc=$?
if [ "$rc" -le 1 ] && [ -s "$NCDIR/files-$TS.tar.gz.tmp" ] \
   && gzip -t "$NCDIR/files-$TS.tar.gz.tmp" 2>/dev/null; then
  mv "$NCDIR/files-$TS.tar.gz.tmp" "$NCDIR/files-$TS.tar.gz"
  echo "  ok (tar rc=$rc): $(ls -lh "$NCDIR/files-$TS.tar.gz" | awk '{print $5}')"
else
  rm -f "$NCDIR/files-$TS.tar.gz.tmp"; echo "  NEXTCLOUD DATA BACKUP FAILED (rc=$rc)" >&2; exit 1
fi

# Backup artifacts are written; lift maintenance mode before retention pruning.
mm_off

# ---- Retention --------------------------------------------------------------
find "$PGDIR" -name 'pg-*.sql.gz'    -mtime +"${RETENTION_DAYS:-14}" -delete 2>/dev/null || true
find "$NCDIR" -name 'files-*.tar.gz' -mtime +"${RETENTION_DAYS:-14}" -delete 2>/dev/null || true
echo "[$(date -u)] === backup $TS OK ==="
