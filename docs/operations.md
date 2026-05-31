---
---

# Operations (Day 2)

Running the chart after install: upgrades, secret rotation, Postgres major
upgrades, `occ`, and maintenance.

---

## Upgrading the chart

```bash
helm upgrade nextcloud-stack . -n nextcloud -f my-values.yaml -f pins.yaml
```

There's no re-apply checklist — everything's in the chart. A **post-upgrade hook
Job** runs the idempotent DB migrations (`occ db:add-missing-*`, repairs) after the
new Pod rolls in.

> **Never change `nameOverride`/`fullnameOverride` after the first install.**
> Deployment selectors are immutable; a changed selector breaks the upgrade.

To adopt newer images, re-pin first and review the diff:

```bash
./scripts/pin-digests.sh > pins.yaml
git diff pins.yaml          # eyeball what's changing
helm upgrade nextcloud-stack . -n nextcloud -f my-values.yaml -f pins.yaml
```

### Upgrading on hook-restricted clusters

On some clusters the post-install/upgrade **hook Job can't be watched to
completion** — e.g. behind the Rancher API proxy, where the hook's watch times out.
Symptom: `helm install/upgrade` hangs on the hook.

Work around it by skipping hooks and running the migration step yourself:

```bash
helm upgrade nextcloud-stack . -n nextcloud -f my-values.yaml --no-hooks

# then run the same idempotent migrations the hook would have:
kubectl -n nextcloud exec deploy/nextcloud-stack -c php -- sh -c '
  for c in db:add-missing-indices db:add-missing-columns \
           db:add-missing-primary-keys db:convert-filecache-bigint; do
    php occ "$c" -n
  done
  php occ maintenance:repair --include-expensive -n'
```

(If you use add-ons, also set their `occ config:app:set …` values — the
db-migrate Job template is the reference for exactly what it does.)

---

## `occ` — the Nextcloud admin CLI

`occ` runs **inside** the php container:

```bash
kubectl -n nextcloud exec deploy/nextcloud-stack -c php -- php occ <command>
```

Handy ones:

```bash
... php occ status                       # installed? maintenance? version?
... php occ user:resetpassword admin     # reset the admin password (interactive)
... php occ files:scan --all             # reconcile the file cache with disk
... php occ config:list system           # dump system config
... php occ app:list                     # installed apps
... php occ maintenance:mode --on|--off  # toggle maintenance mode
```

---

## Maintenance mode

Puts the instance read-only/offline (users see a maintenance page). Used during
restores and risky changes:

```bash
kubectl -n nextcloud exec deploy/nextcloud-stack -c php -- php occ maintenance:mode --on
# … do the work …
kubectl -n nextcloud exec deploy/nextcloud-stack -c php -- php occ maintenance:mode --off
```

---

## Secret rotation

Secrets are external, so rotation is a Secret update + a nudge:

- **Admin password.** Easiest via the web UI, or
  `occ user:resetpassword admin`. The `<release>-admin` Secret only matters at
  first install, so you don't strictly need to update it — but keep it in sync if
  you rely on it.
- **Postgres password.** Order matters (short outage):
  ```bash
  # 1. update the Secret
  kubectl -n nextcloud create secret generic nextcloud-stack-postgres \
    --from-literal=nextcloud-db-password='<new>' --dry-run=client -o yaml \
    | kubectl apply -f -
  # 2. change it in the DB
  kubectl -n nextcloud exec nextcloud-stack-postgres-0 -- \
    psql -U nextcloud -c "ALTER ROLE nextcloud WITH PASSWORD '<new>';"
  # 3. restart Nextcloud to pick up the new env
  kubectl -n nextcloud rollout restart deploy/nextcloud-stack
  ```
- **Valkey password.** Update the `<release>-valkey` Secret (both
  `valkey-password` and the `requirepass` in `valkey.conf`), then
  `kubectl -n nextcloud rollout restart deploy/nextcloud-stack-valkey deploy/nextcloud-stack`.
- **Metrics token.** Update `<release>-metrics`, re-run the serverinfo token step
  (`occ config:app:set serverinfo token`), then restart the exporter. See
  [Monitoring](monitoring.md).

`scripts/bootstrap-secrets.sh --force` can regenerate the standard secrets, but it
won't apply the DB-side change — do that step manually as above.

---

## Postgres major-version upgrades

The chart pins `postgres.image.tag`. **Major** upgrades (e.g. 17 → 18) aren't done
in place — Postgres needs `pg_upgrade` or a dump+restore. Dump+restore:

```bash
kubectl -n nextcloud scale deploy/nextcloud-stack --replicas=0
kubectl -n nextcloud exec nextcloud-stack-postgres-0 -- pg_dumpall -U nextcloud > dumpall.sql
helm uninstall nextcloud-stack -n nextcloud          # PVCs kept (resource-policy: keep)
kubectl -n nextcloud delete pvc data-nextcloud-stack-postgres-0   # postgres data ONLY
# bump postgres.image.tag in your values, then reinstall:
./scripts/bootstrap-secrets.sh -n nextcloud --force
helm install nextcloud-stack . -n nextcloud -f my-values.yaml
kubectl -n nextcloud cp dumpall.sql nextcloud-stack-postgres-0:/tmp/dumpall.sql
kubectl -n nextcloud exec nextcloud-stack-postgres-0 -- psql -U nextcloud -f /tmp/dumpall.sql
kubectl -n nextcloud scale deploy/nextcloud-stack --replicas=1
```

> Take a [backup](backup-and-restore.md) first. Deleting **only** the postgres PVC
> (not the data/webroot PVCs) is the careful part — double-check the name.

---

## Scaling down for maintenance

```bash
kubectl -n nextcloud scale deploy/nextcloud-stack --replicas=0   # frees the RWO PVCs
# … work that needs the volumes free, or a quiet DB …
kubectl -n nextcloud scale deploy/nextcloud-stack --replicas=1
```

---

## Why `kubectl exec`?

The cron and migration Jobs run `occ` by `kubectl exec`ing into the **live** Pod,
rather than mounting the PVC in a separate Pod. The data PVC is `ReadWriteOnce` and
held by the live Pod — a second mount would `Multi-Attach`. Exec sidesteps the
volume entirely. Those Jobs get a scoped Role: `pods/exec` on this Deployment only.

---

## Uninstall (and keeping data)

```bash
helm uninstall nextcloud-stack -n nextcloud
```

PVCs are `helm.sh/resource-policy: keep`, so **data survives**. To remove it,
delete the PVCs explicitly afterward — irreversible, so be sure.

---

← [Add-ons](add-ons.md) · [Wiki home](README.md) · Next: [Troubleshooting](troubleshooting.md)
