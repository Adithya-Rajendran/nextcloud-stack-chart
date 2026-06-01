# Security Model

Security is the whole point of this chart. This page explains what's hardened, why,
and the few things **you** are responsible for.

---

## The short version

- **Hardened images by default** (Docker Hardened Images — minimal, non-root,
  CVE-scanned).
- **Restricted PodSecurity** compatible — `runAsNonRoot`, `readOnlyRootFilesystem`
  where possible, `drop: ["ALL"]`, `seccompProfile: RuntimeDefault` on every
  container.
- **Default-deny NetworkPolicy** (Cilium) with per-component allows.
- **External-only secrets** — nothing sensitive in `values.yaml` or Helm metadata.
- **Digest pinning** available for every image.
- **Least privilege** for the Jobs that touch the K8s API (`pods/exec` only).

---

## Images: Docker Hardened Images

Every default image is a `dhi.io/*` Docker Hardened Image: stripped to the minimum,
non-root, continuously CVE-scanned. The only custom image is the PHP-FPM one
(public on GHCR). Three add-ons have **no** DHI build and use hardened public
images as documented exceptions: **whiteboard**, **metrics** (nextcloud-exporter),
and **cloudflared**.

Prefer plain Docker Hub images? `-f values-public.yaml` swaps them in (no `dhi.io` login).
You lose the hardened base but keep every other control below.

> **Pull-secret gotcha:** the DHI pull secret must be keyed to **`dhi.io`**. A
> Docker-Hub-keyed secret returns `401`. See
> [Troubleshooting](troubleshooting.md#imagepullbackoff--401-unauthorized-on-dhiio).

### Pin digests

Tags move; digests don't. `./scripts/pin-digests.sh > pins.yaml` resolves every
image to its current digest; apply with an extra `-f pins.yaml`. Re-run to adopt
updates deliberately, review the diff, and upgrade.

---

## PodSecurity (restricted)

Apply the `restricted` profile to the namespace — the chart's Pods all comply:

```bash
kubectl label namespace nextcloud \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

Per-container hardening: non-root UIDs (fpm 33, postgres 70, the rest 65532/65534),
`allowPrivilegeEscalation: false`, all capabilities dropped, RuntimeDefault
seccomp, and `readOnlyRootFilesystem: true` wherever the app doesn't need to write
its own image (nginx, valkey, kubectl, curl, cloudflared, metrics).

> The one capability the chart *adds back* is `NET_BIND_SERVICE` on the web
> container — and only when `nextcloud.web.selfConnect.enabled`, so nginx can bind
> the loopback `:443`. Still non-root.

---

## NetworkPolicy (requires Cilium)

The chart renders a **`CiliumNetworkPolicy`** (`cilium.io/v2`), not a standard
NetworkPolicy. It's **default-deny** with explicit per-component allows. This is
load-bearing — it's the only thing that:

- keeps unauthenticated **PHP-FPM on :9000** unreachable from other pods;
- stops in-cluster pods from **spoofing the forwarded real-IP header** through
  nginx (`set_real_ip_from` trusts only `trustedCidrs`);
- keeps **Nextcloud↔Postgres** (plaintext) traffic off the reach of in-cluster
  sniffers.

What it allows:

| Component | Ingress from | Egress to |
|---|---|---|
| Nextcloud | gateway (`fromEntities: [ingress]` when `gatewayApi.enabled`), Cloudflare source, `nextcloudIngressFrom`, the metrics exporter | DNS, Postgres, Valkey, ClamAV, Whiteboard, `world` (if `allowAllEgress`) |
| Postgres / Valkey / ClamAV | Nextcloud only | DNS (+ `world` for ClamAV signatures) |
| Metrics exporter | `metricsIngressFrom` (your Prometheus ns) | DNS, Nextcloud |
| backup Job | — | kube-apiserver, DNS |

Public egress uses Cilium's identity-based **`world`** entity (everything outside
the cluster) — no CIDR list to maintain.

### Why Cilium specifically

The Gateway API path needs `fromEntities: [ingress]` to allow the gateway proxy's
reserved identity, which standard NetworkPolicy v1 **cannot express** — a
Gateway-fronted install would silently `503`. So the chart commits to Cilium.

**On a non-Cilium CNI:** set `networkPolicy.enabled: false` and bring your own
equivalent policy — otherwise every control above is silently gone.

### Extra ingress sources

Front Nextcloud with something the chart doesn't know about? Add a raw Cilium
selector:

```yaml
networkPolicy:
  nextcloudIngressFrom:
    - fromEndpoints:
        - matchLabels: { k8s:io.kubernetes.pod.namespace: ingress-nginx }
```

---

## Secrets are external-only

The chart **never** generates passwords and **never** accepts inline password
values — both would leak plaintext into Helm release metadata (readable by anyone
with `helm get values`). Instead:

1. You pre-create Secrets (the bundled script, or your own
   Vault/ESO/SOPS pipeline).
2. You reference them via `*.auth.existingSecret`.
3. The chart **fails render** if a required reference is empty.

The expected Secrets and keys:

| Secret | Keys | Required |
|---|---|---|
| `<release>-admin` | `admin-user`, `admin-password` | always |
| `<release>-postgres` | `nextcloud-db-password` | always |
| `<release>-valkey` | `valkey-password`, `valkey.conf` | when `valkey.enabled` |
| `<release>-whiteboard` | `jwt-secret-key`, `redis-url` | when `whiteboard.enabled` |
| `<release>-metrics` | `token` | when `metrics.enabled` |
| `<release>-cloudflared` | `tunnel-token` | when `cloudflare.tunnel.enabled` |

> **Valkey config in a Secret, not a ConfigMap** — `requirepass` never lands in a
> cluster-readable resource.

Rotation: [Operations › Secret rotation](operations.md#secret-rotation).

---

## Least-privilege API access

Most Pods set `automountServiceAccountToken: false`. The cron + db-migrate Jobs
*do* talk to the K8s API (they `kubectl exec` into the live Pod to run `occ`), and
they get a **scoped Role**: only `pods/exec` on this Deployment's pods, in this
namespace. Why exec instead of mounting the PVC? The data PVC is RWO and held by
the live Pod — a second mount would `Multi-Attach`. See
[Operations](operations.md#why-kubectl-exec).

---

## Threat model & your responsibilities

The chart hardens the stack, but **you** own:

- **`nextcloud.web.realIp.trustedCidrs`** — the one cluster-specific value. With
  `recursive: true`, it must cover every proxy hop, and those hops must append to
  the header.
- **The CNI.** No Cilium ⇒ no NetworkPolicy ⇒ the controls above are gone unless
  you replace them.
- **TLS at the front door** — the chart doesn't issue certs.
- **Secret storage** — keep the source Secrets (and any password manager copy)
  safe; rotate on exposure.
- **Keeping images current** — re-pin digests and upgrade regularly.

---

← [Exposure & TLS](exposure-and-tls.md) · [Wiki home](README.md) · Next: [Storage & Scaling](storage-and-scaling.md)
