#!/bin/sh
# Backup AND restore for the nextcloud-stack chart — one script, two modes,
# one self-contained artifact per backup run:
#
#   /backup/backup-<TS>.tar            (uncompressed outer tar)
#     ├── nextcloud-backup.meta        KEY=VALUE manifest (format, ts, db, …)
#     ├── pg.sql.gz                    pg_dumpall | gzip   (when PG_ENABLED)
#     └── files.tar.gz                 data/ config/ custom_apps/ themes/
#
# MODE=backup (default — the CronJob's schedule runs this).
#
# MODE=restore — disaster recovery onto a FRESH INSTALL of the chart (same or
#   different cluster/release): install the chart + Secrets, attach the backup
#   PVC, then launch a one-shot Job cloned from the CronJob with
#   MODE=restore and RESTORE_ARCHIVE=<backup-<TS>.tar | latest> injected
#   (copy-paste command in docs/backup-and-restore.md). The restore:
#     1. verifies the archive end-to-end BEFORE touching anything;
#     2. streams files.tar.gz into the live php container (data/, config/,
#        custom_apps/, themes/);
#     3. converges the restored config.php to the CURRENT env/Secrets
#        (dbpassword/dbuser/dbhost/dbname) — the fresh install's passwords
#        stay valid, and the manageAppRole password sync stays consistent;
#     4. scales Nextcloud to 0, drops the DB, reloads the dump, and resets
#        the role passwords to the current Secrets in the SAME psql session;
#     5. scales back up, lifts maintenance mode, bumps the data fingerprint
#        (so desktop/mobile clients resync) and reconciles with files:scan.
#   USER ACCOUNTS come from the backup: log in with the OLD instance's admin
#   credentials, not the fresh install's bootstrap password.
#
# The Postgres dump is produced OVER THE SERVICE by the CronJob's `pg-dump`
# initContainer (no `kubectl exec` → immune to the flaky kubelet-proxy 502 that
# was failing nightly runs). It lands uncompressed at $PG_DUMP_FILE (a shared
# emptyDir); this script gzips + verifies + bundles it. The files tar still
# `kubectl exec`s the live php Pod (its RWO data PVC can't be mounted twice) but
# is now timeout-bounded with a small retry. Restore still execs the live Pods.
# No secret ever appears in a command argument — credentials travel via pod env
# or stdin only.
#
# Env (set by the CronJob): BACKUP_NS, NC_DEPLOY, PG_POD, PG_ENABLED, PG_DB,
# PG_DUMP_FILE, RETENTION_DAYS, MAINTENANCE_MODE, BACKUP_FILES_TIMEOUT,
# BACKUP_FILES_RETRIES; restore adds MODE, RESTORE_ARCHIVE.
set -u
# pipefail where the shell has it (busybox ash, bash); content-based
# verification below covers shells that don't. The subshell PROBE matters: a
# failed bare `set -o pipefail` is a special-builtin error that ABORTS some
# POSIX shells (dash) even with `|| true` — with exit status 0, i.e. a job
# that "succeeds" having done nothing.
(set -o pipefail) 2>/dev/null && set -o pipefail || true
export HOME=/tmp

BACKUP_ROOT=/backup
MODE="${MODE:-backup}"

