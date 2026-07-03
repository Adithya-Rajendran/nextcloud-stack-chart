# nextcloud-stack

A self-hostable Helm chart for Nextcloud on Kubernetes: PHP-FPM + nginx in one
Pod, Postgres, Valkey, and optional ClamAV — all in templates we own, no
subcharts, no out-of-chart patches, no re-apply checklist on upgrade.

It's **security-first**: every image defaults to a [Docker Hardened Image](https://www.docker.com/products/hardened-images/)
(`dhi.io/*`) — minimal, non-root, CVE-scanned. That's the differentiator. Prefer plain Docker Hub
images? A one-line overlay (`-f values-public.yaml`) swaps in public Docker
Hub images. Expose Nextcloud through your choice of **Ingress**, **Gateway API**,
or the optional **Cloudflare tunnel addon**.

> 📖 **New here? Read the [full documentation wiki in `docs/`](docs/README.md)** —
> a friendly, task-oriented guide: [Getting Started](docs/getting-started.md),
> [Installation](docs/installation.md), [Configuration](docs/configuration.md),
> [Exposure & TLS](docs/exposure-and-tls.md), [Security](docs/security.md),
> [Storage & Scaling](docs/storage-and-scaling.md),
> [Backup & Restore](docs/backup-and-restore.md), [Monitoring](docs/monitoring.md),
> [Operations](docs/operations.md), [Troubleshooting](docs/troubleshooting.md), and
> the [FAQ](docs/faq.md). This README is the quick reference.

## What's in it

