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
- **Image digests, not just tags.** Each image block in `values.yaml` accepts
  a `digest:` field (sha256:...). When set, the digest is preferred over the
  tag — this prevents tag-mutation attacks on a publicly-exposed install.
  Pin every image to a digest you've verified before going to production.
- **PodDisruptionBudget** with `maxUnavailable: 0` for the Nextcloud Pod.
  Node drains and cluster upgrades require explicit acknowledgement
  (`kubectl drain --force` or PDB deletion) rather than silently evicting
  the only replica.
- **`terminationGracePeriodSeconds: 120`** on the Nextcloud Pod so in-flight
  file uploads finish on rolling restarts instead of being SIGKILL'd at 30s.

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

```bash
# 1. Pre-create Secrets (recommended).
./charts/nextcloud-stack/scripts/bootstrap-secrets.sh \
    --namespace aio-test \
    --release nextcloud-stack

# 2. Render + dry-run to catch any issues.
helm template ./charts/nextcloud-stack \
    -n aio-test \
    -f ./charts/nextcloud-stack/example-values.yaml \
  | less

helm install --dry-run --debug nextcloud-stack ./charts/nextcloud-stack \
    -n aio-test --create-namespace \
    -f ./charts/nextcloud-stack/example-values.yaml

# 3. Real install.
helm install nextcloud-stack ./charts/nextcloud-stack \
    -n aio-test --create-namespace \
    -f ./charts/nextcloud-stack/example-values.yaml

# 4. Smoke test.
helm test nextcloud-stack -n aio-test
```

## Upgrade

```bash
helm upgrade nextcloud-stack ./charts/nextcloud-stack \
    -n aio-test \
    -f ./charts/nextcloud-stack/example-values.yaml
```

That's the entire upgrade procedure. **There is no re-apply checklist.** The
previous chart required three out-of-chart patches on every upgrade
(mod_remoteip, CronJob concurrencyPolicy, postupgrade Job). Each is gone:

| Old pain | Why it's gone |
|---|---|
| `mod_remoteip` ConfigMap patch | nginx is the front-end now. `set_real_ip_from` + `real_ip_header CF-Connecting-IP` live in `nginx.conf`, rendered by the chart. |
| `CronJob concurrencyPolicy: Allow → Forbid` patch | Chart sets `Forbid` directly. |
| `postupgrade` Job Multi-Attach failure | The db-migrate Job uses `kubectl exec` into the live Pod instead of mounting the RWO PVC. Multi-Attach is structurally impossible. |
| `apacheDefaultSiteConfig` not loaded by Apache | No Apache. nginx config is mounted at `/etc/nginx/nginx.conf`. |

## Migration from `groundhog2k/nextcloud`

Phase 2 of the cutover plan. Two paths, depending on whether you can afford
downtime for a data copy:

**A. Greenfield (recommended for testing):** install the new chart in a
fresh `aio-test` namespace with empty PVCs. Verify it works end-to-end. Cut
the CF Tunnel over, then `helm uninstall nextcloud -n aio`. Done.

**B. Reuse existing data:** scale the old Deployment to zero, detach the
existing PVCs, set `nextcloud.persistence.{webroot,data}.existingClaim` in
the chart values to point at them, and install. The chart's
`schemaFixHook` Job idempotently fixes ownership if the old DB user wasn't
the schema owner.

```bash
# Greenfield outline:
kubectl scale deploy/nextcloud -n aio --replicas=0
helm install nextcloud-stack ./charts/nextcloud-stack -n aio-test ...
# verify
# update CF Public Hostname target
helm uninstall nextcloud -n aio
kubectl delete pvc --all -n aio
```

See `DEPLOYMENT_PLAN.md` §16 ("clean reset procedure") for the canonical
teardown.

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

# 6. Re-install. The initdb script creates the role + db fresh.
./charts/nextcloud-stack/scripts/bootstrap-secrets.sh -n aio --force
helm install nextcloud-stack ./charts/nextcloud-stack -n aio -f my-values.yaml

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
- Automated dump+restore on a Helm hook would mount the RWO PVC twice (the v1.11
  Multi-Attach problem). Operator-driven with explicit downtime is the safe path.

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
kubectl -n <ns> logs deploy/<rel>-nextcloud-stack -c php --tail=200 -f
```

Common cause on a re-used PVC: `partial install detected`. Either let it
finish (Nextcloud retries) or run a manual install per
`DEPLOYMENT_PLAN.md` §12.1.

### nginx logs show `10.1.*` as client IP, not the real IP

`real_ip_header` is the wrong name, or the request didn't come through
Cloudflare. Check that the CF Tunnel sets `CF-Connecting-IP` (it does by
default for the Free plan), and that
`nextcloud.web.realIp.trustedCidr` actually covers the cloudflared pod IPs.

### Helm hook Job stuck pending or failing

Check the Job pod logs:
```bash
kubectl -n <ns> get jobs
kubectl -n <ns> logs job/<rel>-nextcloud-stack-db-migrate
```

If the rollout takes >5 minutes, raise
`nextcloud.dbMigrateJob.activeDeadlineSeconds`.
