---
---

# Configuration

How configuration works in this chart, the knobs most people actually touch, and
worked examples. For an exhaustive list, see [Values Reference](values-reference.md).

---

## How values are applied

The chart is configured the standard Helm way — layered `-f` files, last one
wins:

```bash
helm install nextcloud-stack . -n nextcloud \
  -f my-values.yaml \        # your config
  -f pins.yaml               # digest pins (optional, see Installation)
```

Useful bundled files:

| File | Purpose |
|---|---|
| [`values.yaml`](https://github.com/Adithya-Rajendran/nextcloud-stack-chart/blob/main/values.yaml) | the defaults + inline docs (the source of truth) |
| [`example-values.yaml`](https://github.com/Adithya-Rajendran/nextcloud-stack-chart/blob/main/example-values.yaml) | a realistic minimal install behind ingress-nginx |
| [`values-public.yaml`](https://github.com/Adithya-Rajendran/nextcloud-stack-chart/blob/main/values-public.yaml) | overlay that swaps DHI images for public Docker Hub ones |

Keep your own settings in a small `my-values.yaml` overlay — don't edit
`values.yaml` directly, so chart updates stay clean.

---

## The essentials (what almost everyone sets)

```yaml
imagePullSecrets:
  - name: dhi-pull                      # omit if using -f values-public.yaml

nextcloud:
  admin:
    existingSecret: nextcloud-stack-admin
  settings:
    overwriteHost: cloud.example.com    # your public hostname
    trustedDomains:
      - localhost
      - cloud.example.com
  web:
    realIp:
      trustedCidrs: ["10.0.0.0/8"]      # your proxy's pod CIDR

postgres:
  auth:
    existingSecret: nextcloud-stack-postgres
valkey:
  auth:
    existingSecret: nextcloud-stack-valkey

ingress:                                # or gatewayApi / cloudflare
  enabled: true
  className: nginx
  host: cloud.example.com
  tls: { enabled: true, secretName: cloud-tls }
```

- **Secrets** are referenced, never inlined — see [Security](security.md#secrets-are-external-only).
- **Exposure** is a one-of choice — see [Exposure & TLS](exposure-and-tls.md).
- **`trustedCidrs`** controls real client IP logging — see
  [Exposure & TLS › Real client IP](exposure-and-tls.md#real-client-ip).

---

## Common adjustments by area

### Hostname & server settings

```yaml
nextcloud:
  settings:
    overwriteHost: cloud.example.com
    overwriteProtocol: https
    trustedDomains: [localhost, cloud.example.com]
    defaultPhoneRegion: US        # clears the "no default phone region" admin warning
    maxFileUploadSize: 16G        # nginx + PHP upload caps (keep them in sync with your ingress)
    memoryLimit: 512M             # PHP memory_limit
```

`overwriteHost`/`overwriteProtocol` are how Nextcloud knows its own public URL
behind a proxy. `maxFileUploadSize` must be matched by your front door too (e.g.
`nginx.ingress.kubernetes.io/proxy-body-size`).

### Resources

Every component has a `resources` block with sane requests/limits. The defaults
suit a small-to-medium instance. ClamAV is the heavy one (1–3 GiB RAM). See
[Storage & Scaling › Resource sizing](storage-and-scaling.md#resource-sizing).

### Storage

```yaml
nextcloud:
  persistence:
    data:    { size: 200Gi, storageClassName: fast-rbd }
    webroot: { size: 10Gi }
postgres:
  persistence: { size: 20Gi }
```

Empty `storageClassName` ⇒ the cluster default. Growing a volume later:
[Storage & Scaling › Expanding a PVC](storage-and-scaling.md#expanding-a-pvc).

### Turning components on/off

```yaml
valkey:  { enabled: true }    # caching + file locking — recommended on
clamav:  { enabled: false }   # antivirus — heavy; off if you don't need it
whiteboard: { enabled: true } # collaborative whiteboard add-on
metrics: { enabled: true }    # Prometheus exporter
backup:  { enabled: true }    # scheduled backups
```

See [Add-ons](add-ons.md), [Monitoring](monitoring.md), and
[Backup & Restore](backup-and-restore.md).

### The CronJob (occ cron)

```yaml
nextcloud:
  cronJob:
    enabled: true
    schedule: "*/5 * * * *"
    timeZone: America/Los_Angeles   # K8s 1.27+; empty ⇒ UTC
```

---

## Worked examples

### Behind ingress-nginx (the example)

See [`example-values.yaml`](https://github.com/Adithya-Rajendran/nextcloud-stack-chart/blob/main/example-values.yaml) — Ingress + cert Secret +
`nextcloudIngressFrom` for the controller's namespace.

### Behind a Cilium Gateway with Whiteboard

```yaml
gatewayApi:
  enabled: true
  parentRef: { name: shared-gateway, namespace: gateway }
  hostnames: [cloud.example.com]
whiteboard:
  enabled: true
  nextcloudUrl: https://cloud.example.com
  publicUrl: https://cloud.example.com      # same-origin /socket.io/ route
  auth: { existingSecret: nextcloud-stack-whiteboard }
networkPolicy:
  enabled: true                              # gateway auto-allowed
```

### Public images (Docker Hub)

```bash
helm install nextcloud-stack . -n nextcloud -f my-values.yaml -f values-public.yaml
```

(Drop `imagePullSecrets` from `my-values.yaml`.)

---

## A few render-time guard rails

The chart intentionally **fails to render** (rather than installing something
unsafe or broken) when:

- a required `existingSecret` is empty;
- an add-on is enabled without its required value (`gatewayApi.parentRef.name`,
  `cloudflare.tunnel.existingSecret`, `whiteboard.auth.existingSecret`,
  `metrics.auth.existingSecret`);
- a multi-valued real-IP header is paired with `recursive: false` (spoofable);
- `whiteboard.replicas > 1` without a shared Valkey backend.

The error message names the exact value to fix.

---

← [Architecture](architecture.md) · [Wiki home](README.md) · Next: [Values Reference](values-reference.md)
