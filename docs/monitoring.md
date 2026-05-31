# Monitoring (Prometheus & Grafana)

The chart can run a Prometheus exporter and ships a Grafana dashboard, so you get
visibility into users, files, storage, shares, and instance health.

---

## How it works

Nextcloud has no endpoint Prometheus can scrape directly — its `serverinfo` API
needs custom `NC-Token`/`OCS-APIRequest` headers a scrape config can't send. So the
chart runs the community **[nextcloud-exporter](https://github.com/xperimental/nextcloud-exporter)**,
which calls `serverinfo` and re-exposes clean Prometheus metrics on `:9205`.

```
Prometheus  ──scrape :9205──▶  nextcloud-exporter  ──serverinfo (NC-Token)──▶  Nextcloud
                                      │
                                      ▼
                                  Grafana dashboard "Nextcloud"
```

It authenticates with the **serverinfo token** — read-only, no user account. There
is no DHI image, so it runs the hardened public image (a documented exception,
like Whiteboard), restricted-PSS clean.

---

## 1. Enable it

```bash
# create the token Secret (key: token)
./scripts/bootstrap-secrets.sh --metrics
```

```yaml
metrics:
  enabled: true
  auth:
    existingSecret: nextcloud-stack-metrics
```

When you `helm upgrade`, the db-migrate Job enables the `serverinfo` app and writes
the **same** token into Nextcloud (`occ config:app:set serverinfo token`), so the
exporter and Nextcloud agree. (On a `--no-hooks` install, run that step yourself —
see [Operations](operations.md#upgrading-on-hook-restricted-clusters).)

---

## 2. Let Prometheus reach it (NetworkPolicy)

With the chart's CiliumNetworkPolicy on, allow your Prometheus namespace to scrape
`:9205`:

```yaml
networkPolicy:
  metricsIngressFrom:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: observability   # your Prometheus ns
```

Empty `metricsIngressFrom` ⇒ the default-deny policy blocks every scraper.

---

## 3. Scrape it

**With the Prometheus Operator** — turn on the ServiceMonitor:

```yaml
metrics:
  serviceMonitor:
    enabled: true
    labels: { release: kube-prometheus-stack }   # match your Prometheus's selector
```

**With a plain Prometheus** — add a static target:

```yaml
scrape_configs:
  - job_name: nextcloud
    static_configs:
      - targets: ['nextcloud-stack-metrics.nextcloud.svc.cluster.local:9205']
        labels: { app: nextcloud }
```

Then reload (`POST /-/reload` if `--web.enable-lifecycle` is set) and confirm the
target is `up` in Prometheus → Status → Targets.

---

## 4. Import the Grafana dashboard

Import the chart's bundled [`dashboards/nextcloud.json`](../dashboards/nextcloud.json)
(uid `nextcloud`). It expects a Prometheus datasource with **uid `prometheus`**
(rename in the import dialog if yours differs). Panels: status, users, files, active users (5m/1h/24h),
free space, DB size, shares by type, federated shares, and system/PHP/DB info.

File-provisioned Grafana? Drop the JSON into a dashboards ConfigMap your provider
watches.

---

## Metrics you get

| Metric | Meaning |
|---|---|
| `nextcloud_up` | 1 if the exporter could scrape serverinfo |
| `nextcloud_users_total` | total users |
| `nextcloud_active_users_{total,hourly_total,daily_total}` | active in 5 min / 1 h / 24 h |
| `nextcloud_files_total` | files served |
| `nextcloud_free_space_bytes` | free space in the data dir |
| `nextcloud_database_size_bytes` | DB size |
| `nextcloud_shares_total{type}` / `nextcloud_shares_federated_total{direction}` | shares |
| `nextcloud_system_info{version,…}` / `nextcloud_php_info` / `nextcloud_database_info` | label-only info (value 1) |

---

## Good to know

- **Probes are `tcpSocket`, not `httpGet /metrics`** — on purpose. Every `/metrics`
  request makes the exporter call `serverinfo`, so HTTP probes would generate
  scrape load and can trip Nextcloud's **brute-force throttling**. Don't point your
  own uptime checks at `/metrics` more often than your scrape interval.
- **Alerting idea:** alert on `nextcloud_up == 0` and on
  `nextcloud_free_space_bytes` below a threshold.
- **Token rotation:** update the `<release>-metrics` Secret and re-run the
  db-migrate step (or `occ config:app:set serverinfo token`) so both sides match,
  then `rollout restart deploy/<release>-metrics`.

---

← [Backup & Restore](backup-and-restore.md) · [Wiki home](README.md) · Next: [Operations](operations.md)
