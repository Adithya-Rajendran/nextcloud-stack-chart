# nextcloud-stack

Homegrown Helm chart for Nextcloud on Kubernetes. Replaces
`groundhog2k/nextcloud` and the standalone `manifests/clamav/clamav.yaml`.
The whole stack lives here, in templates we own — no subcharts, no
out-of-chart patches, no re-apply checklist on upgrade.

## What's in it

| Component | Image | Notes |
|---|---|---|
| `php`   | `ghcr.io/adithya-rajendran/nextcloud-fpm:33.0.3-fpm` | PHP-FPM. Only custom image in the chart. Built by [nextcloud-images](../../nextcloud-images). |
| `web`   | `dhi.io/nginx:1-compat` | Sidecar in the same Pod. Listens 8080. `1-compat` (not `:1`) because the init container needs `/bin/sh`. |
| `postgres` | `dhi.io/postgres:18` | StatefulSet, single replica, RWO Cinder. UID 70 (postgres). |
| `valkey` | `dhi.io/valkey:9` | Redis-wire-compatible. Auth on by default. UID 65532. |
| `clamav` | `dhi.io/clamav:1.5-base` | UID 65532. Uses `docker-entrypoint-unprivileged.sh` to skip the root-only chown step. |
| `kubectl` | `dhi.io/kubectl:1` | Used by the cron CronJob + post-install db-migrate Job. Distroless. |
| `curl` | `dhi.io/curl:8-alpine3.23` | Used by `helm test`. Distroless. |

## What's deliberately NOT in it

- **Collabora, Whiteboard, Cloudflared, AFFiNE** — stay as standalone
  manifests under `manifests/`. They have independent lifecycles and don't
  share state with this chart.
- **Cert-manager, Ingress** — Cloudflare Tunnel terminates TLS upstream. The
  origin Service is plain HTTP, ClusterIP.

## Topology, at a glance

```
                CF Tunnel               (NetworkPolicy gate: from=cf-tunnel/cloudflared)
                    │
                    ▼  http://<svc>.<ns>.svc.cluster.local:80
        ┌───────────────────────────┐
        │  Pod  (Recreate, RWO)     │
        │  ┌─────────┐  ┌────────┐  │
        │  │   web   │──│  php   │  │  127.0.0.1:9000
        │  │ nginx   │  │ fpm    │  │
        │  └─────────┘  └────────┘  │
        │       │  shared webroot   │
        │       │  PVC (RWO,10Gi)   │
        │       │  data PVC (100Gi) │
        └───────┼───────────────────┘
                │
       ┌────────┼────────┬─────────┐
       ▼        ▼        ▼         ▼
   postgres  valkey   clamav   (egress: 443/80 with allowAllEgress)
   (5432)   (6379)   (3310)
```

## Security model

- **No secrets in values.yaml** by default. Bootstrap them out-of-band with
  [`scripts/bootstrap-secrets.sh`](scripts/bootstrap-secrets.sh), then point
  the chart at them via `*.auth.existingSecret`. This keeps secret material
  out of Helm release metadata.
- **Pod-level `runAsNonRoot`** everywhere. All DHI images run as their
  designated non-root user from start (UIDs: nginx/valkey/clamav/curl/kubectl
  = 65532, postgres = 70, nextcloud-fpm = 33).
- **`readOnlyRootFilesystem: true`** on nginx, postgres-schema-fix Job,
  cronjob, db-migrate Job, helm-test Pod. Anywhere the application doesn't
  need to write to its own image.
- **`drop: ["ALL"]`** capabilities, `allowPrivilegeEscalation: false`,
  `seccompProfile: RuntimeDefault` on every container.
- **NetworkPolicies on by default.** Default-deny + per-component allows.
  The Nextcloud Pod only accepts ingress from `cf-tunnel/cloudflared`.
  Postgres/Valkey/ClamAV only accept ingress from the Nextcloud Pod.
- **Valkey config in a Secret**, not a ConfigMap — the `requirepass` line
  doesn't end up in a cluster-readable resource.
- **`automountServiceAccountToken: false`** on every Pod that doesn't talk to
  the K8s API. A popped fpm/nginx/postgres container gets no cluster credentials
  for free. The cron + db-migrate Jobs DO mount their token (needed for
  `kubectl exec`) and use a scoped Role (only `pods/exec` on the nextcloud
  Deployment, namespace-local).
