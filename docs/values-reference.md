# Values Reference

Every configurable value, grouped by block, with defaults. The authoritative,
always-current source is [`values.yaml`](../values.yaml) (heavily commented) — this
page is the organised companion. Defaults below are for chart **0.3.0**.

> Convention: only the keys you're likely to set are listed in full. Image blocks
> all share the same shape (`registry`, `repository`, `tag`, `digest`,
> `pullPolicy`) and are summarised once below.

---

## Global

| Value | Default | Notes |
|---|---|---|
| `nameOverride` | `""` | Don't change after first install (selectors are immutable). |
| `fullnameOverride` | `""` | Same caveat. |
| `commonLabels` | `{}` | Added to every resource. |
| `imagePullSecrets` | `[]` | Needs `dhi-pull` for the default DHI images. |

## Image blocks (shared shape)

Every component has an `image:` block:

```yaml
image:
  registry: dhi.io            # or ghcr.io / docker.io
  repository: <name>
  tag: "<tag>"
  digest: ""                  # set via scripts/pin-digests.sh; overrides tag
  pullPolicy: IfNotPresent
```

Defaults: php `ghcr.io/adithya-rajendran/nextcloud-fpm:33.0.3-fpm`,
web `dhi.io/nginx:1-compat`, postgres `dhi.io/postgres:18`, valkey `dhi.io/valkey:9`,
clamav `dhi.io/clamav:1.5-base`, kubectl `dhi.io/kubectl:1`,
curl `dhi.io/curl:8-alpine3.23`, whiteboard `ghcr.io/nextcloud-releases/whiteboard:v1.5.3`,
metrics `ghcr.io/xperimental/nextcloud-exporter:0.9.1`,
cloudflared `docker.io/cloudflare/cloudflared:2024.12.2`.

---

## `nextcloud`

