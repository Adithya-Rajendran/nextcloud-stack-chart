# Restoring Nextcloud from a backup

This restores the data produced by the chart's optional backup CronJob
(`backup.enabled: true`). It is **proven end-to-end**: the exact commands below
were run as a full *back-up → wipe → restore* cycle (an on-disk file *and* a
database row were destroyed and recovered).

---

## 1. What's in a backup

The `<release>-backup` CronJob writes two artifacts per run to the backup PVC
(point it at off-cluster NFS for real DR — see `backup.persistence`):

| Path on the backup PVC | Contents | How it's made |
|---|---|---|
| `postgres/pg-<TS>.sql.gz` | The **whole** Postgres cluster — roles + every database, including `nextcloud` | `pg_dumpall`, gzipped |
| `nextcloud/files-<TS>.tar.gz` | `/var/www/html/data`, `/var/www/html/config`, plus `custom_apps/` and `themes/` when present (store-installed apps + theming) | live `tar czf`, gzipped |

`<TS>` is `YYYYMMDD-HHMMSS` (UTC). A matching pair (same `<TS>`) is one
consistent point in time — always restore the DB and the files from the **same**
timestamp.

> **Why `config/` is in the files tar:** `config/config.php` holds `secret`,
> `passwordsalt`, `instanceid` and `dbpassword`. The database is encrypted/keyed
> against those values, so the DB dump is only usable with its matching
> `config.php`. Restoring the files tar brings the right `config.php` back — which
> is exactly why a DB restore and a files restore must come from the same backup.

---

## 2. Before you start

Set these to match your install:

```sh
export KUBECONFIG=...                  # your cluster
NS=nextcloud                           # release namespace
REL=nextcloud-stack                    # helm release name
DB=nextcloud                           # postgres.auth.database
BACKUP_PVC=nextcloud-backups           # backup.persistence.existingClaim (or <REL>-backup)

PG_POD=$REL-postgres-0                 # the Postgres StatefulSet pod
NC_DEPLOY=$REL                         # the Nextcloud Deployment
```

This guide restores **in place, into the same release** (same Secrets). Restoring
into a brand-new/empty release works too — the files tar carries `config.php`, so
the secrets line up — just create the release (and its Secrets) first, then follow
the same steps.

Only `kubectl` is needed. A throwaway helper Pod is used to read the backup PVC
(the PVC may be `ReadWriteMany` NFS; the helper just needs read access).

---

## 3. Start the helper Pod & pick a timestamp

```sh
kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: restore-helper }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 1000, fsGroup: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: h
      image: busybox:stable
      command: ["sh","-c","sleep 3600"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumeMounts: [{ name: b, mountPath: /backup, readOnly: true }]
  volumes:
    - name: b
      persistentVolumeClaim: { claimName: PUT_BACKUP_PVC_HERE }
EOF
# substitute the PVC name (the heredoc is quoted, so edit after apply or use sed):
kubectl -n "$NS" patch pod restore-helper --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/volumes/0/persistentVolumeClaim/claimName\",\"value\":\"$BACKUP_PVC\"}]" 2>/dev/null || true

kubectl -n "$NS" wait --for=condition=Ready pod/restore-helper --timeout=120s

# List what's available, newest last, and capture the latest matching pair:
kubectl -n "$NS" exec restore-helper -- sh -c 'ls -t /backup/postgres/pg-*.sql.gz; echo ---; ls -t /backup/nextcloud/files-*.tar.gz'

PG=$(kubectl -n "$NS"  exec restore-helper -- sh -c 'ls -t /backup/postgres/pg-*.sql.gz | head -1')
TAR=$(kubectl -n "$NS" exec restore-helper -- sh -c 'ls -t /backup/nextcloud/files-*.tar.gz | head -1')
echo "restoring DB=$PG  FILES=$TAR"
```

> If `claimName` ends up wrong, just `kubectl -n $NS delete pod restore-helper`,
> hard-code your PVC name into the manifest, and re-apply. The `patch` line is a
> convenience for the quoted heredoc.

---

## 4. Put the site into maintenance mode

```sh
kubectl -n "$NS" exec deploy/"$NC_DEPLOY" -c php -- php /var/www/html/occ maintenance:mode --on
```

---

## 5. Restore the files (`data/` + `config/`)

Stream the tar from the backup PVC straight into the running Nextcloud Pod:

```sh
kubectl -n "$NS" exec restore-helper -- cat "$TAR" \
  | kubectl -n "$NS" exec -i deploy/"$NC_DEPLOY" -c php -- \
      tar xzf - --no-overwrite-dir --no-same-owner -C /var/www/html
```

> **Expected, harmless warning:** `tar: data: Cannot change mode … Operation not
> permitted`. The `data` directory is a CSI volume mount-point whose root is
> root-owned, so the non-root `php` user can't reset its mode. File **contents**
> restore correctly — this single line is cosmetic. (Backups taken after the
> `lost+found` fix produce no other chmod noise.)

