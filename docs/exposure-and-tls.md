---
---

# Exposure & TLS

How to get traffic to Nextcloud from the outside world. The chart's Service stays
`ClusterIP`; you pick **one** front door. TLS is always terminated **at that front
door**, and the Pod sees plain HTTP — the chart forces `HTTPS=on` to PHP-FPM so
Nextcloud still emits `https://` URLs and Secure cookies.

Pick one of the three. All are off by default.

---

## Option 1 — Ingress

For clusters with an ingress controller (ingress-nginx, Traefik, …):

```yaml
ingress:
  enabled: true
  className: nginx
  host: cloud.example.com
  tls:
    enabled: true
    secretName: cloud-tls          # a kubernetes.io/tls Secret you provide
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "16g"   # match maxFileUploadSize
```

You bring the controller and the cert (e.g. cert-manager). With NetworkPolicy on,
allow the controller's namespace:

```yaml
networkPolicy:
  nextcloudIngressFrom:
    - namespaceSelector:
        matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
```

---

## Option 2 — Gateway API (HTTPRoute)

For clusters using Gateway API (Cilium Gateway, Envoy Gateway, Istio, …). TLS is
configured on the **Gateway listener**, not here — you just point at it:

```yaml
gatewayApi:
  enabled: true
  parentRef:
    name: shared-gateway
    namespace: gateway          # empty ⇒ same namespace as the release
    # sectionName: https        # optional specific listener
  hostnames: [cloud.example.com]
```

With the **Cilium** Gateway, the chart's NetworkPolicy allows the gateway proxy
**automatically** (`fromEntities: [ingress]`). That's a Cilium-specific identity
that plain NetworkPolicy v1 can't express — which is why this chart's policy is a
`CiliumNetworkPolicy`. See [Security](security.md#networkpolicy-requires-cilium).

> **Whiteboard tip:** when both `gatewayApi.enabled` and `whiteboard.enabled`, the
> chart adds a `/socket.io/` route on the **same hostname** to the whiteboard
> backend, so the collaboration WebSocket is same-origin — no separate
> subdomain/cert. Set `whiteboard.publicUrl` to the same host as Nextcloud. See
> [Add-ons › Whiteboard](add-ons.md#whiteboard).

---

## Option 3 — Cloudflare tunnel addon

No public ingress IP? The chart can run `cloudflared` for you and dial out to
Cloudflare's edge:

```yaml
cloudflare:
  enabled: true
  tunnel:
    enabled: true
    existingSecret: nextcloud-stack-cloudflared   # key: tunnel-token
  realIp:
    trustedCidrs: ["10.0.0.0/8"]                  # cloudflared pod CIDR
```

Steps:

1. Create the tunnel in the Cloudflare Zero Trust dashboard, copy its token.
2. `./scripts/bootstrap-secrets.sh --cloudflare-token '<TOKEN>'`
3. In the dashboard, point the tunnel's **Public Hostname** at
   `http://<release>.<ns>.svc.cluster.local:80`.
4. Install/upgrade with the values above.

The addon also switches real-IP handling to `CF-Connecting-IP` automatically and
opens the NetworkPolicy from the cloudflared pods. To run cloudflared **yourself**
elsewhere, set `cloudflare.tunnel.enabled: false` and fill
`cloudflare.externalTunnel.{namespace,podLabel}`.

---

## Real client IP

Behind any proxy, the Pod's TCP source is the proxy, not the user. nginx can
rewrite it from a forwarded header — but **only** for requests arriving from a
trusted source range, so the header can't be spoofed by other pods.

```yaml
nextcloud:
  web:
    realIp:
      header: X-Forwarded-For    # default; what ingress controllers/gateways emit
      recursive: true            # walk right-to-left skipping trusted hops
      trustedCidrs:
        - 10.0.0.0/8             # your proxy's pod CIDR
```

- Find your pod CIDR:
  `kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'`.
- **Empty `trustedCidrs` disables the rewrite** — Nextcloud then logs the proxy
  IP. That's safe (nothing can spoof it), just less informative.
- With the **Cloudflare** addon this is set automatically to `CF-Connecting-IP`
  (single-valued, `recursive: false`).
- The chart **refuses to render** a multi-valued header with `recursive: false`,
  because that combination is spoofable.

`recursive: true` means `trustedCidrs` must cover **every** proxy hop in front of
nginx, and each must *append* to (not overwrite) the header. One trusted hop (a
single ingress controller or gateway) is the common, safe case.

---

## The self-connect listener

Nextcloud's admin "Setup checks" include several that require the Pod to
HTTP-reach **its own public URL** (WebDAV, `.well-known`, `.mjs`/`.otf` MIME,
the OCS provider, security headers). Some proxies/CNIs can't "hairpin" a backend
Pod back to itself through the external entrypoint — e.g. the Cilium Gateway
returns `403` on that self-loop — so those checks fail even though the features
work for real users.

`nextcloud.web.selfConnect` fixes it without changing anything external:

```yaml
nextcloud:
  web:
    selfConnect:
      enabled: true
      tlsSecret: nextcloud-loopback-tls   # a kubernetes.io/tls cert for overwriteHost
```

When enabled, nginx adds an internal HTTPS listener on `:443` (using
`NET_BIND_SERVICE`, auto-added to the web container) and a `hostAlias` points
`overwriteHost` at `127.0.0.1` — so **only self-requests** resolve to the local
nginx. The Service/gateway path is untouched. The TLS Secret must be valid for
`overwriteHost` and trusted by the image's CA bundle (a cert-manager Let's Encrypt
cert works well).

---

## HSTS

`nextcloud.web.httpsBehindProxy: true` (the default) also emits an HSTS header.
Keep it on for any HTTPS install.

---

← [Values Reference](values-reference.md) · [Wiki home](README.md) · Next: [Security Model](security.md)
