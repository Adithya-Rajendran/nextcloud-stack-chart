# FAQ

Quick answers. Most link to the page with the full story.

---

**Do I need a paid Docker subscription for the hardened images?**
No — a **free** Docker account is enough to pull the `dhi.io` images. Or skip
`dhi.io` entirely: `-f values-public.yaml` swaps in public Docker Hub images with no
pull secret, keeping every other security control. See
[Installation › Public images](installation.md#option-b-public-images-docker-hub).

**Do I have to use Cilium?**
Only if you want the chart's NetworkPolicy. It renders a `CiliumNetworkPolicy`
(the Gateway path needs a Cilium-specific identity). On another CNI, set
`networkPolicy.enabled: false` and bring your own policy. See
[Security](security.md#networkpolicy-requires-cilium).

**How do I expose it on my domain?**
Pick one of Ingress, Gateway API, or the Cloudflare tunnel addon — all in
[Exposure & TLS](exposure-and-tls.md). TLS is terminated at that front door.

**Where do passwords come from? Can I set them inline?**
No inline passwords — that would leak into Helm metadata. You pre-create Secrets
(use `scripts/bootstrap-secrets.sh`) and reference them. See
[Security › Secrets](security.md#secrets-are-external-only).

**How do I make the data volume bigger?**
Raise `nextcloud.persistence.data.size` and `helm upgrade` (StorageClass must allow
expansion; you can only grow). Step-by-step:
[Storage & Scaling › Expanding a PVC](storage-and-scaling.md#expanding-a-pvc).

**Can I run Nextcloud with multiple replicas for HA?**
Not the core — it shares an RWO PVC, so it's single-Pod by design. Resilience here
comes from fast restarts + good [backups](backup-and-restore.md). Whiteboard *does*
scale. See [Storage & Scaling › HA](storage-and-scaling.md#high-availability-and-replicas).

**Is my data deleted when I uninstall?**
No — PVCs are kept (`resource-policy: keep`). Delete them explicitly if you really
want the data gone. See [Operations › Uninstall](operations.md#uninstall-and-keeping-data).

**How do I back up and restore?**
Turn on `backup.enabled` for a scheduled CronJob; restore with the proven
[restore guide](restore.md). Overview: [Backup & Restore](backup-and-restore.md).

**How do I get metrics/dashboards?**
Enable `metrics.enabled`, scrape `:9205`, import the bundled Grafana dashboard. See
[Monitoring](monitoring.md).

**Why do the cron/migration Jobs use `kubectl exec` instead of mounting the PVC?**
The data PVC is RWO and held by the live Pod; a second mount would `Multi-Attach`.
Exec sidesteps the volume, with a scoped `pods/exec` Role. See
[Operations › Why kubectl exec](operations.md#why-kubectl-exec).

**Can I upgrade Postgres to a new major version?**
Not in place — it needs dump+restore. Procedure in
[Operations › Postgres major upgrades](operations.md#postgres-major-version-upgrades).

**Should I run Collabora/Office?**
Not from this chart — run it separately and connect the `richdocuments` app.
[Add-ons › Office/Collabora](add-ons.md#office-and-collabora-not-included).

**Can I turn off ClamAV?**
Yes — `clamav.enabled: false`. It's heavy (1–3 GiB RAM). See
[Add-ons › ClamAV](add-ons.md#clamav-antivirus).

**How do I change the upload size limit?**
`nextcloud.settings.maxFileUploadSize`, and match it on your front door (e.g.
`nginx.ingress.kubernetes.io/proxy-body-size`). See [Configuration](configuration.md#hostname-and-server-settings).

**Can I reuse my existing PVCs / migrate from another chart?**
Yes — `nextcloud.persistence.*.existingClaim`. See
[Installation › Uninstalling](installation.md) and the README migration notes.

**How do I run `occ` commands?**
`kubectl -n <ns> exec deploy/<release> -c php -- php occ <command>`. Common ones in
[Operations › occ](operations.md#occ-the-nextcloud-admin-cli).

---

← [Troubleshooting](troubleshooting.md) · [Wiki home](README.md)
