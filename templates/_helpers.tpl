{{/*
Common template helpers.

Naming convention: every resource uses one of these helpers so the chart can be
installed under multiple release names without collision. Resource names are
short and release-qualified, with no hardcoded prefix.
*/}}

{{/*
Resolve the chart's "name". Override with values.nameOverride.
*/}}
{{- define "nextcloud-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Full release-qualified name. Override with values.fullnameOverride.
*/}}
{{- define "nextcloud-stack.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.nextcloud.fullname" -}}{{ include "nextcloud-stack.fullname" . }}{{- end -}}
{{- define "nextcloud-stack.postgres.fullname" -}}{{ include "nextcloud-stack.fullname" . }}-postgres{{- end -}}
{{- define "nextcloud-stack.valkey.fullname"   -}}{{ include "nextcloud-stack.fullname" . }}-valkey{{- end -}}
{{- define "nextcloud-stack.clamav.fullname"   -}}{{ include "nextcloud-stack.fullname" . }}-clamav{{- end -}}

{{- define "nextcloud-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels - applied to every resource.
*/}}
{{- define "nextcloud-stack.labels" -}}
helm.sh/chart: {{ include "nextcloud-stack.chart" . }}
{{ include "nextcloud-stack.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "nextcloud-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nextcloud-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "nextcloud-stack.nextcloud.selectorLabels" -}}
{{ include "nextcloud-stack.selectorLabels" . }}
app.kubernetes.io/component: nextcloud
{{- end -}}

{{- define "nextcloud-stack.postgres.selectorLabels" -}}
{{ include "nextcloud-stack.selectorLabels" . }}
app.kubernetes.io/component: postgres
{{- end -}}

{{- define "nextcloud-stack.valkey.selectorLabels" -}}
{{ include "nextcloud-stack.selectorLabels" . }}
app.kubernetes.io/component: valkey
{{- end -}}

{{- define "nextcloud-stack.clamav.selectorLabels" -}}
{{ include "nextcloud-stack.selectorLabels" . }}
app.kubernetes.io/component: clamav
{{- end -}}