| Value | Default | Notes |
|---|---|---|
| `nextcloud.replicas` | `1` | Core is single-Pod (RWO) — see [Storage & Scaling](storage-and-scaling.md#high-availability-and-replicas). |
| `nextcloud.strategy.type` | `Recreate` | Required for RWO PVCs. |
| `nextcloud.resources` | req `250m`/`512Mi`, lim `2`/`4Gi` | PHP-FPM. |
| `nextcloud.podSecurityContext` | non-root, UID/GID/fsGroup `33` | www-data. |
| `nextcloud.pdb.enabled` / `.maxUnavailable` | `true` / `0` | Blocks accidental drain of the single Pod. |
| `nextcloud.service.type` / `.port` / `.targetPort` | `ClusterIP` / `80` / `8080` | Fronted by ingress/gateway/tunnel. |

### `nextcloud.admin`
| Value | Default | Notes |
|---|---|---|
| `admin.existingSecret` | `""` **(required)** | Keys `admin-user` (the username), `admin-password`. |

### `nextcloud.settings`
| Value | Default | Notes |
|---|---|---|
| `overwriteHost` | `nextcloud.example.com` | Your public hostname. |
| `overwriteProtocol` | `https` | |
| `overwriteCliUrl` | `""` | Auto-derived if empty. |
| `trustedDomains` | `[localhost, nextcloud.example.com]` | |
| `defaultPhoneRegion` | `US` | |
| `maxFileUploadSize` | `16G` | nginx + PHP caps. |
| `memoryLimit` | `512M` | PHP `memory_limit`. |
| `customPhp` | secure cookie defaults | Appended to `custom.ini`. |

### `nextcloud.web`
| Value | Default | Notes |
|---|---|---|
| `web.httpsBehindProxy` | `true` | Forces `HTTPS=on` to fpm behind a TLS proxy. |
| `web.realIp.header` | `X-Forwarded-For` | See [Exposure › Real client IP](exposure-and-tls.md#real-client-ip). |
| `web.realIp.recursive` | `true` | Required for multi-valued headers. |
| `web.realIp.trustedCidrs` | `[]` | Your proxy's pod CIDR; empty disables rewrite. |
| `web.selfConnect.enabled` | `false` | Loopback `:443` listener for "connect to itself" checks — [details](exposure-and-tls.md#the-self-connect-listener). |
| `web.selfConnect.tlsSecret` | `""` | Required when enabled. |

### `nextcloud.cronJob` / `nextcloud.dbMigrateJob`
| Value | Default | Notes |
|---|---|---|
| `cronJob.enabled` | `true` | `occ cron` via `kubectl exec`. |
| `cronJob.schedule` | `*/5 * * * *` | |
| `cronJob.timeZone` | `""` (UTC) | K8s 1.27+. |
| `dbMigrateJob.enabled` | `true` | post-install/upgrade hook. |
| `dbMigrateJob.activeDeadlineSeconds` | `900` | Raise on slow storage. |

### `nextcloud.persistence`
| Value | Default | Notes |
|---|---|---|
| `persistence.webroot.size` | `10Gi` | code + `config/`. |
| `persistence.data.size` | `100Gi` | user files. |
| `persistence.*.storageClassName` | `""` (cluster default) | |
| `persistence.*.accessModes` | `[ReadWriteOnce]` | |
| `persistence.*.existingClaim` | `""` | Reuse an existing PVC (migration). |

---

## `postgres`

| Value | Default | Notes |
|---|---|---|
| `postgres.enabled` | `true` | |
| `postgres.auth.database` / `.username` | `nextcloud` / `nextcloud` | Must not be `postgres` with `manageAppRole`. |
| `postgres.auth.existingSecret` | `""` **(required)** | Keys `nextcloud-db-password` + (with `manageAppRole`) `postgres-admin-password`. |
| `postgres.auth.manageAppRole` | `true` | Run Nextcloud as a dedicated `NOSUPERUSER` role that owns only its DB; the `postgres` superuser stays separate. Legacy installs are auto-migrated — see [Security › Database privilege separation](security.md#database-privilege-separation). |
| `postgres.persistence.size` | `10Gi` | |
| `postgres.resources` | req `100m`/`256Mi`, lim `1`/`1Gi` | |
| `postgres.service.port` | `5432` | |

> Major-version upgrades are out-of-chart — see [Operations](operations.md#postgres-major-version-upgrades).

## `valkey`

| Value | Default | Notes |
|---|---|---|
| `valkey.enabled` | `true` | Caching + file locking. |
| `valkey.auth.enabled` | `true` | |
| `valkey.auth.existingSecret` | `""` **(required when enabled)** | Keys `valkey-password`, `valkey.conf`. |
| `valkey.service.port` | `6379` | Cache only; no persistence (emptyDir). |

## `clamav`

| Value | Default | Notes |
|---|---|---|
| `clamav.enabled` | `true` | On-upload antivirus (heavy). |
| `clamav.resources` | req `250m`/`1Gi`, lim `2`/`3Gi` | |
| `clamav.signaturesEmptyDirSize` | `1Gi` | freshclam re-downloads ~250 MB on cold start. |
| `clamav.service.port` | `3310` | |

---

## Exposure

### `ingress`
| Value | Default | Notes |
|---|---|---|
| `ingress.enabled` | `false` | |
| `ingress.className` | `""` | e.g. `nginx`. |
| `ingress.host` | `nextcloud.example.com` | |
| `ingress.tls.enabled` / `.secretName` | `false` / `""` | |
| `ingress.annotations` | `{}` | e.g. cert-manager issuer, body-size. |

### `gatewayApi`
| Value | Default | Notes |
|---|---|---|
| `gatewayApi.enabled` | `false` | |
| `gatewayApi.parentRef.name` | `""` **(required when enabled)** | Existing Gateway. |
| `gatewayApi.parentRef.namespace` / `.sectionName` | `""` | |
| `gatewayApi.hostnames` | `[nextcloud.example.com]` | |

### `cloudflare`
| Value | Default | Notes |
|---|---|---|
| `cloudflare.enabled` | `false` | |
| `cloudflare.tunnel.enabled` | `true` | Deploy cloudflared here. |
| `cloudflare.tunnel.existingSecret` | `""` **(required)** | Key `tunnel-token`. |
| `cloudflare.tunnel.replicas` | `2` | |
| `cloudflare.externalTunnel.*` | ns `cf-tunnel`, label `app=cloudflared` | Only when `tunnel.enabled: false`. |
| `cloudflare.realIp.header` | `CF-Connecting-IP` | Auto-applied. |
| `cloudflare.realIp.trustedCidrs` | `[]` | cloudflared pod CIDR. |

---

## `networkPolicy`

| Value | Default | Notes |
|---|---|---|
| `networkPolicy.enabled` | `true` | |
| `networkPolicy.flavor` | `cilium` | `cilium` (full fidelity, requires Cilium) or `kubernetes` (standard v1 for any policy-enforcing CNI, with documented approximations). |
| `networkPolicy.nextcloudIngressFrom` | `[]` | Raw ingress-source objects in the selected flavor's schema. |
| `networkPolicy.whiteboardIngressFrom` | `[]` | Defaults to `nextcloudIngressFrom`. |
| `networkPolicy.metricsIngressFrom` | `[]` | Your Prometheus namespace. |
| `networkPolicy.allowAllEgress` | `true` | Public egress (Cilium `world`, or its v1 ipBlock approximation). |

See [Security › NetworkPolicy](security.md#networkpolicy-requires-cilium).

---

## Add-ons

### `whiteboard`
| Value | Default | Notes |
|---|---|---|
| `whiteboard.enabled` | `false` | |
| `whiteboard.replicas` | `2` | `>1` needs `storageStrategy: redis` + Valkey. |
| `whiteboard.storageStrategy` | `redis` | `lww` = single-instance only. |
| `whiteboard.nextcloudUrl` | `https://nextcloud.example.com` | Backend → Nextcloud. |
| `whiteboard.publicUrl` | `""` | Browser-facing; use same host as Nextcloud. |
| `whiteboard.auth.existingSecret` | `""` **(required when enabled)** | Keys `jwt-secret-key`, `redis-url`. |
| `whiteboard.service.port` | `3002` | |

### `metrics`
| Value | Default | Notes |
|---|---|---|
| `metrics.enabled` | `false` | |
| `metrics.nextcloudUrl` | `""` (internal svc) | |
| `metrics.scrapeTimeout` | `5s` | |
| `metrics.auth.existingSecret` / `.tokenKey` | `""` **(required)** / `token` | |
| `metrics.serviceMonitor.enabled` | `false` | Prometheus-Operator. |
| `metrics.service.port` | `9205` | |

See [Monitoring](monitoring.md).

### `backup`
| Value | Default | Notes |
|---|---|---|
| `backup.enabled` | `false` | |
| `backup.schedule` | `30 2 * * *` | |
| `backup.retentionDays` | `14` | |
| `backup.persistence.existingClaim` / `.size` / `.storageClassName` | `""` / `10Gi` / `""` | Point at off-cluster storage. |

See [Backup & Restore](backup-and-restore.md).

### `tests`
| Value | Default | Notes |
|---|---|---|
| `tests.enabled` | `true` | `helm test` smoke test. |

---

← [Configuration](configuration.md) · [Wiki home](README.md) · Next: [Exposure & TLS](exposure-and-tls.md)