---

## 6. Restore the database

The DB must have no application connections while it's dropped and reloaded, so
scale Nextcloud to zero first:

```sh
# 6a. quiesce the app (frees all DB connections)
kubectl -n "$NS" scale deploy/"$NC_DEPLOY" --replicas=0
kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/component=nextcloud --timeout=120s

# 6b. drop the existing database
kubectl -n "$NS" exec "$PG_POD" -c postgres -- sh -c \
  "PGPASSWORD=\"\$POSTGRES_PASSWORD\" dropdb -U \"\$POSTGRES_USER\" -h 127.0.0.1 --if-exists --force $DB"

# 6c. load the dump (pg_dumpall recreates the database and its contents).
#     'CREATE ROLE … already exists' notices are expected and harmless — the
#     roles persist across the drop; only the database is recreated.
kubectl -n "$NS" exec restore-helper -- cat "$PG" | gunzip -c \
  | kubectl -n "$NS" exec -i "$PG_POD" -c postgres -- sh -c \
      'PGPASSWORD="$POSTGRES_PASSWORD" psql -q -U "$POSTGRES_USER" -h 127.0.0.1 -d postgres'

# 6d. bring the app back
kubectl -n "$NS" scale deploy/"$NC_DEPLOY" --replicas=1
kubectl -n "$NS" rollout status deploy/"$NC_DEPLOY" --timeout=180s
```

---

## 7. Reconcile & leave maintenance mode

```sh
# Restoring config.php (step 5) usually clears the maintenance flag already;
# run this to be certain, then reconcile the file cache with what's on disk.
kubectl -n "$NS" exec deploy/"$NC_DEPLOY" -c php -- php /var/www/html/occ maintenance:mode --off
kubectl -n "$NS" exec deploy/"$NC_DEPLOY" -c php -- php /var/www/html/occ files:scan --all
kubectl -n "$NS" exec deploy/"$NC_DEPLOY" -c php -- php /var/www/html/occ status
```

`occ status` should report `installed: true`, `maintenance: false`,
`needsDbUpgrade: false`.

---

## 8. Clean up

```sh
kubectl -n "$NS" delete pod restore-helper
```

---

## 9. Verifying a restore (recommended drill)

Prove the pipeline *before* you need it. In a throwaway namespace, install the
chart with `backup.enabled: true`, then:

```sh
# plant two markers: one on disk, one in the database
kubectl -n "$NS" exec deploy/"$NC_DEPLOY" -c php -- sh -c \
  'echo HELLO > /var/www/html/data/admin/files/MARKER.txt; php /var/www/html/occ files:scan admin'
kubectl -n "$NS" exec deploy/"$NC_DEPLOY" -c php -- php /var/www/html/occ config:app:set restoretest marker --value=HELLO

# back up, then destroy both markers
kubectl -n "$NS" create job verify-backup --from=cronjob/"$REL"-backup
# … wait for the job to succeed …
kubectl -n "$NS" exec deploy/"$NC_DEPLOY" -c php -- sh -c \
  'rm /var/www/html/data/admin/files/MARKER.txt; php /var/www/html/occ files:scan admin'
kubectl -n "$NS" exec deploy/"$NC_DEPLOY" -c php -- php /var/www/html/occ config:app:delete restoretest marker

# run the restore (steps 3–8) and confirm both markers return:
kubectl -n "$NS" exec deploy/"$NC_DEPLOY" -c php -- cat /var/www/html/data/admin/files/MARKER.txt           # -> HELLO
kubectl -n "$NS" exec deploy/"$NC_DEPLOY" -c php -- php /var/www/html/occ config:app:get restoretest marker  # -> HELLO
```

This is exactly the cycle used to validate the procedure above.

---

## Notes & alternatives

- **Very large data sets.** Steps 5 and 6c stream the archives through your local
  `kubectl`. That's fine up to tens of GB, but for hundreds of GB — or over a slow
  API-server proxy — run the restore *inside* the cluster instead: scale Nextcloud
  to 0, then launch a one-shot Pod that mounts the backup PVC **and** the data /
  webroot PVCs (now free) and untars locally; restore the DB with a Pod on the
  cluster network running `psql`. Same commands, no bytes leaving the cluster.
- **Point-in-time / older snapshot.** Set `PG`/`TAR` in step 3 to the pair you
  want instead of `head -1`. Keep them the same `<TS>`.
- **Retention.** Backups older than `backup.retentionDays` are pruned by the
  CronJob, so older snapshots may not exist. Copy archives you want to keep
  long-term off the PVC.
- **Restoring onto a different cluster.** Provision the same Secrets (or let the
  restored `config.php` supply them), match `postgres.auth.username`/`database`,
  then follow steps 3–8 unchanged.