- **Image digests, not just tags.** Every image block in `values.yaml`
  accepts a `digest:` field (sha256:...). When set, the digest is preferred
  over the tag — this prevents tag-mutation attacks on a publicly-exposed
  install. Run `./scripts/pin-digests.sh > pins.yaml` to resolve every
  image's current digest and apply with a second `-f pins.yaml`.
- **PodDisruptionBudget** with `maxUnavailable: 0` for the Nextcloud Pod.
  Node drains and cluster upgrades require explicit acknowledgement
  (`kubectl drain --force` or PDB deletion) rather than silently evicting
  the only replica.
- **`terminationGracePeriodSeconds: 120`** on the Nextcloud Pod so in-flight
  file uploads finish on rolling restarts instead of being SIGKILL'd at 30s.

### Threat model

The chart's NetworkPolicy is load-bearing. It's the only thing keeping
- unauthenticated PHP-FPM on 9000 from being reachable by other pods,
- in-cluster pods from spoofing `CF-Connecting-IP` through nginx,
- Nextcloud-database traffic (plaintext) from being readable by
  in-cluster sniffers.

If your CNI doesn't enforce v1 NetworkPolicy (or you turn enforcement
off for debugging and forget to turn it back on), every one of those
controls is silently gone. Cilium with default config enforces.
Calico does. The flannel default DOES NOT — flannel needs a separate
policy enforcer.

### Cluster assumptions

The chart defaults assume Canonical K8s / Cilium. Two values are
cluster-specific and fail silently if wrong:

- `nextcloud.web.realIp.trustedCidr` — pod CIDR of the `cloudflared`
  pods. If it doesn't match this cluster's pod CIDR, nginx ignores
  `CF-Connecting-IP` from every request and every access log shows the
  cloudflared pod IP as the client.
- `networkPolicy.inClusterCidrs` — list of in-cluster CIDRs excluded
  from the public-egress fallback rule. Should include BOTH the pod
  CIDR and the Service CIDR. If the Service CIDR is missing, egress
  from Nextcloud to in-cluster ClusterIP VIPs on 80/443 escapes
  through the public lane.

Find both with:
```bash
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
kubectl cluster-info dump | grep -m1 service-cluster-ip-range
```
Set them before the first install — `helm install`'s NOTES output
prints whatever you have configured, so you can sanity-check there too.

### Apply the PodSecurityStandards `restricted` profile

Label the namespace so admission rejects any deviation:

```bash
kubectl label namespace aio-test \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest
```

The chart's Pods are already restricted-compatible. The label means any future
ad-hoc manifest you `kubectl apply` into this namespace must also comply.

## Install

These commands assume you're running them from the chart root (the
directory that contains this README). Replace `.` with the path to the
extracted chart if you're installing from a downloaded tarball.

```bash
# 1. Pre-create Secrets (recommended).
./scripts/bootstrap-secrets.sh \
    --namespace aio-test \
    --release nextcloud-stack

# 2. (Optional) pin every image to its current digest.
./scripts/pin-digests.sh > pins.yaml

# 3. Render + dry-run to catch any issues.
helm template . \
    -n aio-test \
    -f example-values.yaml \
    -f pins.yaml \
  | less

helm install --dry-run --debug nextcloud-stack . \
    -n aio-test --create-namespace \
    -f example-values.yaml \
    -f pins.yaml

# 4. Real install.
helm install nextcloud-stack . \
    -n aio-test --create-namespace \
    -f example-values.yaml \
    -f pins.yaml

# 5. Smoke test.
helm test nextcloud-stack -n aio-test
```

Drop the `-f pins.yaml` lines if you don't want digest pinning (the
chart still installs, but images are referenced by mutable tag).

## Upgrade

```bash
helm upgrade nextcloud-stack . \
    -n aio-test \
    -f example-values.yaml \
    -f pins.yaml
```

> **DO NOT** change `nameOverride` or `fullnameOverride` after the first
> install. The chart's selectorLabels derive from these values, and
> Kubernetes Deployment selectors are immutable — a changed selector
> means `helm upgrade` fails with "field is immutable" and you have to
> delete and re-create the Deployment (data PVCs are kept).

