# Architecture

A tour of how the chart is put together — useful before you tune it or debug it.

---

## Topology at a glance

```
   Ingress  /  Gateway API  /  Cloudflare tunnel     (pick one; all optional)
                        │   TLS terminated here
                        ▼   http://<release>.<ns>.svc.cluster.local:80
            ┌────────────────────────────────┐
            │  Nextcloud Pod  (Recreate, RWO) │
            │   ┌─────────┐    ┌──────────┐   │
            │   │  web    │───▶│  php     │   │   nginx :8080  →  fpm 127.0.0.1:9000
            │   │ (nginx) │    │ (fpm)    │   │
            │   └─────────┘    └──────────┘   │
            │      shared webroot PVC (RWO)   │
            │      data PVC (RWO)             │
            └───────┬────────────────────────┘
                    │
        ┌───────────┼───────────┬───────────────┐
        ▼           ▼           ▼               ▼
   postgres      valkey      clamav*        metrics*        (* optional)
   :5432         :6379       :3310          exporter :9205
   (StatefulSet) (cache)     (antivirus)    (→ Prometheus)
```

- The Nextcloud **Service stays `ClusterIP`**. Whatever you put in front of it
  (ingress controller, Gateway, or cloudflared) terminates TLS and forwards plain
  HTTP to port 80, which maps to nginx on `8080` inside the Pod.
- nginx forces `HTTPS=on` to PHP-FPM so Nextcloud emits `https://` URLs and sets
  Secure cookies even though the origin sees HTTP
  (`nextcloud.web.httpsBehindProxy`, on by default).

---

## Components

| Component | Object | Default image | Port | UID | Optional? |
|---|---|---|---|---|---|
| **php** | Deployment (container) | `ghcr.io/adithya-rajendran/nextcloud-fpm:33.0.5-fpm` | 9000 (loopback) | 33 | core |
| **web** | same Pod (sidecar) | `dhi.io/nginx:1-compat` | 8080 | 65532 | core |
| **postgres** | StatefulSet | `dhi.io/postgres:18` | 5432 | 70 | core |
| **valkey** | Deployment | `dhi.io/valkey:9` | 6379 | 65532 | `valkey.enabled` |
| **clamav** | Deployment | `dhi.io/clamav:1.5-base` | 3310 | 65532 | `clamav.enabled` |
| **kubectl** | CronJob + hook Job | `dhi.io/kubectl:1` | — | 65532 | core |
| **curl** | `helm test` Pod | `dhi.io/curl:8-alpine3.23` | — | 65532 | `tests.enabled` |
| **whiteboard** | Deployment | `ghcr.io/nextcloud-releases/whiteboard` | 3002 | 65534 | `whiteboard.enabled` |
| **metrics** | Deployment | `ghcr.io/xperimental/nextcloud-exporter:0.9.1` | 9205 | 65534 | `metrics.enabled` |
| **cloudflared** | Deployment | `cloudflare/cloudflared:2024.12.2` | — | 65532 | `cloudflare.tunnel.enabled` |

> The **php** image is the only custom one (public on GHCR, built by
> [nextcloud-images](https://github.com/adithya-rajendran/nextcloud-images)).
> Everything else is a stock DHI image, or — for whiteboard / metrics /
> cloudflared, which have no DHI build — a hardened public image (the documented
> exceptions). With `-f values-public.yaml` the core images become public Docker
> Hub equivalents and the UIDs change accordingly.

---

## Why php + nginx share one Pod

They share the webroot over a `ReadWriteOnce` PVC. Two containers in the **same
Pod** can both mount an RWO volume; two separate Pods cannot (that's a
`Multi-Attach` error). Keeping them together is what lets the chart work on any
RWO StorageClass without requiring RWX.

That same constraint is why the Nextcloud Deployment uses **`strategy: Recreate`**
— a rolling update would briefly run two Pods, each wanting the RWO volume. See
[Storage & Scaling](storage-and-scaling.md) for the HA implications.

---

## Data flow

1. A request hits your front door (ingress/gateway/tunnel), which terminates TLS.
2. It's forwarded as HTTP to the Nextcloud `ClusterIP` Service → nginx `:8080`.
3. nginx serves static files from the webroot and proxies PHP to fpm on
   `127.0.0.1:9000`.
4. fpm talks to **postgres** (data), **valkey** (locking + cache, if enabled), and
   **clamav** (scans uploads, if enabled).
5. A CronJob runs `occ cron` every 5 minutes via `kubectl exec` into the live Pod.

The migration/cron Jobs use **`kubectl exec`** rather than mounting the PVC —
again to dodge `Multi-Attach`. They get a tightly scoped Role (`pods/exec` on this
Deployment only). See [Operations](operations.md#why-kubectl-exec) and
[Security](security.md).

---

## Persistent volumes

| PVC | Default size | Access | Holds |
|---|---|---|---|
| `<release>-webroot` | 10Gi | RWO | the Nextcloud code + `config/` |
| `<release>-data` | 100Gi | RWO | user files (the big one) |
| `data-<release>-postgres-0` | 10Gi | RWO | the database |

All are annotated `helm.sh/resource-policy: keep`, so they survive `helm
uninstall`. Sizing and expansion: [Storage & Scaling](storage-and-scaling.md).

---

## What's deliberately *not* in the chart

- **A TLS issuer, a Gateway, or an ingress controller.** The chart renders an
  Ingress or HTTPRoute, but you bring the controller/Gateway and (for Ingress) the
  cert issuer (e.g. cert-manager).
- **Collabora / Office, AFFiNE.** Independent lifecycles, no shared state — run
  them separately. (Whiteboard *is* included as an add-on because it integrates
  tightly via a shared JWT.) See [Add-ons](add-ons.md).
- **A CNI.** The NetworkPolicy assumes Cilium; see [Security](security.md).

---

← [Installation](installation.md) · [Wiki home](README.md) · Next: [Configuration](configuration.md)
