# nextcloud-stack wiki

Welcome! This is the full documentation for **nextcloud-stack** — a security-first
Helm chart that runs [Nextcloud](https://nextcloud.com/) on Kubernetes with
Postgres, Valkey, optional ClamAV, and a handful of opt-in add-ons, all in
templates the chart owns (no subcharts, no out-of-chart patches).

New here? Start with **[Getting Started](getting-started.md)** — it takes you from
zero to a running instance. Then come back to this map for the deep dives.

---

## What makes this chart different

- **Hardened by default.** Every image is a [Docker Hardened Image](https://www.docker.com/products/hardened-images/)
  (`dhi.io/*`) — minimal, non-root, CVE-scanned. No DHI subscription? One overlay
  (`-f values-public.yaml`) swaps in public Docker Hub images.
- **Locked down out of the box.** Restricted PodSecurity, a default-deny
  CiliumNetworkPolicy, non-root + read-only-rootfs + dropped capabilities
  everywhere, external-only secrets, digest pinning.
- **No surprises on upgrade.** No re-apply checklist; migrations run as a
  post-upgrade hook; everything is in the chart.
- **Batteries optional.** Ingress / Gateway API / Cloudflare tunnel for exposure;
  Whiteboard, antivirus, backups, and Prometheus/Grafana monitoring as toggles.

---

## The map

### Start here
| Page | What it covers |
|---|---|
| **[Getting Started](getting-started.md)** | Prerequisites and the fastest path to a working instance. |
| **[Installation](installation.md)** | The full install walkthrough — secrets, DHI vs public images, digest pinning, `helm test`, first login. |
| **[Architecture](architecture.md)** | How the pieces fit: topology, components, ports, UIDs, data flow. |

### Configure it
| Page | What it covers |
|---|---|
| **[Configuration](configuration.md)** | How values work, what most people change, worked examples. |
| **[Values Reference](values-reference.md)** | Every value block, organised, with defaults. |
| **[Exposure & TLS](exposure-and-tls.md)** | Ingress, Gateway API, Cloudflare tunnel, real client IP, the self-connect listener. |
| **[Security Model](security.md)** | PodSecurity, NetworkPolicy, secrets, image provenance, the threat model. |

### Run it well (day 2)
| Page | What it covers |
|---|---|
| **[Storage & Scaling](storage-and-scaling.md)** | PVCs, storage classes, **expanding a volume**, replicas, resource sizing. |
| **[Backup & Restore](backup-and-restore.md)** | The backup CronJob, plus the proven **[restore guide](restore.md)**. |
| **[Monitoring](monitoring.md)** | The Prometheus exporter, scraping, and the Grafana dashboard. |
| **[Operations](operations.md)** | Upgrades, secret rotation, Postgres major upgrades, `occ`, maintenance mode. |
| **[Add-ons](add-ons.md)** | ClamAV antivirus, Whiteboard, and notes on Collabora/Office. |

### When something's wrong
| Page | What it covers |
|---|---|
| **[Troubleshooting](troubleshooting.md)** | Symptoms → fixes, including the non-obvious gotchas. |
| **[FAQ](faq.md)** | Quick answers to common questions. |

---

## "I want to…" quick links

- **…install for the first time** → [Getting Started](getting-started.md)
- **…expose it on my domain** → [Exposure & TLS](exposure-and-tls.md)
- **…run it without a DHI subscription** → [Installation › Public images](installation.md#option-b-public-images-no-subscription)
- **…make the data volume bigger** → [Storage & Scaling › Expanding a PVC](storage-and-scaling.md#expanding-a-pvc)
- **…turn on backups** → [Backup & Restore](backup-and-restore.md)
- **…get metrics into Grafana** → [Monitoring](monitoring.md)
- **…rotate a password** → [Operations › Secret rotation](operations.md#secret-rotation)
- **…upgrade the chart** → [Operations › Upgrading](operations.md#upgrading-the-chart)
- **…understand the security posture** → [Security Model](security.md)

---

## Conventions used in this wiki

- Commands assume you run from the **chart root** (the directory containing
  `Chart.yaml`) and that your `kubectl`/`helm` point at the right cluster.
- Placeholders: `<ns>` = namespace (examples use `nextcloud`), `<release>` =
  Helm release name (examples use `nextcloud-stack`).
- The chart's **release name is used as a prefix** for almost every object, so
  the Nextcloud Deployment is `<release>`, Postgres is `<release>-postgres`, etc.
- Chart version documented here: **0.3.0** (Nextcloud appVersion **33.0.3**).

> This wiki lives in [`docs/`](.) in the repo, so it's versioned and reviewed
> alongside the chart. The top-level [`README.md`](../README.md) is the quick
> reference; these pages are the long form.
