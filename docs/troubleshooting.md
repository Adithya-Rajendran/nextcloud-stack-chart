# Troubleshooting

Symptoms → causes → fixes. Includes the non-obvious ones learned the hard way.

---

## Install / render

### `helm install` fails about a missing Secret or value
A required `existingSecret` is empty, or you enabled an add-on without its required
value (`gatewayApi.parentRef.name`, `cloudflare.tunnel.existingSecret`,
`whiteboard.auth.existingSecret`, `metrics.auth.existingSecret`). The error names
the exact key. Run `scripts/bootstrap-secrets.sh` (with the right flags) and/or set
the value. This is a deliberate guard rail, not a bug.

### `helm install/upgrade` hangs forever
Likely the post-install **hook Job can't be watched** on your cluster (e.g. the
Rancher API proxy times out the watch). Install with `--no-hooks` and run the
migration step yourself — see
[Operations › hook-restricted clusters](operations.md#upgrading-on-hook-restricted-clusters).

---

## Images

### `ImagePullBackOff` / `401 Unauthorized` on `dhi.io`
The DHI pull secret is missing or **keyed to the wrong registry**. The
`docker-registry` secret must use `--docker-server=dhi.io` — a Docker-Hub-keyed
secret returns `401` against `dhi.io`. Recreate it:

```bash
kubectl -n nextcloud create secret docker-registry dhi-pull \
  --docker-server=dhi.io --docker-username=<user> \
  --docker-password='<docker-pat>' --docker-email=<email>
```

…and ensure `imagePullSecrets: [{name: dhi-pull}]` is set — a **free** Docker account is enough. Prefer plain Docker Hub images?
Use `-f values-public.yaml` instead.

### `ImagePullBackOff` on a public image
Check the tag exists and your nodes can reach the registry. With
`-f values-public.yaml`, confirm you also **removed** the `dhi-pull` reference if
those images are public.

---

## Networking / exposure

### The site is unreachable through my ingress / gateway
1. Confirm the Pod is Ready and the Service has endpoints:
   `kubectl -n nextcloud get endpoints nextcloud-stack`.
2. With NetworkPolicy on, the front door must be allowed. The **Cilium Gateway**
   and the **Cloudflare** addon are auto-allowed; **any other** front (e.g. a
   separate ingress controller) must be added to
   `networkPolicy.nextcloudIngressFrom`, then `helm upgrade`.

### `503` specifically behind a Gateway
The chart's policy must be a **CiliumNetworkPolicy** and you must be on Cilium —
the gateway proxy's identity (`fromEntities: [ingress]`) can't be expressed by
standard NetworkPolicy v1, so a v1 policy silently blocks it. On a non-Cilium CNI,
set `networkPolicy.enabled: false` and bring your own policy.

### Everything times out between pods, even internally
NetworkPolicy is on but your CNI doesn't enforce `CiliumNetworkPolicy` (you're not
on Cilium). Either install Cilium or set `networkPolicy.enabled: false`. See
[Security](security.md#networkpolicy-requires-cilium).

### nginx logs show proxy pod IPs instead of real client IPs
`nextcloud.web.realIp.trustedCidrs` is empty or doesn't cover your proxy's pod
CIDR. Set it from
`kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'`. The install NOTES print
the configured value as a sanity check.

---

## Nextcloud app

### Admin "Setup checks": "cannot connect to itself" / WebDAV / `.well-known`
The Pod can't HTTP-reach its own public URL because your proxy/CNI won't hairpin
the backend back to itself (the Cilium Gateway returns `403` on that self-loop).
The features work for real users; only the self-check fails. Enable the loopback
listener:

```yaml
nextcloud:
  web:
    selfConnect:
      enabled: true
      tlsSecret: <a kubernetes.io/tls cert for overwriteHost>
```

See [Exposure & TLS › self-connect](exposure-and-tls.md#the-self-connect-listener).

### "Maintenance window not set" / "no default phone region" warnings
Cosmetic admin warnings. Set `nextcloud.settings.defaultPhoneRegion` and
`maintenanceWindowStart`. Mimetype/migration warnings are cleared by the db-migrate
Job (`maintenance:repair`).

### `/status.php` says `installed: false` after a long wait
First-time `occ maintenance:install` hasn't finished (slow storage, big initial
copy). Tail it:
`kubectl -n nextcloud logs deploy/nextcloud-stack -c php -f`. Raise
`nextcloud.dbMigrateJob.activeDeadlineSeconds`/`rolloutStatusTimeoutSeconds` if a
Job hit `DeadlineExceeded`.

### Pod stuck in `Init:0/1` (`wait-for-postgres`)
Postgres isn't reachable yet. Check
`kubectl -n nextcloud logs -l app.kubernetes.io/component=postgres`. If Postgres is
crash-looping, look at its PVC and the `nextcloud-db-password` Secret.

---

## Storage

### `Multi-Attach error for volume …`
Two Pods are trying to mount the same RWO PVC. Usually a rolling update where
`strategy: Recreate` got changed, or a stray Pod from a failed rollout. Ensure the
Nextcloud Deployment uses `Recreate` and scale to a single replica.

### PVC won't grow / upgrade errors on a size change
You can only **increase** a PVC, and only if the StorageClass has
`allowVolumeExpansion: true`. Don't lower a size in values (Kubernetes rejects
shrink → upgrade error). Full procedure:
[Storage & Scaling › Expanding a PVC](storage-and-scaling.md#expanding-a-pvc).

### PVC condition `FileSystemResizePending` after expansion
The volume grew but the filesystem resize needs a Pod restart on your driver:
`kubectl -n nextcloud rollout restart deploy/nextcloud-stack`.

---

## Monitoring

### Exporter logs `wrong credentials` / Prometheus target `down`
The token in the `<release>-metrics` Secret doesn't match the one in Nextcloud. Set
them equal: `occ config:app:set serverinfo token --value=<token-from-secret>`, then
`rollout restart deploy/<release>-metrics`. The db-migrate Job does this
automatically on a hooked upgrade.

### Exporter logs `too many requests`
Something is hitting `/metrics` too often (each hit triggers an upstream serverinfo
scrape), tripping Nextcloud's brute-force throttle. Don't probe `/metrics` with
HTTP health checks (the chart uses `tcpSocket` for this reason) and keep your scrape
interval reasonable (≥30s). After fixing, restart the exporter to get a fresh pod
IP/clean slate.

---

## ClamAV

### ClamAV Pod takes ages to become Ready
It downloads ~250 MB of signatures on cold start (they live on an `emptyDir`). This
is normal. If memory-constrained it may OOM — raise its limit or set
`clamav.enabled: false`.

---

## Getting more detail

```bash
kubectl -n nextcloud get pods
kubectl -n nextcloud describe pod <pod>            # events, probe failures
kubectl -n nextcloud logs <pod> -c <container>     # php / web / postgres / …
kubectl -n nextcloud logs -l app.kubernetes.io/component=metrics
helm -n nextcloud get values nextcloud-stack       # what you actually deployed
```

Still stuck? See the [FAQ](faq.md) or open an issue with the output above.

---

← [Operations](operations.md) · [Wiki home](README.md) · Next: [FAQ](faq.md)