That's the entire upgrade procedure. **There is no re-apply checklist.** The
previous chart required three out-of-chart patches on every upgrade
(mod_remoteip, CronJob concurrencyPolicy, postupgrade Job). Each is gone:

| Old pain | Why it's gone |
|---|---|
| `mod_remoteip` ConfigMap patch | nginx is the front-end now. `set_real_ip_from` + `real_ip_header CF-Connecting-IP` live in `nginx.conf`, rendered by the chart. |
| `CronJob concurrencyPolicy: Allow → Forbid` patch | Chart sets `Forbid` directly. |
| `postupgrade` Job Multi-Attach failure | The db-migrate Job uses `kubectl exec` into the live Pod instead of mounting the RWO PVC. Multi-Attach is structurally impossible. |
| `apacheDefaultSiteConfig` not loaded by Apache | No Apache. nginx config is mounted at `/etc/nginx/nginx.conf`. |

## Migration from a previous chart

Two paths:

**A. Greenfield (recommended).** Install this chart in a fresh
namespace with empty PVCs. Verify it works end-to-end. Point your
Cloudflare Tunnel at the new Service, then uninstall the old release.

**B. Reuse existing data.** Scale the old release to zero, then set
`nextcloud.persistence.webroot.existingClaim` and
`nextcloud.persistence.data.existingClaim` in your values to point at
the existing PVCs. Install. On the first boot, Nextcloud opens the
existing data with the configured admin credentials (the bootstrap
Secret must match the existing instance's password, or you'll have to
reset it via `occ user:resetpassword admin`).

## Postgres major-version upgrades (out-of-chart)

The chart pins `postgres.image.tag: "18"`. When DHI publishes 19 and you want
to move, **the chart does not handle major-version upgrades**. Postgres
major upgrades require either `pg_upgrade` (in-place, complex and image-version
specific) or a dump+restore.

Recommended procedure (dump+restore):

```bash
# 1. Scale Nextcloud to 0 so the DB isn't being written to.
kubectl -n aio scale deploy/nextcloud-stack --replicas=0

# 2. Dump the current cluster.
kubectl -n aio exec nextcloud-stack-postgres-0 -- \
    pg_dumpall -U postgres > /tmp/dumpall.sql

# 3. Uninstall the chart (PVCs are kept by resource-policy: keep).
helm uninstall nextcloud-stack -n aio

# 4. Delete the postgres data PVC ONLY (keep the Nextcloud webroot + data).
kubectl -n aio delete pvc data-nextcloud-stack-postgres-0

# 5. Bump postgres.image.tag in my-values.yaml to the new major.

# 6. Re-install. The Postgres bootstrap env vars create the role + db fresh.
./scripts/bootstrap-secrets.sh -n aio --force
helm install nextcloud-stack . -n aio -f my-values.yaml

# 7. Wait for postgres-0 to be Ready, then restore.
kubectl -n aio cp /tmp/dumpall.sql nextcloud-stack-postgres-0:/tmp/dumpall.sql
kubectl -n aio exec nextcloud-stack-postgres-0 -- \
    psql -U postgres -f /tmp/dumpall.sql

# 8. Scale Nextcloud back up.
kubectl -n aio scale deploy/nextcloud-stack --replicas=1
```

This is operator work, not chart automation, because:
- pg_upgrade requires both old + new postgres binaries in one image, which DHI
  doesn't publish.
- Automated dump+restore on a Helm hook would mount the RWO PVC twice and
  Multi-Attach. Operator-driven with explicit downtime is the safe path.

## Backups

The chart does not configure backups. This is intentional — a backup
that no one tests is worse than no backup — but **don't skip this**.
The single-operator self-hosted workload is exactly the one most likely
to forget.

The two minimums you should script outside this chart:

```bash
# 1. Postgres logical dump. Run from a sibling CronJob in the same namespace,
#    or from operator workstation on a schedule.
kubectl -n <ns> exec <rel>-postgres-0 -- \
    pg_dumpall -U <user> > nextcloud-pg-$(date +%F).sql

# 2. Data PVC snapshot (Cinder CSI VolumeSnapshot). Operator-driven, e.g.:
kubectl -n <ns> create -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: nextcloud-data-$(date +%F)
spec:
  volumeSnapshotClassName: csi-cinder-snapshotclass
  source:
    persistentVolumeClaimName: <rel>-data
EOF
```

