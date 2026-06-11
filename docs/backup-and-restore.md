# Backup & Restore

The chart ships an optional backup CronJob and a **proven** restore procedure. A
backup nobody restore-tests is worse than none, so the restore guide is written
from an actual back-up → wipe → restore cycle.

---

## Turning on backups

```yaml
backup:
  enabled: true
  schedule: "30 2 * * *"          # daily 02:30 (cluster timezone)
  retentionDays: 14
  persistence:
    existingClaim: nextcloud-backups   # an OFF-CLUSTER-backed PVC, for real DR
    # or, to let the chart create one:
    # size: 100Gi
    # storageClassName: nfs-csi-retain
```

Each run produces **one self-contained archive** on the backup PVC —
`backup-<TS>.tar` (`<TS>` = `YYYYMMDD-HHMMSS` UTC), an uncompressed tar of:

| Member | Contents | Made with |
|---|---|---|
| `nextcloud-backup.meta` | `KEY=VALUE` manifest: format, timestamp, database name, … | — |
| `pg.sql.gz` | the **whole** Postgres cluster | `pg_dumpall` + gzip |
| `files.tar.gz` | `data/` (user files), `config/`, plus `custom_apps/` and `themes/` when present | live `tar` + gzip |

One file = one consistent point in time: copy it off-site as a unit, and the
DB dump can never be separated from its matching `config.php`. Bundling stages
the members on the backup PVC first, so keep roughly **2× one run's size**
free. (Pre-0.6 runs wrote a `postgres/` + `nextcloud/` *pair* instead — those
remain restorable via the manual guide, and retention still prunes them.)

> `config/` is included because `config.php` holds the `secret`, `passwordsalt`,
> and `dbpassword` the database is keyed against — the DB dump is only restorable
> alongside its matching `config.php`. `custom_apps/` (the writable apps path —
> where store-installed apps live) and `themes/` are included so a restore
> doesn't come back with apps the database knows about but whose code is gone.
> Core Nextcloud code is deliberately **not** backed up: the image provides it.

### Consistency: live tar vs maintenance mode

By default the tar runs against the **live** Pod (changed-mid-read files are
tolerated, `tar rc=1`). For a hard guarantee that the DB dump and the files tar
are one frozen point in time — what the Nextcloud manual recommends — set:

```yaml
backup:
  maintenanceMode: true   # occ maintenance:mode --on … --off around the run
```

Users see the maintenance page for the duration of the backup (schedule it for
the quietest hour). The job re-enables normal mode on **every** exit path,
including failures.

### Why not back up / "download" the PVCs directly?

There is no Kubernetes API for downloading a PVC — a volume's contents are only
reachable through a Pod that mounts it, or via storage-layer snapshots:

- **Mounting the PVCs in the backup Job** would `Multi-Attach`-deadlock on RWO
  storage while the live Pod holds them — the exact failure mode this design
  avoids. The `kubectl exec` + `tar` stream *is* the "download", from the one
  Pod that legitimately has the volume mounted.
- **Raw-copying the Postgres PVC** would capture a torn, non-restorable state
  unless the server is stopped; `pg_dumpall` is the transactionally-consistent
  equivalent.
- **CSI `VolumeSnapshot`s** are a fine *complement* (fast, crash-consistent,
  before risky upgrades) but they live in the same storage backend they
  protect, need a per-cluster `VolumeSnapshotClass`, and aren't restorable
  off-cluster — so the chart doesn't manage them. The off-cluster tar + dump
  pair remains the disaster-recovery source of truth.

### How it stays safe

- It **`kubectl exec`s into the live Pods** rather than mounting the RWO PVCs, so
  it never `Multi-Attach`es.
