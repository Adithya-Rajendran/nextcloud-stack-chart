# Installation

The complete install walkthrough, with the reasoning behind each step. For the
condensed version see [Getting Started](getting-started.md).

All commands run from the **chart root** (the directory containing `Chart.yaml`).

---

## 1. Namespace + PodSecurity

```bash
kubectl create namespace nextcloud
kubectl label namespace nextcloud \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

Every Pod the chart ships is compatible with the `restricted`
[Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/),
so there's no reason not to enforce it. If a Pod ever fails admission, that's a
signal worth investigating — see [Security](security.md).

---

## 2. Secrets (external-only)

This chart deliberately keeps **all** secret material out of `values.yaml` and out
of Helm release metadata. You create Kubernetes Secrets up front and reference
them by name with `*.auth.existingSecret`. The chart **fails to render** if a
required secret reference is empty — a guard rail, not a nuisance.

The bundled script generates strong passwords and creates everything:

```bash
./scripts/bootstrap-secrets.sh --namespace nextcloud --release nextcloud-stack
```

| Flag | Adds the Secret | Keys |
|---|---|---|
| *(always)* | `<release>-admin` | `admin-user`, `admin-password` |
| *(always)* | `<release>-postgres` | `nextcloud-db-password` |
| *(always)* | `<release>-valkey` | `valkey-password`, `valkey.conf` |
| `--whiteboard` | `<release>-whiteboard` | `jwt-secret-key`, `redis-url` |
| `--metrics` | `<release>-metrics` | `token` |
| `--cloudflare-token '<TOKEN>'` | `<release>-cloudflared` | `tunnel-token` |

Other flags: `--force` (overwrite existing), `--kubeconfig PATH`.

> **The admin password is printed once at the end.** Save it. You can re-read it
> later from the Secret, or reset it with
> `occ user:resetpassword admin` (see [Operations](operations.md)).

Prefer an external secrets manager (Vault, External Secrets Operator, SOPS)? Just
make sure the Secrets exist with the keys above before you install — the chart
doesn't care how they got there. See [Security › Secrets](security.md#secrets-are-external-only).

---

## 3. Choose your image source

### Option A: Docker Hardened Images (default)

The default images live on `dhi.io`, which needs a **free** Docker account (not a
paid subscription) to pull, so the
cluster needs credentials to pull them:

```bash
kubectl -n nextcloud create secret docker-registry dhi-pull \
  --docker-server=dhi.io --docker-username=<user> \
  --docker-password='<docker-pat>' --docker-email=<email>
```

Then reference it (the example values already do):

```yaml
imagePullSecrets:
  - name: dhi-pull
```

> **Heads-up:** the pull secret must be keyed to the **`dhi.io`** registry. A
> Docker-Hub-keyed secret returns `401` against `dhi.io`. (See
> [Troubleshooting](troubleshooting.md#imagepullbackoff--401-unauthorized-on-dhiio).)

### Option B: public images (Docker Hub)

Add the overlay and skip the pull secret entirely:

```bash
helm install nextcloud-stack . -n nextcloud -f my-values.yaml -f values-public.yaml
```

`values-public.yaml` swaps every image for a public Docker Hub equivalent
(`nginxinc/nginx-unprivileged`, `postgres:17-alpine`, `valkey`, `rancher/kubectl`,
`curlimages/curl`) and adjusts the UIDs to match. ClamAV is left off by default in
the public overlay (the public non-root clamav image needs per-cluster validation).

---

## 4. Configure

Start from the example and edit:

```bash
cp example-values.yaml my-values.yaml
```

At minimum, set:

- `nextcloud.settings.overwriteHost` and `trustedDomains` — your public hostname.
- One exposure block — `ingress`, `gatewayApi`, or `cloudflare` (see
  [Exposure & TLS](exposure-and-tls.md)).
- `nextcloud.web.realIp.trustedCidrs` — your proxy's pod CIDR, so logs show real
  client IPs (find it with
  `kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'`).
- `networkPolicy.nextcloudIngressFrom` — the namespace of your ingress
  controller, if you use one (Gateway/Cloudflare are auto-allowed).

A full tour of the knobs is in [Configuration](configuration.md); every value is
in [Values Reference](values-reference.md).

---

## 5. (Optional) Pin image digests

Tags can move; digests can't. Resolve every image to its current digest and apply
the result as an extra overlay for a fully reproducible, supply-chain-pinned
install:

```bash
./scripts/pin-digests.sh > pins.yaml
helm install nextcloud-stack . -n nextcloud -f my-values.yaml -f pins.yaml
```

You can re-run `pin-digests.sh` whenever you want to adopt newer images, review
the diff, and `helm upgrade`.

---

## 6. Install

```bash
# render and review (recommended)
helm template nextcloud-stack . -n nextcloud -f my-values.yaml | less

# install
helm install nextcloud-stack . -n nextcloud -f my-values.yaml
```

What happens on install:

1. The Secrets you created are referenced (not created) by the chart.
2. Postgres comes up; the Nextcloud Pod waits for it (`wait-for-postgres` init
   container), then runs first-time `occ maintenance:install`.
3. A **post-install hook Job** runs the idempotent database migrations
   (`occ db:add-missing-*`, repairs) and wires up any enabled add-ons.

Watch it:

```bash
kubectl -n nextcloud get pods -w
```

> **On a slow or hook-restricted cluster** (e.g. behind the Rancher API proxy,
> where the hook's watch can time out), install with `--no-hooks` and run the
> migration step yourself afterwards. See
> [Operations › Upgrading on restricted clusters](operations.md#upgrading-on-hook-restricted-clusters).

---

## 7. Verify and log in

```bash
helm test nextcloud-stack -n nextcloud
kubectl -n nextcloud exec deploy/nextcloud-stack -c php -- php occ status
```

`occ status` → `installed: true`, `maintenance: false`. Browse to your hostname
and log in as `admin`.

---

## Uninstalling

```bash
helm uninstall nextcloud-stack -n nextcloud
```

PVCs are annotated `helm.sh/resource-policy: keep`, so **your data survives an
uninstall**. To remove it too, delete the PVCs explicitly afterwards
(`kubectl -n nextcloud delete pvc nextcloud-stack-data nextcloud-stack-webroot
data-nextcloud-stack-postgres-0`). Be sure — this is irreversible.

---

← [Getting Started](getting-started.md) · [Wiki home](README.md) · Next: [Architecture](architecture.md)