| Component | Default image (DHI) | Notes |
|---|---|---|
| `php`   | `ghcr.io/adithya-rajendran/nextcloud-fpm:33.0.5-fpm` | PHP-FPM. The only custom image (public on GHCR). Built by [nextcloud-images](https://github.com/adithya-rajendran/nextcloud-images). UID 33. |
| `web`   | `dhi.io/nginx:1-compat` | Sidecar in the same Pod. Listens 8080. UID 65532. |
| `postgres` | `dhi.io/postgres:18` | StatefulSet, single replica, RWO. UID 70. |
| `valkey` | `dhi.io/valkey:9` | Redis-wire-compatible. Auth on by default. UID 65532. |
| `clamav` | `dhi.io/clamav:1.5-base` | On-upload AV (heavy). Unprivileged entrypoint, UID 65532. |
| `kubectl` | `dhi.io/kubectl:1` | Cron CronJob + post-install db-migrate Job. Distroless; entrypoint is `kubectl`. |
| `curl` | `dhi.io/curl:8-alpine3.23` | `helm test`. |
| `cloudflared` | `cloudflare/cloudflared:2024.12.2` | **Only with the Cloudflare addon.** No DHI image exists; upstream distroless, UID 65532. |

> **Prefer plain Docker Hub images?** Pass `-f values-public.yaml` to swap
> every image for a public Docker Hub equivalent (nginx-unprivileged, postgres,
> valkey, rancher/kubectl, curlimages/curl). No pull secret needed. The DHI images
> only need a **free** Docker account (no paid subscription) plus an `imagePullSecret`
> (see [Install](#install)).

## What's deliberately NOT in it

- **Collabora, Whiteboard, AFFiNE** — independent lifecycles, no shared state
  with this chart. Run them separately.
- **cert-manager / a Gateway / an ingress controller** — the chart renders an
  Ingress or HTTPRoute, but you bring the controller/Gateway and (for Ingress)
  the TLS issuer.

## Topology, at a glance

```
   Ingress / Gateway API / Cloudflare tunnel   (you pick one; all optional)
                    │  TLS terminated here
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
       ┌────────┼─────────┐
       ▼        ▼         ▼
   postgres  valkey   clamav*    (* optional; egress to 443/80 with allowAllEgress)
   (5432)   (6379)   (3310)
```

The origin Service stays ClusterIP. Whatever fronts it (ingress controller,
Gateway, or cloudflared) terminates TLS and forwards plain HTTP; the chart's
nginx forces `HTTPS=on` to PHP-FPM so Nextcloud emits `https://` URLs and Secure
cookies (toggle: `nextcloud.web.httpsBehindProxy`).

## Exposing Nextcloud

Enable exactly one. All are disabled by default (Service is ClusterIP).

**Ingress**
```yaml
ingress:
  enabled: true
  className: nginx
  host: cloud.yourdomain.com
  tls: { enabled: true, secretName: cloud-tls }
```

**Gateway API (HTTPRoute)**
```yaml
gatewayApi:
  enabled: true
  parentRef: { name: my-gateway, namespace: gateway-system }
  hostnames: [cloud.yourdomain.com]
```

**Cloudflare tunnel addon** — deploys `cloudflared` from a tunnel token and
switches real-IP handling to `CF-Connecting-IP`:
```yaml
cloudflare:
  enabled: true
  tunnel:
    enabled: true
    existingSecret: nextcloud-stack-cloudflared   # key: tunnel-token
  realIp:
    trustedCidrs: [10.0.0.0/8]                     # cloudflared pod CIDR
```
Create the token Secret with `scripts/bootstrap-secrets.sh --cloudflare-token '<TOKEN>'`,
then point the tunnel's Public Hostname at
`http://<release>.<ns>.svc.cluster.local:80` in the Cloudflare dashboard. To run
cloudflared yourself instead, set `cloudflare.tunnel.enabled: false` and fill
`cloudflare.externalTunnel.{namespace,podLabel}`.

> **NetworkPolicy (Cilium):** the chart renders **CiliumNetworkPolicy**
> (`cilium.io/v2`), so it **requires Cilium**. The Cilium **Gateway** is allowed
> automatically when `gatewayApi.enabled` (via `fromEntities: [ingress]` — standard
> NetworkPolicy v1 can't select the gateway proxy's identity, which is why a
> Gateway-fronted install needs the Cilium policy). The Cloudflare addon adds its
> own source automatically. For any **other** front (e.g. a separate ingress
> controller) add it to `networkPolicy.nextcloudIngressFrom` as a Cilium ingress
> selector:
> ```yaml
> networkPolicy:
>   nextcloudIngressFrom:
>     - fromEndpoints:
>         - matchLabels: { k8s:io.kubernetes.pod.namespace: ingress-nginx }
> ```
> On a non-Cilium policy-enforcing CNI (Calico, kube-router, …) set
> `networkPolicy.flavor: kubernetes` to render standard `networking.k8s.io/v1`
> NetworkPolicies instead (with the documented approximations — see
> [Security](docs/security.md)). Only set `networkPolicy.enabled: false` if you
> have no policy enforcement at all and will manage isolation yourself.

## Real client IP

nginx rewrites the connection source from a forwarded header, but only for
requests arriving from `nextcloud.web.realIp.trustedCidrs` (your proxy's pod
CIDR). Two modes:

- **Generic (default):** `X-Forwarded-For` walked recursively
  (`recursive: true`). This is what ingress controllers and gateways emit.
- **Cloudflare (`cloudflare.enabled`):** the single-valued `CF-Connecting-IP`
  with recursion off — set automatically.

If `trustedCidrs` is empty, the rewrite is disabled entirely and Nextcloud sees
the proxy IP (safe — nothing can spoof the header). The chart **fails render** if
a multi-valued header is paired with `recursive: false`, which would be spoofable
(`nextcloud-stack.requireSafeRealIp`).

## Security model

- **No secrets in values.yaml.** Bootstrap them out-of-band with
  [`scripts/bootstrap-secrets.sh`](scripts/bootstrap-secrets.sh), then point the
  chart at them via `*.auth.existingSecret`. Keeps secret material out of Helm
  release metadata. The chart fails render if a required `existingSecret` is empty.
- **`runAsNonRoot` everywhere.** With the default DHI images, nginx/valkey/clamav
  and the cron/migrate/test/cloudflared pods run as UID 65532, postgres as 70, fpm
  as 33. (The public overlay uses the public images' UIDs: nginx 101, valkey 999,
  clamav 100.)
- **`readOnlyRootFilesystem: true`** wherever the app doesn't need to write its
  own image (nginx, valkey, kubectl, curl, cloudflared).
- **`drop: ["ALL"]`**, `allowPrivilegeEscalation: false`,
  `seccompProfile: RuntimeDefault` on every container.
- **CiliumNetworkPolicy on by default** (requires Cilium). Default-deny +
  per-component allows. The Nextcloud Pod accepts ingress from the Cilium gateway
  (`fromEntities: [ingress]` when `gatewayApi.enabled`), the Cloudflare source, and
  anything in `networkPolicy.nextcloudIngressFrom`. Postgres/Valkey/ClamAV only
  accept ingress from the Nextcloud Pod; public egress uses Cilium's identity-based
  `world` entity (no CIDR list to maintain).
- **Valkey config in a Secret**, not a ConfigMap — `requirepass` never lands in a
  cluster-readable resource.
- **`automountServiceAccountToken: false`** on every Pod that doesn't talk to the
  K8s API. The cron + db-migrate Jobs use a scoped Role (only `pods/exec` on the
  nextcloud Deployment, namespace-local).
- **Image digests, not just tags.** Every image block accepts a `digest:` field;
  `./scripts/pin-digests.sh > pins.yaml` resolves them all. Apply with an extra
  `-f pins.yaml`.
- **PodDisruptionBudget** (`maxUnavailable: 0`) and
  **`terminationGracePeriodSeconds: 120`** for the Nextcloud Pod.

### Threat model

The chart's NetworkPolicy is load-bearing. It's the only thing keeping
- unauthenticated PHP-FPM on 9000 from being reachable by other pods,
- in-cluster pods from spoofing the forwarded real-IP header through nginx
  (`set_real_ip_from` trusts only `trustedCidrs`),
- Nextcloud↔database traffic (plaintext) from in-cluster sniffers.

By default the chart renders **CiliumNetworkPolicy** (`cilium.io/v2`), so the
default needs Cilium. This is deliberate: only the Cilium policy can express
`fromEntities: [ingress]` to allow a **Cilium** Gateway proxy. On a non-Cilium
policy-enforcing CNI set `networkPolicy.flavor: kubernetes` to render standard
`networking.k8s.io/v1` policies instead (with the documented approximations — a
non-Cilium gateway/ingress front must be added to `nextcloudIngressFrom`). Only
set `networkPolicy.enabled: false` if you have no policy enforcement at all —
otherwise every one of those controls is silently gone.

With the generic `X-Forwarded-For` mode, `recursive: true` means nginx walks the
chain skipping trusted hops — so `trustedCidrs` must cover **every** proxy hop in
front of nginx, and those proxies must append (not blindly trust) the header.
A single trusted hop (one ingress controller / gateway) is the common, safe case.

### Cluster assumptions

One value is cluster-specific:

- `nextcloud.web.realIp.trustedCidrs` (default empty) — your proxy's pod CIDR.
  Empty means real-IP rewriting is off and logs show the proxy pod IP.

```bash
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
```

(`networkPolicy` no longer needs an in-cluster CIDR list — Cilium's identity-based
`world` entity defines "outside the cluster" directly, replacing the old
`inClusterCidrs` exception block.)

### Apply the PodSecurityStandards `restricted` profile

```bash
kubectl label namespace nextcloud \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest
```
The chart's Pods are restricted-compatible.

## Install

Run from the chart root (the directory with this README).

```bash
# 1. Pre-create Secrets.
./scripts/bootstrap-secrets.sh --namespace nextcloud --release nextcloud-stack

# 2. DHI pull secret (default images live on dhi.io — a FREE Docker account).
#    For public images instead: skip this and add `-f values-public.yaml` below.
kubectl -n nextcloud create secret docker-registry dhi-pull \
    --docker-server=dhi.io --docker-username=<user> \
    --docker-password='<docker-pat>' --docker-email=<email>

# 3. (Optional) pin every image to its current digest.
./scripts/pin-digests.sh > pins.yaml

# 4. Render to eyeball it.
helm template . -n nextcloud -f example-values.yaml -f pins.yaml | less

# 5. Install. example-values.yaml exposes via Ingress — edit host/class first.
helm install nextcloud-stack . \
    -n nextcloud --create-namespace -f example-values.yaml -f pins.yaml

# 6. Smoke test.
helm test nextcloud-stack -n nextcloud
```

Drop `-f pins.yaml` to skip digest pinning. To use public Docker Hub images
instead, skip the pull secret and add `-f values-public.yaml` to the
`helm template`/`helm install` commands.

## Upgrade

```bash
helm upgrade nextcloud-stack . -n nextcloud -f example-values.yaml -f pins.yaml
```

> **DO NOT** change `nameOverride`/`fullnameOverride` after the first install —
> Deployment selectors are immutable, so a changed selector breaks `helm upgrade`.

There is no re-apply checklist. nginx serves the real client IP via
`set_real_ip_from`; the CronJob sets `concurrencyPolicy: Forbid` directly; DB
migrations run as a post-upgrade Hook Job via `kubectl exec` (no Multi-Attach).

## Migration from a previous chart

**A. Greenfield (recommended).** Install into a fresh namespace with empty PVCs,
verify end-to-end, repoint your exposure (Ingress/Gateway/tunnel) at the new
Service, then uninstall the old release.

**B. Reuse existing data.** Scale the old release to zero, set
`nextcloud.persistence.webroot.existingClaim` and `…data.existingClaim` to the
existing PVCs, and install (the bootstrap admin Secret must match the existing
instance's password, or reset it via `occ user:resetpassword admin`).

## Postgres major-version upgrades (out-of-chart)

The chart pins `postgres.image.tag`. Major upgrades are **not** handled by the
chart — they need `pg_upgrade` or dump+restore. Dump+restore procedure:

```bash
kubectl -n <ns> scale deploy/nextcloud-stack --replicas=0
kubectl -n <ns> exec nextcloud-stack-postgres-0 -- pg_dumpall -U nextcloud > dumpall.sql
helm uninstall nextcloud-stack -n <ns>          # PVCs kept (resource-policy: keep)
kubectl -n <ns> delete pvc data-nextcloud-stack-postgres-0   # postgres data ONLY
# bump postgres.image.tag, then:
./scripts/bootstrap-secrets.sh -n <ns> --force
helm install nextcloud-stack . -n <ns> -f example-values.yaml
kubectl -n <ns> cp dumpall.sql nextcloud-stack-postgres-0:/tmp/dumpall.sql
kubectl -n <ns> exec nextcloud-stack-postgres-0 -- psql -U nextcloud -f /tmp/dumpall.sql
kubectl -n <ns> scale deploy/nextcloud-stack --replicas=1
```

## Backups

Set `backup.enabled: true` for a built-in CronJob that, on each run, writes two
artifacts to a PVC:

- `postgres/pg-<TS>.sql.gz` — `pg_dumpall` of the whole cluster.
- `nextcloud/files-<TS>.tar.gz` — `data/` + `config/` (which carries the
  `config.php` secrets the DB dump is keyed against).

It `kubectl exec`s into the live Pods rather than mounting the RWO PVCs, so it
never multi-attaches. It runs as a non-root, restricted-PSS Pod with a minimal
ServiceAccount (`pods/exec` only) and its own CiliumNetworkPolicy. Old archives
are pruned past `backup.retentionDays`.

```yaml
backup:
  enabled: true
  schedule: "30 2 * * *"
  retentionDays: 14
  persistence:
    existingClaim: nextcloud-backups   # an off-cluster NFS-backed PVC, for real DR
```

Point `backup.persistence` at storage on a **different failure domain** than the
cluster (e.g. an NFS export) — a backup on the same disks it protects isn't one.

**Restoring:** see **[docs/restore.md](docs/restore.md)** — a proven, copy-pasteable
back-up → wipe → restore procedure. Run its verification drill (§9) quarterly; a
backup nobody restore-tests is worse than none.

## Monitoring (Prometheus / Grafana)

Set `metrics.enabled: true` to run a Prometheus exporter
([`nextcloud-exporter`](https://github.com/xperimental/nextcloud-exporter)) that
scrapes Nextcloud's `serverinfo` API and re-exposes metrics on `:9205` (Nextcloud
has no endpoint Prometheus can scrape directly). It authenticates with the
`serverinfo` **token** — read-only, no user account; the db-migrate Job writes the
same token into Nextcloud via `occ config:app:set serverinfo token`. No DHI image
exists, so it runs the community image hardened restricted-PSS clean (like
Whiteboard). Pre-create the Secret:

```bash
scripts/bootstrap-secrets.sh --metrics      # adds <release>-metrics (key: token)
```

```yaml
metrics:
  enabled: true
  auth:
    existingSecret: nextcloud-stack-metrics
networkPolicy:
  metricsIngressFrom:                         # let your Prometheus reach :9205
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: observability
```

**Scraping it.** With the Prometheus Operator, set `metrics.serviceMonitor.enabled:
true` (+ `labels` to match your Prometheus's selector). Otherwise add a static
target for `<release>-metrics.<namespace>.svc.cluster.local:9205`:

```yaml
  - job_name: nextcloud
    static_configs:
      - targets: ['nextcloud-stack-metrics.nextcloud.svc.cluster.local:9205']
```

**Grafana.** Import [`dashboards/nextcloud.json`](dashboards/nextcloud.json)
(uid `nextcloud`) — status, users, files, active users, free space, DB size,
shares, and system/PHP/DB info, against a `prometheus`-uid datasource.

> Health probes use `tcpSocket`, **not** `httpGet /metrics`: every `/metrics`
> request triggers an upstream serverinfo scrape, so HTTP probes would generate
> load and can trip Nextcloud's brute-force throttling.

## Secret rotation

External Secrets ⇒ operator-driven.
- **Admin:** change via the web UI (the Secret is only for the initial install).
- **Postgres:** update the Secret, `rollout restart deploy/<rel>`, and
  `ALTER ROLE <user> WITH PASSWORD …` on the DB. Short outage; order matters.
- **Valkey:** update the Secret, `rollout restart deploy/<rel>-valkey deploy/<rel>`.

## Values reference

See [`values.yaml`](values.yaml) for the full surface. Most users touch:

- `nextcloud.admin.existingSecret`
- `nextcloud.settings.overwriteHost` / `trustedDomains`
- `postgres.auth.existingSecret`, `valkey.auth.existingSecret`
- `nextcloud.persistence.*.size` / `*.storageClassName`
- one of `ingress.*`, `gatewayApi.*`, or `cloudflare.*`
- `nextcloud.web.realIp.trustedCidrs`
- `networkPolicy.nextcloudIngressFrom`

[`example-values.yaml`](example-values.yaml) is a working minimal config behind
ingress-nginx. [`values-public.yaml`](values-public.yaml) swaps the default DHI
images for public Docker Hub ones.

## Why `kubectl exec` for the migration / cron Jobs?

They talk to a Nextcloud install on an RWO PVC held by the live Pod. A Job that
mounted the PVC would hit Multi-Attach. Exec'ing into the live Pod sidesteps the
volume layer. A scoped Role grants only `pods/exec` on this Deployment's pods.

## Troubleshooting

### `helm install` complains about a missing Secret / value
A required `existingSecret` is empty, or you enabled an addon without its required
value (`gatewayApi.parentRef.name`, `cloudflare.tunnel.existingSecret`). The error
names the exact key. Run `scripts/bootstrap-secrets.sh` and/or set the value.

### The site is unreachable through my ingress / gateway
With NetworkPolicy on, add the controller's/gateway's namespace to
`networkPolicy.nextcloudIngressFrom` and `helm upgrade`. Confirm the Pod is Ready
and the Service has endpoints (`kubectl get endpoints <rel>`).

### nginx logs show proxy pod IPs instead of real client IPs
`nextcloud.web.realIp.trustedCidrs` doesn't cover your proxy's pod CIDR (or is
empty). Set it to the CIDR from
`kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'`. The install NOTES
print the configured value as a sanity-check.

### Pod stuck in `Init:0/1` (`wait-for-postgres`)
Postgres isn't reachable yet. Check
`kubectl -n <ns> logs -l app.kubernetes.io/component=postgres`.

### `/status.php` returns `installed:false` after a long wait
First-install `occ` hasn't finished. Tail `kubectl -n <ns> logs deploy/<rel> -c php -f`.