- It runs as a non-root, restricted-PSS Pod with a **minimal ServiceAccount**
  (`pods/exec`, plus `deployments/scale` — restore-mode's only write) and its
  **own network policy** (egress to the kube-apiserver + DNS only).
- Archives older than `retentionDays` are pruned automatically.
- The volume-root `lost+found` artifact is excluded from the data tar (it would
  otherwise trip a noisy chmod warning on restore).

### Put the backups somewhere else

Point `backup.persistence` at storage on a **different failure domain** than the
cluster — an NFS export, object storage via a CSI driver, etc. A backup on the same
disks it protects isn't a backup. Use a `Retain`-reclaim StorageClass so the
archives survive PVC deletion.

---

## Restoring — scripted

The same script that takes the backups performs the restore. Target state: a
**fresh install of the chart** (same or different cluster/release) — Secrets
bootstrapped, pods healthy, and the backup PVC attached via
`backup.persistence.existingClaim`. Then launch a one-shot Job cloned from the
CronJob with the restore mode injected:

```bash
NS=nextcloud REL=nextcloud-stack
# RESTORE_ARCHIVE: a specific backup-<TS>.tar, or 'latest'
kubectl -n $NS create job restore-$(date +%s) --from=cronjob/$REL-backup \
  --dry-run=client -o json \
| jq '.spec.template.spec.containers[0].env += [
    {"name":"MODE","value":"restore"},
    {"name":"RESTORE_ARCHIVE","value":"latest"}]' \
| kubectl create -f -
kubectl -n $NS logs -f job/$(kubectl -n $NS get job -o name --sort-by=.metadata.creationTimestamp | tail -1 | cut -d/ -f2)
```

What the restore does, in order:

1. **Verifies the whole archive first** (gzip integrity + the `pg_dumpall`
   completion trailer) — a corrupt archive aborts before anything is touched.
2. Streams `files.tar.gz` into the live php container (`data/`, `config/`,
   `custom_apps/`, `themes/`), then verifies it landed by **content**
   (`config.php`'s `instanceid` must match the archive's) rather than trusting
   the exec's exit status — some API proxies leave the exec websocket half-open
   after the bytes arrive, which would otherwise hang the Job. A completion
   sentinel means the restore proceeds the instant the data is in. Every
   nextcloud-pod call is `timeout`-bounded; tune with the Job env vars
   `RESTORE_REQUEST_TIMEOUT` (default `120s`) and `RESTORE_STREAM_TIMEOUT`
   (default `900s`, the hard cap on the file stream) if a slow link needs more.
3. **Converges the restored `config.php` to the current Secrets/env**
   (`dbpassword`/`dbuser`/`dbhost`/`dbname`) — `instanceid`, `secret` and
   `passwordsalt` stay as backed up, since they key the restored data. This is
   what makes restore-onto-fresh-install (and onto a different release name)
   work, and keeps the `manageAppRole` password sync consistent.
4. Scales Nextcloud to 0, drops the database, reloads the dump, and resets the
   DB role passwords to the current Secrets **in the same psql session** (the
   dump itself would otherwise reset them to the old ones).
5. Scales back up, lifts maintenance mode, bumps the data fingerprint (so
   desktop/mobile clients resync) and runs `occ files:scan --all`.

> **Log in with the backed-up instance's credentials afterwards** — user
> accounts (including admin) come from the restored database, not from the
> fresh install's bootstrap password. `occ user:resetpassword admin` if lost.

The manual step-by-step equivalent (also the path for **pre-0.6 pair-layout**
backups) lives in **[restore.md](restore.md)**, including a **verification
drill** you should run quarterly.

> The restore flow was validated end-to-end: an on-disk file **and** a database
> row were destroyed and recovered. Don't improvise during an incident.

---

## Quick verification of a backup run

```bash
# trigger an out-of-schedule run
kubectl -n nextcloud create job manual-backup --from=cronjob/nextcloud-stack-backup

# watch it
kubectl -n nextcloud logs -f job/manual-backup

# confirm the archive is valid (from a Pod mounting the backup PVC)
#   tar tf backup-<TS>.tar                      # lists meta + pg.sql.gz + files.tar.gz
#   tar -xOf backup-<TS>.tar pg.sql.gz | gunzip -t
#   tar -xOf backup-<TS>.tar files.tar.gz | gunzip -t
```

---

## What else to back up

- **The source Secrets** (admin, postgres, valkey, …). They're not in the data/DB
  backup. Keep them in your secrets manager or a sealed/SOPS file.
- **Your values overlay** (`my-values.yaml`) — under version control.

With those three (Secrets, values, data+DB backup) you can rebuild the instance
from scratch.

---

← [Storage & Scaling](storage-and-scaling.md) · [Wiki home](README.md) · Next: [Monitoring](monitoring.md)
