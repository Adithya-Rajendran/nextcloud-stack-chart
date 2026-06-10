# nginx configuration for the Nextcloud-fpm + nginx Pod.
#
# VENDORED from the upstream Nextcloud nginx recipe:
#   https://docs.nextcloud.com/server/latest/admin_manual/installation/nginx.html
#
# Refresh procedure (manual, periodically):
#   1. Open the upstream doc.
#   2. Diff against this file. Bring over any new location blocks, MIME types,
#      or fastcgi_param entries.
#   3. Preserve the chart-specific bits below:
#        - set_real_ip_from / real_ip_header (from values.nextcloud.web.realIp)
#        - listen port (from values.nextcloud.service.targetPort)
#        - client_max_body_size (from values.nextcloud.settings.maxFileUploadSize)
#        - temp paths under /tmp (readOnlyRootFilesystem requires this)
#   4. helm lint && helm template, commit.
#
# Why not fetch at install time: network dependency, supply-chain risk, install
# fails if the URL is unreachable. Vendoring keeps the chart self-contained.
# Why not fetch at build time: same risk, plus the Nextcloud docs are HTML —
# extracting the nginx block reliably is more work than periodic manual diff.

worker_processes auto;
# Log to stdout/stderr so kubectl logs surfaces them and any future log
# aggregator picks them up without a sidecar tail. emptyDir log volumes
# disappear on pod restart anyway.
error_log /dev/stderr notice;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    types {
        text/javascript mjs;
        application/wasm wasm;
    }

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /dev/stdout main;

    server_tokens off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;

    # readOnlyRootFilesystem: true on the nginx container — temp paths must be
    # writable (provided by emptyDir).
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path       /tmp/proxy_temp;
    fastcgi_temp_path     /tmp/fastcgi_temp;
    uwsgi_temp_path       /tmp/uwsgi_temp;
    scgi_temp_path        /tmp/scgi_temp;

    # Real client IP, gated by the trusted-proxy CIDRs (only requests arriving
    # from those sources are allowed to set the forwarded header). Header +
    # recursive flag are resolved by the chart (generic X-Forwarded-For with
    # recursive on, or Cloudflare's single-valued CF-Connecting-IP with recursive
    # off when the cloudflare addon is enabled). The chart fails render on an
    # unsafe pairing — see nextcloud-stack.requireSafeRealIp in _helpers.tpl.
    # With no trusted CIDRs configured the whole block is omitted, so the header
    # is never honored and cannot be spoofed.
{{- $realIpCidrs := ternary .Values.cloudflare.realIp.trustedCidrs .Values.nextcloud.web.realIp.trustedCidrs .Values.cloudflare.enabled }}
{{- if $realIpCidrs }}
{{- range $realIpCidrs }}
    set_real_ip_from {{ . }};
{{- end }}
    real_ip_header   {{ include "nextcloud-stack.realIp.header" $ }};
    real_ip_recursive {{ include "nextcloud-stack.realIp.recursive" $ }};
{{- end }}

    map $arg_v $asset_immutable {
        "" "";
        default ", immutable";
    }

    upstream php-handler {
        server 127.0.0.1:9000;
    }

    server {
        listen {{ .Values.nextcloud.service.targetPort }};
        listen [::]:{{ .Values.nextcloud.service.targetPort }};
{{- if .Values.nextcloud.web.selfConnect.enabled }}
        # Internal HTTPS loopback so the Pod can reach its OWN public URL
        # (settings.overwriteHost, pinned to 127.0.0.1 via a hostAlias) for the
        # "connect to itself" setup checks. NOT reachable externally — the
        # Service/gateway use the plain listener above; this :443 is only hit by
        # the in-Pod loopback. TLS terminates here with the loopback cert.
        listen 443 ssl;
        listen [::]:443 ssl;
        ssl_certificate     /etc/nginx/selfconnect-tls/tls.crt;
        ssl_certificate_key /etc/nginx/selfconnect-tls/tls.key;
        ssl_protocols TLSv1.2 TLSv1.3;
{{- end }}
        server_name _;
        root /var/www/html;

        client_max_body_size {{ .Values.nextcloud.settings.maxFileUploadSize }};
        client_body_timeout  300s;
        client_body_buffer_size 512k;
        fastcgi_buffers 64 4K;

        gzip on;
        gzip_vary on;
        gzip_comp_level 4;
        gzip_min_length 256;
        gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
        gzip_types application/atom+xml text/javascript application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;

        # Security headers borrowed from upstream Nextcloud .htaccess.
        # X-XSS-Protection is omitted — deprecated in modern browsers.
        add_header Referrer-Policy                   "no-referrer"       always;
        add_header X-Content-Type-Options            "nosniff"           always;
        add_header X-Frame-Options                   "SAMEORIGIN"        always;
        add_header X-Permitted-Cross-Domain-Policies "none"              always;
        add_header X-Robots-Tag                      "noindex, nofollow" always;
{{- if .Values.nextcloud.web.httpsBehindProxy }}
        # HSTS — only meaningful when the site is served over HTTPS (TLS upstream).
        add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
{{- end }}

        fastcgi_hide_header X-Powered-By;

        index index.php index.html /index.php$request_uri;

        location = / {
            if ($http_user_agent ~ ^DavClnt) {
                return 302 /remote.php/webdav/$is_args$args;
            }
        }

        location = /robots.txt {
            allow all;
            log_not_found off;
            access_log off;
        }

        location ^~ /.well-known {
            location = /.well-known/carddav { return 301 /remote.php/dav/; }
            location = /.well-known/caldav  { return 301 /remote.php/dav/; }
            location /.well-known/acme-challenge { try_files $uri $uri/ =404; }
            location /.well-known/pki-validation { try_files $uri $uri/ =404; }
            return 301 /index.php$request_uri;
        }

        location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
        location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)                { return 404; }

        location ~ \.php(?:$|/) {
            rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|ocs-provider\/.+|.+\/richdocumentscode(_arm64)?\/proxy) /index.php$request_uri;

            fastcgi_split_path_info ^(.+?\.php)(/.*)$;
            set $path_info $fastcgi_path_info;
            try_files $fastcgi_script_name =404;

            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param PATH_INFO $path_info;
{{- if .Values.nextcloud.web.httpsBehindProxy }}
            # TLS is terminated upstream (ingress / gateway / cloudflared), so
            # Nextcloud must see HTTPS=on to set the Secure cookie flag and emit
            # https:// URLs. Disable via nextcloud.web.httpsBehindProxy=false.
            fastcgi_param HTTPS on;
{{- end }}
            fastcgi_param modHeadersAvailable true;
            fastcgi_param front_controller_active true;
            fastcgi_pass php-handler;

            fastcgi_intercept_errors on;
            fastcgi_request_buffering off;
            fastcgi_max_temp_file_size 0;
        }

        location ~ \.(?:css|js|mjs|svg|gif|png|jpg|ico|wasm|tflite|map|ogg|flac)$ {
            try_files $uri /index.php$request_uri;
            # nginx add_header inheritance: ANY add_header in a location cancels
            # ALL add_header directives inherited from the server block, so the
            # security headers must be repeated here (the upstream recipe does
            # exactly this). Without them, static responses — including
            # user-uploadable SVG — ship without nosniff/X-Frame-Options.
            add_header Cache-Control "public, max-age=15778463$asset_immutable";
            add_header Referrer-Policy                   "no-referrer"       always;
            add_header X-Content-Type-Options            "nosniff"           always;
            add_header X-Frame-Options                   "SAMEORIGIN"        always;
            add_header X-Permitted-Cross-Domain-Policies "none"              always;
            add_header X-Robots-Tag                      "noindex, nofollow" always;
{{- if .Values.nextcloud.web.httpsBehindProxy }}
            add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
{{- end }}
            access_log off;

            location ~ \.wasm$ {
                default_type application/wasm;
            }
        }

        location ~ \.woff2?$ {
            try_files $uri /index.php$request_uri;
            expires 7d;
            access_log off;
        }

        location /remote {
            return 301 /remote.php$request_uri;
        }

        location / {
            try_files $uri $uri/ /index.php$request_uri;
        }
    }
}
