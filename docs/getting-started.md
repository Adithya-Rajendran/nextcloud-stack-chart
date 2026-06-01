# Getting Started

This page gets you from nothing to a working Nextcloud in about ten minutes. For
the why-behind-each-step version, see **[Installation](installation.md)**.

---

## 1. Prerequisites

You'll need:

- **A Kubernetes cluster** (1.27+ recommended) and `kubectl` pointed at it.
- **Helm 3.**
- **A clone of this chart**, and a terminal in its root (the folder with
  `Chart.yaml`).
- **A StorageClass** that can provision `ReadWriteOnce` volumes (the default one
  is fine). Check with `kubectl get storageclass`.
- **One of:** a free Docker account for `dhi.io` (default), **or** nothing
  extra if you use the public-image overlay (see step 4).

Strongly recommended for the security features:

- **Cilium** as your CNI — the chart's NetworkPolicy is a `CiliumNetworkPolicy`.
  On another CNI you'll set `networkPolicy.enabled: false` (see
  [Security](security.md#networkpolicy-requires-cilium)).
- A way to terminate TLS and route traffic in: an **ingress controller**, a
  **Gateway API** Gateway, or a **Cloudflare tunnel** (see
  [Exposure & TLS](exposure-and-tls.md)).

---

## 2. Create the namespace and apply restricted PodSecurity

The chart's Pods are all restricted-PSS compatible, so opt in:

```bash
kubectl create namespace nextcloud
kubectl label namespace nextcloud \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

---

## 3. Create the secrets

The chart **never** generates or accepts inline passwords — you pre-create the
secrets and point the chart at them. The bundled script does it for you:

```bash
./scripts/bootstrap-secrets.sh --namespace nextcloud --release nextcloud-stack
```

This creates `nextcloud-stack-admin`, `nextcloud-stack-postgres`, and
`nextcloud-stack-valkey`, and **prints the admin password once** — save it now.
(Add `--whiteboard`, `--metrics`, or `--cloudflare-token '<TOKEN>'` if you'll use
those add-ons.) Details: [Security › Secrets](security.md#secrets-are-external-only).

---

## 4. Pick your image source

**Option A — Docker Hardened Images (default).** Create the pull secret for
`dhi.io` (a free Docker account is enough — no paid subscription):

```bash
kubectl -n nextcloud create secret docker-registry dhi-pull \
  --docker-server=dhi.io --docker-username=<user> \
  --docker-password='<docker-pat>' --docker-email=<email>
```

**Option B — public images (Docker Hub).** Skip the pull secret and add
`-f values-public.yaml` to every `helm` command below.

---

## 5. Configure your install

Copy the example and edit the essentials — at minimum your **hostname** and
**exposure**:

```bash
cp example-values.yaml my-values.yaml
```

The example exposes via ingress-nginx. Change `ingress.host`, `ingress.className`,
`nextcloud.settings.overwriteHost`, and `trustedDomains` to your domain. Want
Gateway API or a Cloudflare tunnel instead? See
[Exposure & TLS](exposure-and-tls.md).

---

## 6. Install

```bash
# eyeball the rendered manifests first (optional but nice)
helm template nextcloud-stack . -n nextcloud -f my-values.yaml | less

# install
helm install nextcloud-stack . -n nextcloud -f my-values.yaml
```

(Using public images? Append `-f values-public.yaml` to both commands.)

A post-install hook Job runs the database migrations automatically. Watch
everything come up:

```bash
kubectl -n nextcloud get pods -w
```

---

## 7. Verify

```bash
helm test nextcloud-stack -n nextcloud
kubectl -n nextcloud exec deploy/nextcloud-stack -c php -- php occ status
```

`occ status` should report `installed: true`. Then browse to your hostname and
log in as `admin` with the password from step 3.

---

## What next?

- **Lock in the exact images** with digest pinning → [Installation › Digest pinning](installation.md#5-optional-pin-image-digests).
- **Turn on backups** → [Backup & Restore](backup-and-restore.md).
- **Wire up metrics** → [Monitoring](monitoring.md).
- **Tune storage and resources** → [Storage & Scaling](storage-and-scaling.md).

---

← [Wiki home](README.md) · Next: [Installation](installation.md)
