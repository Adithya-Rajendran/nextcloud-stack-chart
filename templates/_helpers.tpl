{{/*
Common template helpers.

Naming convention: every resource uses one of these helpers so the chart can be
installed under multiple release names without collision. The names follow the
DEPLOYMENT_PLAN.md section 11 convention - short, no "aio" prefix.
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
