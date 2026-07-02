# Add-ons

Optional components beyond the core (Nextcloud + Postgres + Valkey). Each is a
single `enabled` toggle plus a little config.

| Add-on | Value | Default | What it does |
|---|---|---|---|
| ClamAV | `clamav.enabled` | **on** | scans uploads for malware |
| Whiteboard | `whiteboard.enabled` | off | real-time collaborative whiteboard |
| Metrics | `metrics.enabled` | off | Prometheus exporter → [Monitoring](monitoring.md) |
| Backup | `backup.enabled` | off | scheduled backups → [Backup & Restore](backup-and-restore.md) |
| Cloudflare tunnel | `cloudflare.enabled` | off | exposure → [Exposure & TLS](exposure-and-tls.md#option-3--cloudflare-tunnel-addon) |

This page covers ClamAV and Whiteboard, plus notes on Office/Collabora (not
included).

---

## ClamAV (antivirus)

On by default with the DHI image. It runs a clamd daemon; Nextcloud's
`files_antivirus` app is wired up automatically by the db-migrate Job to scan
on upload.

```yaml
clamav:
  enabled: true
  resources:
    requests: { cpu: 250m, memory: 1Gi }
    limits:   { cpu: "2",  memory: 3Gi }
  signaturesEmptyDirSize: 1Gi
```

Things to know:

- **It's heavy.** 1–3 GiB RAM and a **~250 MB signature download on every cold
  start** (signatures live on an `emptyDir`, so freshclam re-fetches them when the
  Pod restarts). Give it time to become Ready.
- **Tight on memory?** Set `clamav.enabled: false` — Nextcloud works fine without
  it; you just lose on-upload scanning.
- The public-image overlay leaves ClamAV **off** by default (the public non-root
  clamav image needs per-cluster validation).

---

## Whiteboard

Nextcloud Whiteboard's real-time backend (a Node.js Socket.IO server). There's no
DHI image, so it uses the hardened public GHCR release image (documented
exception). The db-migrate Job installs the `whiteboard` app and wires the shared
JWT + backend URL for you.

```yaml
whiteboard:
  enabled: true
  replicas: 2                       # HA — needs the redis backend below
  storageStrategy: redis            # share live board state via Valkey
  nextcloudUrl: https://cloud.example.com   # backend → Nextcloud (JWT verify / API)
  publicUrl:    https://cloud.example.com   # browsers reach the backend here
  auth:
    existingSecret: nextcloud-stack-whiteboard   # keys: jwt-secret-key, redis-url
```

Create the Secret with `./scripts/bootstrap-secrets.sh --whiteboard`.

### HA and the storage strategy

- `storageStrategy: redis` (default) shares live board state across replicas via
  the chart's **Valkey** — so `replicas: 2+` is real HA. This needs
  `valkey.enabled: true`.
- `storageStrategy: lww` is in-memory and **single-instance only**. The chart
  **fails render** if `replicas > 1` without the redis backend.

### Same-origin WebSocket (recommended)

Set `publicUrl` to the **same host as Nextcloud**. With `gatewayApi.enabled`, the
chart routes `/socket.io/` on that host to the whiteboard backend, so the
collaboration WebSocket is **same-origin** — no separate subdomain, no extra cert,
no cross-origin browser failures. (Behind a plain Ingress you'd add an equivalent
`/socket.io/` route yourself, or use a separate hostname.)

### Recording is off (on purpose)

Server-side board recording launches a bundled Chromium with `--no-sandbox`. With
no gVisor/Kata sandbox runtime that's unsafe, so it's disabled and intentionally
hard to enable. Leave `whiteboard.recording.enabled: false` unless you've sandboxed
the runtime.

---

## SSO / OIDC login (user_oidc)

Connects Nextcloud login to an OIDC IdP (tested with authentik) with **zero
manual steps** — the db-migrate Job installs `user_oidc` and upserts the
provider on every deploy.

```bash
./scripts/bootstrap-secrets.sh --sso     # creates <release>-sso (client-id/client-secret)
```

```yaml
sso:
  enabled: true
  auth:
    existingSecret: nextcloud-stack-sso
  provider:
    identifier: authentik
    discoveryUri: https://authentik.example.com/application/o/nextcloud/.well-known/openid-configuration
```

Register the same client-id/secret at the IdP. For authentik, a blueprint can
read the secret via `!Env` so both sides stay declarative; redirect URI is
`https://<overwriteHost>/apps/user_oidc/code`. Re-running is safe: the provider
upsert is keyed on `identifier`.

## Office / Collabora (not included)

Document editing (Collabora Online / Nextcloud Office) is **not** part of this
chart — it has an independent lifecycle and no shared state with the stack. It's
also harder to harden (no DHI image; the document-conversion sandbox has its own
requirements).

If you want it, run Collabora separately and connect Nextcloud's
`richdocuments` app to it. A common hardened pattern is to run Collabora on an
isolated host (or with a sandboxed container runtime) and route document traffic to
it — but that's deployment-specific and out of scope here. Whiteboard covers the
real-time-collaboration use case without that footprint.

---

← [Monitoring](monitoring.md) · [Wiki home](README.md) · Next: [Operations](operations.md)
