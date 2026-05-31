---
---

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

On each run the CronJob writes two artifacts to the backup PVC:

| File | Contents | Made with |
|---|---|---|
| `postgres/pg-<TS>.sql.gz` | the **whole** Postgres cluster | `pg_dumpall` + gzip |
| `nextcloud/files-<TS>.tar.gz` | `data/` **and** `config/` | live `tar` + gzip |

`<TS>` is `YYYYMMDD-HHMMSS` (UTC). A matching pair = one consistent point in time.

> `config/` is included because `config.php` holds the `secret`, `passwordsalt`,
> and `dbpassword` the database is keyed against — the DB dump is only restorable
> alongside its matching `config.php`.

### How it stays safe

- It **`kubectl exec`s into the live Pods** rather than mounting the RWO PVCs, so
  it never `Multi-Attach`es.
- It runs as a non-root, restricted-PSS Pod with a **minimal ServiceAccount**
  (`pods/exec` only) and its **own CiliumNetworkPolicy** (egress to the
  kube-apiserver + DNS only).
- Archives older than `retentionDays` are pruned automatically.
- The volume-root `lost+found` artifact is excluded from the data tar (it would
  otherwise trip a noisy chmod warning on restore).

### Put the backups somewhere else

Point `backup.persistence` at storage on a **different failure domain** than the
cluster — an NFS export, object storage via a CSI driver, etc. A backup on the same
disks it protects isn't a backup. Use a `Retain`-reclaim StorageClass so the
archives survive PVC deletion.

---

## Restoring

The full, copy-pasteable procedure lives in **[restore.md](restore.md)** — it
covers:

1. Identifying which backup to restore (a helper Pod reads the backup PVC).
2. Maintenance mode.
3. Restoring `data/` + `config/` (stream the tar into the running Pod).
4. Restoring the database (scale to 0 → `dropdb` → reload `pg_dumpall` → scale up).
5. Reconciling (`occ files:scan`) and verifying.

It also includes a **verification drill** (§9) you should run quarterly, and an
in-cluster variant for very large data sets.

> The restore steps were validated end-to-end: an on-disk file **and** a database
> row were destroyed and recovered. Quote the guide; don't improvise during an
> incident.

---

## Quick verification of a backup run

```bash
# trigger an out-of-schedule run
kubectl -n nextcloud create job manual-backup --from=cronjob/nextcloud-stack-backup

# watch it
kubectl -n nextcloud logs -f job/manual-backup

# confirm the archives are valid (from a Pod mounting the backup PVC)
#   gunzip -t postgres/pg-<TS>.sql.gz   &&   tar tzf nextcloud/files-<TS>.tar.gz
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
