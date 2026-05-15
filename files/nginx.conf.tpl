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

    # Real client IP from Cloudflare's CF-Connecting-IP header, gated by the
    # pod CIDR (only requests from cloudflared pods are trusted to set it).
    # real_ip_recursive is OFF: this only makes sense for single-valued
    # headers like CF-Connecting-IP. With X-Forwarded-For-style multi-value
    # chains, recursive=on lets a client append a trusted-looking address as
    # the rightmost link and bypass set_real_ip_from. The chart fails render
    # if `realIp.header` is set to a multi-valued header — see
    # nextcloud-stack.requireSingleValuedRealIpHeader in _helpers.tpl.
    set_real_ip_from {{ .Values.nextcloud.web.realIp.trustedCidr }};
    real_ip_header   {{ .Values.nextcloud.web.realIp.header }};
    real_ip_recursive off;

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
            # cloudflared terminates TLS — Nextcloud must see HTTPS=on so it
            # sets the Secure flag on cookies and emits correct URLs.
            fastcgi_param HTTPS on;
            fastcgi_param modHeadersAvailable true;
            fastcgi_param front_controller_active true;
            fastcgi_pass php-handler;

            fastcgi_intercept_errors on;
            fastcgi_request_buffering off;
            fastcgi_max_temp_file_size 0;
        }

        location ~ \.(?:css|js|mjs|svg|gif|png|jpg|ico|wasm|tflite|map|ogg|flac)$ {
            try_files $uri /index.php$request_uri;
            add_header Cache-Control "public, max-age=15778463$asset_immutable";
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