Velero, Stash, or a homegrown CronJob+rclone all work; pick one and
restore-test it quarterly. If you don't restore-test, you don't have
backups.

## Secret rotation

The chart references external Secrets, so rotation is operator-driven.

- **Admin password.** Change via the Nextcloud web UI. The Secret is for
  the *initial* admin install only; once Nextcloud has stored the
  hashed password in its DB, the Secret value isn't re-read.
- **Postgres password.** Update the Secret, then
  `kubectl -n <ns> rollout restart deploy/<rel>` for the Nextcloud pod
  to pick up the new value AND `kubectl -n <ns> exec <rel>-postgres-0
  -- psql -c "ALTER ROLE <user> WITH PASSWORD '<new>';"` for the DB
  side. Plan a short outage window — order matters.
- **Valkey password.** Update the Secret, then
  `kubectl -n <ns> rollout restart deploy/<rel>-valkey deploy/<rel>`.
  The valkey config is mounted from a Secret and the Nextcloud config
  reads the password from an env var — both pods need to roll.

## Values reference

See [`values.yaml`](values.yaml) for the full surface. Most users only need
to touch:

- `nextcloud.admin.existingSecret`
- `nextcloud.settings.overwriteHost` / `trustedDomains`
- `postgres.auth.existingSecret`
- `valkey.auth.existingSecret`
- `nextcloud.persistence.*.size`
- `networkPolicy.cfTunnel.namespace`

`example-values.yaml` next to this file is a working minimal config.

## Why a post-upgrade hook (not pre-upgrade) for DB migrations?

Pre-upgrade fires *before* Helm rolls the new image. The migrations need to
run against the upgraded code, so the timing is wrong. Post-upgrade fires
after the new Pod is Ready — that's when the migrations should run. The
chart spec said "PreUpgrade hook"; the implementation deviates here for
correctness. The hook annotation is `helm.sh/hook: post-install,post-upgrade`.

## Why `kubectl exec` for the migration / cron Jobs?

Because they need to talk to a Nextcloud install on an RWO Cinder PVC. The
PVC is held by the live Pod. If a Job mounts it concurrently, Cinder rejects
the second attachment (Multi-Attach error) — exactly the v1.11 bug. Exec'ing
into the live Pod sidesteps the volume layer entirely.

A scoped `Role` grants the Job's ServiceAccount `pods/exec` only on this
Deployment's pods, in this namespace — minimum privilege.

## Troubleshooting

### `helm install` complains about missing secret material

You didn't set `existingSecret` or inline password, and `secrets.autoGenerate`
is false. Run `scripts/bootstrap-secrets.sh`.

### Pod stuck in `Init:0/1` (`wait-for-postgres`)

Postgres pod isn't reachable. Check:
```bash
kubectl -n <ns> get pod -l app.kubernetes.io/component=postgres
kubectl -n <ns> logs <postgres-pod>
```

### `/status.php` returns `installed:false` after long wait

Nextcloud's first-install `occ` step hasn't completed. Tail the php container:
```bash
kubectl -n <ns> logs deploy/<rel> -c php --tail=200 -f
```

Common cause on a re-used PVC: `partial install detected`. Either let it
finish (Nextcloud retries) or rerun the install manually:
```bash
kubectl -n <ns> exec deploy/<rel> -c php -- \
    php -f /var/www/html/occ -- maintenance:install \
        --database pgsql --database-host <rel>-postgres \
        --database-name nextcloud --database-user nextcloud \
        --database-pass "$PG_PASSWORD" \
        --admin-user admin --admin-pass "$ADMIN_PASSWORD"
```

### nginx logs show pod IPs instead of real client IPs

`real_ip_header` is the wrong name, or the request didn't come through
Cloudflare. Check that the CF Tunnel sets `CF-Connecting-IP` (it does by
default for the Free plan), and that
`nextcloud.web.realIp.trustedCidr` actually covers the cloudflared pod IPs.
The chart's `helm install` NOTES print the configured value as a
sanity-check.

### Helm hook Job stuck pending or failing

Check the Job pod logs:
```bash
kubectl -n <ns> get jobs
kubectl -n <ns> logs job/<rel>-nextcloud-stack-db-migrate
```

If the rollout takes >5 minutes, raise
`nextcloud.dbMigrateJob.activeDeadlineSeconds`.