log()  { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
occ()  { kubectl exec -n "$BACKUP_NS" "deploy/$NC_DEPLOY" -c php -- php /var/www/html/occ "$@"; }
# psql/dropdb inside the postgres Pod, authenticated with ITS env (admin under
# manageAppRole, the app user under the legacy layout). Secrets stay in env.
pgexec() { kubectl exec -i -n "$BACKUP_NS" "$PG_POD" -c postgres -- sh -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" $*"; }
# Run one scalar SQL query in the postgres Pod (SQL is built LOCALLY, with
# qlit-quoted literals, then runs remotely against the maintenance DB).
pgsql_scalar() { pgexec "psql -U \"\$POSTGRES_USER\" -h 127.0.0.1 -d postgres -qAtc \"$1\"" </dev/null; }
# SQL quoting for identifiers / literals built outside the database.
qid()  { printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"; }
qlit() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# ---- maintenance-mode plumbing (used by both modes) --------------------------
MM_ON=0
mm_off() {
  if [ "$MM_ON" = 1 ]; then
    occ maintenance:mode --off || echo "WARNING: failed to disable maintenance mode — run 'occ maintenance:mode --off' manually" >&2
    MM_ON=0
  fi
}
mm_on() {
  log "enabling maintenance mode"
  if occ maintenance:mode --on; then MM_ON=1; else fail "could not enable maintenance mode"; fi
}

# ==============================================================================
# MODE=backup
# ==============================================================================
do_backup() {
  TS=$(date -u +%Y%m%d-%H%M%S)
  STAGE="$BACKUP_ROOT/.work-$TS"
  log "=== backup $TS start ==="

  # Stale stage dirs from crashed runs (>1 day old).
  for d in $(find "$BACKUP_ROOT" -maxdepth 1 -type d -name '.work-*' -mmin +1440 2>/dev/null); do
    log "pruning stale stage $d"; rm -rf "$d"
  done
  mkdir -p "$STAGE"

  if [ "${MAINTENANCE_MODE:-false}" = "true" ]; then
    trap mm_off EXIT
    mm_on
  fi

  # ---- Postgres: gzip + verify the dump the initContainer made --------------
  # The `pg-dump` initContainer already ran `pg_dumpall` OVER THE SERVICE (no
  # kubectl exec) into $PG_DUMP_FILE — a single consistent snapshot — and the
  # Job would have failed before reaching here if that exited non-zero. We just
  # compress and verify it. Verification is content-based: a complete dump ends
  # with pg_dump's "PostgreSQL database dump complete" trailer; gzip integrity +
  # that trailer catch truncation/corruption regardless of shell semantics.
  if [ "${PG_ENABLED:-true}" = "true" ]; then
    DUMP="${PG_DUMP_FILE:-/pgdump/pg.sql}"
    log "postgres dump (made over the Service by initContainer) -> pg.sql.gz"
    [ -s "$DUMP" ] || { rm -rf "$STAGE"; fail "dump $DUMP missing/empty — the pg-dump initContainer failed"; }
    gzip -c "$DUMP" > "$STAGE/pg.sql.gz" || true
    if [ -s "$STAGE/pg.sql.gz" ] && gzip -t "$STAGE/pg.sql.gz" 2>/dev/null \
       && zcat "$STAGE/pg.sql.gz" | tail -c 4096 | grep -q 'PostgreSQL database dump complete'; then
      log "  ok: $(ls -lh "$STAGE/pg.sql.gz" | awk '{print $5}')"
    else
      rm -rf "$STAGE"; fail "postgres dump invalid (missing trailer or corrupt gzip)"
    fi
  fi

  # ---- Nextcloud files (live tar; tar rc 1 = file changed, tolerated) -------
  # Members: data/ (user files — the data PVC) and config/ (config.php
  # secrets) always; custom_apps/ (store-installed apps — the writable
  # apps_paths entry in the upstream image) and themes/ when present. Core
  # code is NOT backed up — the image provides it. lost+found is the
  # root-owned ext4 volume-root artifact, not app data.
  # This exec CAN still hit a transient kubelet-proxy blip, so it is now bounded
  # by `timeout` and retried a few times instead of failing the whole run on one
  # hiccup (tunable via BACKUP_FILES_TIMEOUT / BACKUP_FILES_RETRIES).
  log "nextcloud files tar -> files.tar.gz"
  FT_TIMEOUT="${BACKUP_FILES_TIMEOUT:-1800s}"
  FT_RETRIES="${BACKUP_FILES_RETRIES:-3}"
  attempt=1
  while :; do
    rc=0
    timeout "$FT_TIMEOUT" kubectl exec -n "$BACKUP_NS" "deploy/$NC_DEPLOY" -c php -- \
      sh -c 'cd /var/www/html && dirs="data config"; for d in custom_apps themes; do [ -d "$d" ] && dirs="$dirs $d"; done; tar czf - --ignore-failed-read --exclude="lost+found" $dirs' \
      > "$STAGE/files.tar.gz" || rc=$?
    if [ "$rc" -le 1 ] && [ -s "$STAGE/files.tar.gz" ] && gzip -t "$STAGE/files.tar.gz" 2>/dev/null; then
      log "  ok (tar rc=$rc): $(ls -lh "$STAGE/files.tar.gz" | awk '{print $5}')"
      break
    fi
    if [ "$attempt" -ge "$FT_RETRIES" ]; then
      rm -rf "$STAGE"; fail "nextcloud files tar failed after $attempt attempt(s) (rc=$rc)"
    fi
    log "  files tar attempt $attempt failed (rc=$rc) — retrying in 10s"
    attempt=$((attempt + 1)); sleep 10
  done

  # Artifacts captured — lift maintenance mode before local-only bundling.
  mm_off

  # ---- bundle into ONE archive ----------------------------------------------
  {
    echo "format=1"
    echo "ts=$TS"
    echo "db=${PG_DB:-nextcloud}"
    echo "pg=${PG_ENABLED:-true}"
    echo "deploy=$NC_DEPLOY"
    echo "maintenance_mode=${MAINTENANCE_MODE:-false}"
  } > "$STAGE/nextcloud-backup.meta"
  members="nextcloud-backup.meta files.tar.gz"
  [ -f "$STAGE/pg.sql.gz" ] && members="nextcloud-backup.meta pg.sql.gz files.tar.gz"
  log "bundling -> backup-$TS.tar"
  if tar cf "$BACKUP_ROOT/backup-$TS.tar.tmp" -C "$STAGE" $members \
     && tar tf "$BACKUP_ROOT/backup-$TS.tar.tmp" >/dev/null; then
    mv "$BACKUP_ROOT/backup-$TS.tar.tmp" "$BACKUP_ROOT/backup-$TS.tar"
    rm -rf "$STAGE"
    log "  ok: $(ls -lh "$BACKUP_ROOT/backup-$TS.tar" | awk '{print $5}')"
  else
    rm -f "$BACKUP_ROOT/backup-$TS.tar.tmp"; rm -rf "$STAGE"
    fail "bundling failed (is the backup PVC large enough for ~2x one run?)"
  fi

  # ---- Retention (new single-archive layout + pre-0.6 pair layout) ----------
  find "$BACKUP_ROOT" -maxdepth 1 -name 'backup-*.tar' -mtime +"${RETENTION_DAYS:-14}" -delete 2>/dev/null || true
  find "$BACKUP_ROOT/postgres"  -name 'pg-*.sql.gz'    -mtime +"${RETENTION_DAYS:-14}" -delete 2>/dev/null || true
  find "$BACKUP_ROOT/nextcloud" -name 'files-*.tar.gz' -mtime +"${RETENTION_DAYS:-14}" -delete 2>/dev/null || true
  log "=== backup $TS OK ==="
}

# ==============================================================================
# MODE=restore
# ==============================================================================
meta_get() { grep "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2-; }

do_restore() {
  [ -n "${RESTORE_ARCHIVE:-}" ] || fail "MODE=restore requires RESTORE_ARCHIVE=<backup-<TS>.tar or 'latest'>"
  if [ "$RESTORE_ARCHIVE" = "latest" ]; then
    ARCHIVE=$(ls -t "$BACKUP_ROOT"/backup-*.tar 2>/dev/null | head -1)
    [ -n "$ARCHIVE" ] || fail "no backup-*.tar archives found in $BACKUP_ROOT"
  else
    ARCHIVE="$BACKUP_ROOT/$RESTORE_ARCHIVE"
  fi
  [ -f "$ARCHIVE" ] || fail "archive not found: $ARCHIVE"
  log "=== restore from $(basename "$ARCHIVE") ==="

  # ---- 1. verify the WHOLE archive before mutating anything ------------------
  META=/tmp/nextcloud-backup.meta
  tar -xOf "$ARCHIVE" nextcloud-backup.meta > "$META" 2>/dev/null || fail "archive has no nextcloud-backup.meta (pre-0.6 pair-layout backups: use the manual guide in docs/restore.md)"
  [ "$(meta_get format "$META")" = "1" ] || fail "unsupported archive format '$(meta_get format "$META")'"
  ARC_DB=$(meta_get db "$META"); ARC_PG=$(meta_get pg "$META")
  log "archive: ts=$(meta_get ts "$META") db=$ARC_DB pg=$ARC_PG"
  RESTORE_PG=false
  if [ "${PG_ENABLED:-true}" = "true" ] && [ "$ARC_PG" = "true" ]; then
    RESTORE_PG=true
    [ "$ARC_DB" = "${PG_DB:-nextcloud}" ] || fail "archive db '$ARC_DB' != chart db '${PG_DB:-nextcloud}' — cross-database-name restores are not supported"
    log "verifying pg.sql.gz"
    tar -xOf "$ARCHIVE" pg.sql.gz | zcat 2>/dev/null | tail -c 4096 | grep -q 'PostgreSQL database dump complete' \
      || fail "pg.sql.gz is corrupt or truncated — refusing to restore"
  elif [ "$ARC_PG" = "true" ]; then
    log "WARNING: archive contains a DB dump but postgres.enabled=false — restoring FILES ONLY"
  fi
  log "verifying files.tar.gz"
  tar -xOf "$ARCHIVE" files.tar.gz | gzip -t 2>/dev/null || fail "files.tar.gz is corrupt — refusing to restore"

  # ---- 2. fail-fast plumbing -------------------------------------------------
  # This cluster's API-proxied exec websocket can stay open AFTER a large
  # transfer's bytes have already landed (seen as "websocket: close sent"). With
  # no request timeout that pins the whole restore until the Job's
  # activeDeadlineSeconds — and the Job controller then deletes the Pod, losing
  # the logs. So bound every nextcloud-Pod call, and verify the big file
  # transfer by CONTENT (the same philosophy as the backup's content checks)
  # rather than trusting the exec's exit status. Tunable via env if a slow link
  # needs longer.
  RT="${RESTORE_REQUEST_TIMEOUT:-120s}"   # control-plane calls (creds/converge/scale/verify)
  RTS="${RESTORE_STREAM_TIMEOUT:-900s}"   # the single large files stream
  ncx() { timeout "$RT" kubectl exec -n "$BACKUP_NS" "deploy/$NC_DEPLOY" -c php -- "$@"; }

  # ---- 3. capture the CURRENT credentials from the live pod envs -------------
  # (also proves both pods are up before we start). The restored config.php and
  # the reloaded DB roles are converged to THESE values, so the Secrets the
  # fresh install was bootstrapped with stay authoritative.
  CUR_APP_USER=$(ncx printenv POSTGRES_USER) || fail "cannot read app DB user from the nextcloud pod"
  CUR_APP_PW=$(ncx printenv POSTGRES_PASSWORD) || fail "cannot read app DB password from the nextcloud pod"
  if [ "$RESTORE_PG" = "true" ]; then
    CUR_PG_USER=$(timeout "$RT" kubectl exec -n "$BACKUP_NS" "$PG_POD" -c postgres -- printenv POSTGRES_USER) || fail "cannot read bootstrap user from the postgres pod"
    CUR_PG_PW=$(timeout "$RT" kubectl exec -n "$BACKUP_NS" "$PG_POD" -c postgres -- printenv POSTGRES_PASSWORD) || fail "cannot read bootstrap password from the postgres pod"
  fi

  trap 'echo "RESTORE FAILED — the instance may be scaled down or partially restored; see docs/restore.md before retrying" >&2' EXIT

  # ---- 4. files: stream straight out of the archive into the php container ---
  # The php container's liveness probe is a bare TCP check, so the (briefly
  # inconsistent) restored config.php does NOT restart the Pod here — the
  # convergence below runs against this same Pod, and the clean boot happens
  # later when the DB step scales it 0->N.
  #
  # On this cluster the exec websocket can stay half-open AFTER every byte has
  # landed ("websocket: close sent" — the original ~1h hang). So the remote
  # shell drops a sentinel with tar's exit status the instant extraction
  # finishes; we poll for it and move on as soon as the data is really in,
  # rather than blocking on the dead socket until the RTS hard cap. tar's rc is
  # advisory (a chmod warning on the root-owned data dir alone trips it); the
  # AUTHORITATIVE check is by CONTENT — config.php's instanceid must match the
  # archive's (the same philosophy as the backup's content verification).
  log "restoring files (data/ config/ custom_apps/ themes/)"
  ncx rm -f /tmp/.nc-restore-rc >/dev/null 2>&1 || true
  ( tar -xOf "$ARCHIVE" files.tar.gz \
      | timeout "$RTS" kubectl exec -i -n "$BACKUP_NS" "deploy/$NC_DEPLOY" -c php -- \
          sh -c 'tar xzf - --no-overwrite-dir --no-same-owner -C /var/www/html; echo "$?" >/tmp/.nc-restore-rc' \
  ) >/dev/null 2>&1 &
  STREAM_PID=$!
  TAR_RC=""; waited=0; cap="${RTS%s}"
  while [ "$waited" -lt "$cap" ]; do
    TAR_RC=$(ncx cat /tmp/.nc-restore-rc 2>/dev/null | tr -dc '0-9')
    [ -n "$TAR_RC" ] && break                    # remote tar finished (all members)
    kill -0 "$STREAM_PID" 2>/dev/null || break    # local pipeline already returned
    waited=$((waited + 5)); sleep 5
  done
  kill "$STREAM_PID" 2>/dev/null; wait "$STREAM_PID" 2>/dev/null || true
  ncx rm -f /tmp/.nc-restore-rc >/dev/null 2>&1 || true
  [ -n "$TAR_RC" ] && [ "$TAR_RC" -le 1 ] 2>/dev/null \
    || log "  note: file stream did not report a clean tar status (rc=[$TAR_RC]) — relying on the content check below"

  iid_re="'instanceid'[[:space:]]*=>[[:space:]]*'[^']*'"
  ARC_IID=$(tar -xOf "$ARCHIVE" files.tar.gz | tar -xzO config/config.php 2>/dev/null | grep -oE "$iid_re" | head -1)
  LIVE_IID=$(ncx grep -oE "$iid_re" /var/www/html/config/config.php 2>/dev/null | head -1)
  [ -n "$ARC_IID" ] && [ "$ARC_IID" = "$LIVE_IID" ] \
    || fail "file restore verification failed — config.php did not land (archive=[$ARC_IID] live=[$LIVE_IID]); the DB is untouched, so this is safe to retry"
  log "  files restored and verified (config.php instanceid matches the archive)"

  # ---- 5. converge restored config.php to the CURRENT env/Secrets ------------
  # The backup's config.php carries the OLD dbpassword/dbhost. Left alone it
  # would break either immediately (different release name) or on the next pod
  # start (manageAppRole syncs the role password to the current Secret).
  # instanceid/secret/passwordsalt are deliberately untouched — they key the
  # restored data. maintenance is cleared; occ confirms it again at the end.
  log "converging restored config.php to current env"
  ncx php -r '
    $f = "/var/www/html/config/config.php";
    require $f;
    $CONFIG["dbpassword"]  = getenv("POSTGRES_PASSWORD");
    $CONFIG["dbuser"]      = getenv("POSTGRES_USER");
    $CONFIG["dbhost"]      = getenv("POSTGRES_HOST");
    $CONFIG["dbname"]      = getenv("POSTGRES_DB");
    $CONFIG["maintenance"] = false;
    if (file_put_contents($f, "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n") === false) { exit(1); }
    echo "config.php converged\n";' || fail "config.php convergence failed"

  if [ "$RESTORE_PG" = "true" ]; then
    # ---- 6. quiesce the app (frees every DB connection) ----------------------
    ORIG_REPLICAS=$(timeout "$RT" kubectl get deploy -n "$BACKUP_NS" "$NC_DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    [ -n "$ORIG_REPLICAS" ] && [ "$ORIG_REPLICAS" -ge 1 ] 2>/dev/null || ORIG_REPLICAS=1
    log "scaling deploy/$NC_DEPLOY 0 (was $ORIG_REPLICAS)"
    timeout "$RT" kubectl scale -n "$BACKUP_NS" "deploy/$NC_DEPLOY" --replicas=0 || fail "scale to 0 failed"
    CONN_SQL="SELECT count(*) FROM pg_stat_activity WHERE datname = $(qlit "$ARC_DB")"
    i=0
    while [ "$(pgsql_scalar "$CONN_SQL" 2>/dev/null || echo 1)" != "0" ]; do
      i=$((i+1)); [ "$i" -le 60 ] || break   # dropdb --force terminates stragglers
      sleep 2
    done

    # ---- 7. drop + reload, resetting role passwords in the SAME session ------
    # pg_dumpall's ALTER ROLE statements would reset both roles to the OLD
    # passwords mid-reload; the epilogue (same already-authenticated session)
    # converges them back to the current Secrets before anything reconnects.
    # "role … already exists" errors during the reload are expected.
    log "dropping database $ARC_DB"
    pgexec "dropdb -U \"\$POSTGRES_USER\" -h 127.0.0.1 --if-exists --force $(qid "$ARC_DB")" </dev/null || fail "dropdb failed"
    log "reloading dump (role-exists errors are expected)"
    {
      tar -xOf "$ARCHIVE" pg.sql.gz | zcat
      printf '\n'
      printf 'ALTER ROLE %s WITH PASSWORD %s;\n' "$(qid "$CUR_PG_USER")" "$(qlit "$CUR_PG_PW")"
      printf 'ALTER ROLE %s WITH PASSWORD %s;\n' "$(qid "$CUR_APP_USER")" "$(qlit "$CUR_APP_PW")"
    } | pgexec 'psql -q -U "$POSTGRES_USER" -h 127.0.0.1 -d postgres' || fail "dump reload failed"
    EXISTS_SQL="SELECT count(*) FROM pg_database WHERE datname = $(qlit "$ARC_DB")"
    [ "$(pgsql_scalar "$EXISTS_SQL")" = "1" ] || fail "database $ARC_DB missing after reload"

    # ---- 8. bring the app back FRESH ------------------------------------------
    # The scaled-up Pod boots against the CONVERGED config.php + the RELOADED
    # DB — a clean start. (The old flow left the in-place, exec-mutated Pod
    # running, which wedged on its next entrypoint re-run.)
    log "scaling deploy/$NC_DEPLOY back to $ORIG_REPLICAS"
    timeout "$RT" kubectl scale -n "$BACKUP_NS" "deploy/$NC_DEPLOY" --replicas="$ORIG_REPLICAS" || fail "scale up failed"
    kubectl rollout status -n "$BACKUP_NS" "deploy/$NC_DEPLOY" --timeout=600s || fail "nextcloud did not become ready after restore"
  else
    # Files-only restore (no DB in the archive, or postgres.enabled=false): the
    # running Pod still holds its pre-restore config in memory, so bounce it via
    # the scale subresource (the only Deployment write this SA is granted) to
    # boot against the restored files + converged config.php.
    ORIG_REPLICAS=$(timeout "$RT" kubectl get deploy -n "$BACKUP_NS" "$NC_DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    [ -n "$ORIG_REPLICAS" ] && [ "$ORIG_REPLICAS" -ge 1 ] 2>/dev/null || ORIG_REPLICAS=1
    log "files-only restore — bouncing deploy/$NC_DEPLOY (0 -> $ORIG_REPLICAS) to apply"
    timeout "$RT" kubectl scale -n "$BACKUP_NS" "deploy/$NC_DEPLOY" --replicas=0 || fail "scale to 0 failed"
    timeout "$RT" kubectl scale -n "$BACKUP_NS" "deploy/$NC_DEPLOY" --replicas="$ORIG_REPLICAS" || fail "scale up failed"
    kubectl rollout status -n "$BACKUP_NS" "deploy/$NC_DEPLOY" --timeout=600s || fail "nextcloud did not become ready after restore"
  fi

  # ---- 9. reconcile -----------------------------------------------------------
  occ maintenance:mode --off || true
  MM_ON=0
  # New data fingerprint tells desktop/mobile clients the server state changed.
  occ maintenance:data-fingerprint || log "WARNING: maintenance:data-fingerprint failed — run it manually"
  occ files:scan --all || log "WARNING: files:scan --all failed or timed out — run it manually"
  occ status || true
  trap - EXIT
  log "=== restore OK — log in with the BACKED-UP instance's credentials (not the fresh install's bootstrap password) ==="
}

case "$MODE" in
  backup)  do_backup ;;
  restore) do_restore ;;
  *) fail "unknown MODE '$MODE' (backup|restore)" ;;
esac
