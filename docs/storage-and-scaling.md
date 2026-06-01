# Storage & Scaling

Sizing volumes, growing them later, choosing a StorageClass, and the realities of
scaling this stack.

---

## The volumes

| PVC | Default size | Holds | Class |
|---|---|---|---|
| `<release>-data` | **100Gi** | user files (the big one) | `nextcloud.persistence.data.storageClassName` |
| `<release>-webroot` | 10Gi | Nextcloud code + `config/` | `nextcloud.persistence.webroot.storageClassName` |
| `data-<release>-postgres-0` | 10Gi | the database | `postgres.persistence.storageClassName` |

All are `ReadWriteOnce` and annotated `helm.sh/resource-policy: keep` (they survive
`helm uninstall`). Set sizes at install time:

```yaml
nextcloud:
  persistence:
    data:    { size: 200Gi, storageClassName: fast-rbd }
    webroot: { size: 10Gi }
postgres:
  persistence: { size: 20Gi }
```

An empty `storageClassName` uses the cluster's default StorageClass
(`kubectl get storageclass`).

---

## Choosing a StorageClass

- **Reclaim policy matters.** A `Delete`-reclaim class means deleting the PVC
  destroys the data. A `Retain` class keeps the underlying volume — safer for the
  data PVC. Check: `kubectl get storageclass <name> -o jsonpath='{.reclaimPolicy}'`.
- **Expandable?** If you might grow volumes later (you usually will), pick a class
  with `allowVolumeExpansion: true` — see below.
- **Performance.** The data PVC sees the most I/O; put it on your fastest block
  storage. Postgres benefits from low-latency storage too.

---

## Expanding a PVC

> Short answer to "how do I make the data volume bigger?": raise the size in your
> values and `helm upgrade` — **if** the StorageClass allows expansion. You can
> only **grow** a PVC, never shrink it.

### 1. Confirm the StorageClass allows it

```bash
kubectl get storageclass <class> \
  -o custom-columns='NAME:.metadata.name,EXPAND:.allowVolumeExpansion'
```

If `EXPAND` is not `true`, you can't expand in place — you'd migrate to a bigger
volume instead (provision a new PVC, copy data, repoint). Most CSI drivers
(Ceph RBD, AWS EBS, etc.) support expansion.

### 2. Raise the size through the chart (recommended)

Because the PVCs are **Helm-managed**, change the value — not just the live object —
so the next `helm upgrade` doesn't try to set it back (Kubernetes rejects
shrinking, which would error your upgrade):

```yaml
nextcloud:
  persistence:
    data:
      size: 200Gi      # was 100Gi
```

```bash
helm upgrade nextcloud-stack . -n nextcloud -f my-values.yaml
```

Helm patches `spec.resources.requests.storage`; the CSI driver expands the volume
and the filesystem. Many drivers (e.g. Ceph RBD) do this **online** — no Pod
restart, no downtime.

### 3. Watch it land and verify

```bash
kubectl -n nextcloud get pvc nextcloud-stack-data -w      # capacity grows
kubectl -n nextcloud exec deploy/nextcloud-stack -c php -- df -h /var/www/html/data
```

If you see a PVC condition `FileSystemResizePending`, the volume grew but the
filesystem resize needs the Pod to restart (some drivers resize offline):

```bash
kubectl -n nextcloud rollout restart deploy/nextcloud-stack
```

### Direct-patch alternative

Same result without editing values — **but you must still update the chart value
afterward** to keep Helm consistent:

```bash
kubectl -n nextcloud patch pvc nextcloud-stack-data \
  -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
```

### Changing the *default* for new installs

`nextcloud.persistence.data.size` in `values.yaml` (or your overlay) only affects
**newly created** PVCs. An existing volume only grows via the upgrade/patch above.

---

## Resource sizing

Every component has a `resources` block (requests + limits). Defaults suit a
small-to-medium instance:

| Component | Requests | Limits |
|---|---|---|
| php (fpm) | 250m / 512Mi | 2 / 4Gi |
| web (nginx) | 50m / 64Mi | 1 / 256Mi |
| postgres | 100m / 256Mi | 1 / 1Gi |
| valkey | 50m / 64Mi | 500m / 512Mi |
| **clamav** | 250m / 1Gi | 2 / **3Gi** | 

ClamAV is the memory hog (it loads the full signature DB). If you're tight on
memory and don't need on-upload AV, set `clamav.enabled: false`. Bump fpm and
postgres limits for heavier instances.

---

## High availability and replicas

Be clear-eyed about what scales here:

- **Nextcloud core is single-Pod.** The php + nginx containers share an RWO PVC,
  so `nextcloud.replicas` stays `1` and the Deployment uses `strategy: Recreate`.
  True multi-replica Nextcloud needs RWX storage for the data dir plus shared
  locking — out of scope for this chart's default design. The single Pod is still
  resilient (restarts, reschedules); the PodDisruptionBudget
  (`maxUnavailable: 0`) guards it during node drains.
- **Postgres is single-replica** (a StatefulSet). For DB HA, run an external
  Postgres operator and point the chart at it (set `postgres.enabled: false` and
  configure the connection) — or accept single-instance + good backups.
- **Whiteboard *does* scale** — `replicas: 2+` with `storageStrategy: redis` shares
  live board state through Valkey. See [Add-ons › Whiteboard](add-ons.md#whiteboard).
- **cloudflared** runs 2 replicas by default for tunnel redundancy.

For most self-hosters, the right resilience strategy here is **solid backups +
fast restore**, not multi-master. See [Backup & Restore](backup-and-restore.md).

---

## Node placement

Whiteboard ships `topologySpreadConstraints` (`ScheduleAnyway`) to spread its
replicas across nodes. Add your own `nodeSelector`/`affinity`/`tolerations` via the
per-component `podAnnotations`/`podLabels` and standard values where present, or
pin storage to a zone via the StorageClass.

---

← [Security Model](security.md) · [Wiki home](README.md) · Next: [Backup & Restore](backup-and-restore.md)
