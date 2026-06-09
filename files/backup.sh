#!/bin/sh
# Backs up Postgres (pg_dumpall) + the Nextcloud data/config to /backup (a PVC,
# e.g. off-cluster NFS). Runs as a non-root CronJob that `kubectl exec`s into the
# live Pods, so it never multi-attaches the RWO PVCs. Dynamic values come from
# env (set by the CronJob): PG_POD, NC_DEPLOY, BACKUP_NS, PG_ENABLED,
# RETENTION_DAYS.
set -u
set -o pipefail 2>/dev/null || true
export HOME=/tmp
TS=$(date -u +%Y%m%d-%H%M%S)
PGDIR=/backup/postgres
NCDIR=/backup/nextcloud
mkdir -p "$PGDIR" "$NCDIR"
echo "[$(date -u)] === backup $TS start ==="

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

# ---- Nextcloud data + config (live tar; tar rc 1 = file changed, tolerated) --
# Exclude lost+found: it's the root-owned ext4 volume-root artifact, not app data,
# and restoring it trips a harmless-but-noisy "Cannot change mode" chmod error.
echo "[$(date -u)] nextcloud data/config tar -> files-$TS.tar.gz"
rc=0
kubectl exec -n "$BACKUP_NS" "deploy/$NC_DEPLOY" -c php -- \
  tar czf - --ignore-failed-read --exclude='lost+found' -C /var/www/html data config \
  > "$NCDIR/files-$TS.tar.gz.tmp" || rc=$?
if [ "$rc" -le 1 ] && [ -s "$NCDIR/files-$TS.tar.gz.tmp" ]; then
  mv "$NCDIR/files-$TS.tar.gz.tmp" "$NCDIR/files-$TS.tar.gz"
  echo "  ok (tar rc=$rc): $(ls -lh "$NCDIR/files-$TS.tar.gz" | awk '{print $5}')"
else
  rm -f "$NCDIR/files-$TS.tar.gz.tmp"; echo "  NEXTCLOUD DATA BACKUP FAILED (rc=$rc)" >&2; exit 1
fi

# ---- Retention --------------------------------------------------------------
find "$PGDIR" -name 'pg-*.sql.gz'    -mtime +"${RETENTION_DAYS:-14}" -delete 2>/dev/null || true
find "$NCDIR" -name 'files-*.tar.gz' -mtime +"${RETENTION_DAYS:-14}" -delete 2>/dev/null || true
echo "[$(date -u)] === backup $TS OK ==="