{{- define "nextcloud-stack.nextcloud.labels" -}}
helm.sh/chart: {{ include "nextcloud-stack.chart" . }}
{{ include "nextcloud-stack.nextcloud.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "nextcloud-stack.postgres.labels" -}}
helm.sh/chart: {{ include "nextcloud-stack.chart" . }}
{{ include "nextcloud-stack.postgres.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "nextcloud-stack.valkey.labels" -}}
helm.sh/chart: {{ include "nextcloud-stack.chart" . }}
{{ include "nextcloud-stack.valkey.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "nextcloud-stack.clamav.labels" -}}
helm.sh/chart: {{ include "nextcloud-stack.chart" . }}
{{ include "nextcloud-stack.clamav.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "nextcloud-stack.cloudflared.fullname" -}}{{ include "nextcloud-stack.fullname" . }}-cloudflared{{- end -}}

{{- define "nextcloud-stack.cloudflared.selectorLabels" -}}
{{ include "nextcloud-stack.selectorLabels" . }}
app.kubernetes.io/component: cloudflared
{{- end -}}

{{- define "nextcloud-stack.cloudflared.labels" -}}
helm.sh/chart: {{ include "nextcloud-stack.chart" . }}
{{ include "nextcloud-stack.cloudflared.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "nextcloud-stack.whiteboard.fullname" -}}{{ include "nextcloud-stack.fullname" . }}-whiteboard{{- end -}}

{{- define "nextcloud-stack.whiteboard.selectorLabels" -}}
{{ include "nextcloud-stack.selectorLabels" . }}
app.kubernetes.io/component: whiteboard
{{- end -}}

{{- define "nextcloud-stack.whiteboard.labels" -}}
helm.sh/chart: {{ include "nextcloud-stack.chart" . }}
{{ include "nextcloud-stack.whiteboard.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "nextcloud-stack.backup.fullname" -}}{{ include "nextcloud-stack.fullname" . }}-backup{{- end -}}

{{- define "nextcloud-stack.backup.selectorLabels" -}}
{{ include "nextcloud-stack.selectorLabels" . }}
app.kubernetes.io/component: backup
{{- end -}}

{{- define "nextcloud-stack.backup.labels" -}}
helm.sh/chart: {{ include "nextcloud-stack.chart" . }}
{{ include "nextcloud-stack.backup.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "nextcloud-stack.metrics.fullname" -}}{{ include "nextcloud-stack.fullname" . }}-metrics{{- end -}}

{{- define "nextcloud-stack.metrics.selectorLabels" -}}
{{ include "nextcloud-stack.selectorLabels" . }}
app.kubernetes.io/component: metrics
{{- end -}}

{{- define "nextcloud-stack.metrics.labels" -}}
helm.sh/chart: {{ include "nextcloud-stack.chart" . }}
{{ include "nextcloud-stack.metrics.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Internal URL the metrics exporter uses to reach Nextcloud's serverinfo API.
Defaults to the in-cluster Service FQDN (the serverinfo token endpoint does NOT
require the host to be a trusted_domain, verified empirically). Override with
metrics.nextcloudUrl.
*/}}
{{- define "nextcloud-stack.metrics.nextcloudUrl" -}}
{{- if .Values.metrics.nextcloudUrl -}}
{{ .Values.metrics.nextcloudUrl }}
{{- else -}}
http://{{ include "nextcloud-stack.nextcloud.fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local:{{ .Values.nextcloud.service.port }}
{{- end -}}
{{- end -}}

{{/*
Image reference. Prefers digest pinning when .digest is set; otherwise tag.
Digest pinning protects against tag mutation (key for supply-chain integrity
on a publicly-exposed install). Tags like ":1" or ":18" can shift under us.
Use as: {{ include "nextcloud-stack.image" .Values.nextcloud.image }}
*/}}
{{- define "nextcloud-stack.image" -}}
{{- $registry := default "docker.io" .registry -}}
{{- if .digest -}}
{{- printf "%s/%s@%s" $registry .repository .digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .repository .tag -}}
{{- end -}}
{{- end -}}

{{/*
Secret-name resolution. Returns the existingSecret if set, otherwise the
chart-managed Secret name.
Args: (dict "existing" $existingSecret "default" "chart-managed-name")
*/}}
{{- define "nextcloud-stack.secretName" -}}
{{- if .existing -}}{{ .existing }}{{- else -}}{{ .default }}{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.postgres.host" -}}
{{ include "nextcloud-stack.postgres.fullname" . }}
{{- end -}}

{{- define "nextcloud-stack.valkey.host" -}}
{{ include "nextcloud-stack.valkey.fullname" . }}
{{- end -}}

{{- define "nextcloud-stack.clamav.host" -}}
{{ include "nextcloud-stack.clamav.fullname" . }}
{{- end -}}

{{- define "nextcloud-stack.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
overwrite.cli.url - derived from overwriteHost/Protocol if not set explicitly.
*/}}
{{- define "nextcloud-stack.overwriteCliUrl" -}}
{{- if .Values.nextcloud.settings.overwriteCliUrl -}}
{{ .Values.nextcloud.settings.overwriteCliUrl }}
{{- else -}}
{{ .Values.nextcloud.settings.overwriteProtocol }}://{{ .Values.nextcloud.settings.overwriteHost }}
{{- end -}}
{{- end -}}

{{/*
Validate that an existingSecret is set. The chart no longer generates secrets
or accepts inline passwords — external secrets only.

Args (dict):
  existing : the .existingSecret value (string)
  section  : values.yaml path to the section (e.g. "postgres.auth")
*/}}
{{- define "nextcloud-stack.requireSecret" -}}
{{- $existing := index . "existing" -}}
{{- $section := index . "section" -}}
{{- if not $existing -}}
{{- fail (printf "%s.existingSecret is required. Pre-create the Secret with scripts/bootstrap-secrets.sh and set %s.existingSecret to its name." $section $section) -}}
{{- end -}}
{{- end -}}

{{/*
Real-client-IP resolution.

The chart supports two proxy modes, resolved here so nginx.conf, config.php, and
NOTES all agree:
  * Generic (default): a reverse proxy / ingress controller / gateway sets a
    forwarded header. Defaults to the multi-valued X-Forwarded-For with
    real_ip_recursive ON (walk the chain right-to-left skipping trusted proxies).
  * Cloudflare (cloudflare.enabled): the single-valued CF-Connecting-IP with
    real_ip_recursive OFF. cloudflare.realIp.* overrides nextcloud.web.realIp.*.

set_real_ip_from is gated to the trusted CIDRs; an empty CIDR list disables the
rewrite entirely (Nextcloud sees the proxy IP — never spoofable). Consumers pick
the effective CIDR list with:
  ternary .Values.cloudflare.realIp.trustedCidrs .Values.nextcloud.web.realIp.trustedCidrs .Values.cloudflare.enabled
*/}}
{{- define "nextcloud-stack.realIp.header" -}}
{{- if .Values.cloudflare.enabled -}}{{ .Values.cloudflare.realIp.header }}{{- else -}}{{ .Values.nextcloud.web.realIp.header }}{{- end -}}
{{- end -}}

{{/* nginx real_ip_recursive value: on/off. Cloudflare mode is always off. */}}
{{- define "nextcloud-stack.realIp.recursive" -}}
{{- if .Values.cloudflare.enabled -}}off{{- else if .Values.nextcloud.web.realIp.recursive -}}on{{- else -}}off{{- end -}}
{{- end -}}

{{/* Nextcloud forwarded_for_headers entry derived from the effective header,
e.g. X-Forwarded-For -> HTTP_X_FORWARDED_FOR, CF-Connecting-IP -> HTTP_CF_CONNECTING_IP. */}}
{{- define "nextcloud-stack.realIp.phpHeader" -}}
{{- printf "HTTP_%s" (include "nextcloud-stack.realIp.header" . | upper | replace "-" "_") -}}
{{- end -}}

{{/*
Validate the effective real-IP config is not spoofable: a multi-valued header
(X-Forwarded-For / Forwarded) MUST be paired with recursive on. A single-valued
header (CF-Connecting-IP) is safe either way. Only enforced when real-IP
rewriting is actually enabled (trustedCidrs non-empty).
*/}}
{{- define "nextcloud-stack.requireSafeRealIp" -}}
{{- $cidrs := ternary .Values.cloudflare.realIp.trustedCidrs .Values.nextcloud.web.realIp.trustedCidrs .Values.cloudflare.enabled -}}
{{- if $cidrs -}}
{{- $h := include "nextcloud-stack.realIp.header" . -}}
{{- $rec := include "nextcloud-stack.realIp.recursive" . -}}
{{- if and (or (eq $h "X-Forwarded-For") (eq $h "Forwarded")) (eq $rec "off") -}}
{{- fail (printf "Real-IP misconfiguration: header %q is multi-valued but real_ip_recursive is off — nginx would read a spoofable address. Set nextcloud.web.realIp.recursive=true, or use a single-valued header such as CF-Connecting-IP (the Cloudflare addon does this automatically)." $h) -}}
{{- end -}}
{{- end -}}
{{- end -}}
