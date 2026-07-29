{{/* Chart name */}}
{{- define "phoenix-liveview.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name */}}
{{- define "phoenix-liveview.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "phoenix-liveview.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Common labels */}}
{{- define "phoenix-liveview.labels" -}}
helm.sh/chart: {{ include "phoenix-liveview.chart" . }}
{{ include "phoenix-liveview.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: phoenix-liveview
{{- end }}

{{/* Selector labels */}}
{{- define "phoenix-liveview.selectorLabels" -}}
app.kubernetes.io/name: {{ include "phoenix-liveview.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "phoenix-liveview.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "phoenix-liveview.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Name of the Secret holding DATABASE_URL / SECRET_KEY_BASE */}}
{{- define "phoenix-liveview.secretName" -}}
{{- if .Values.secret.existingSecret }}
{{- .Values.secret.existingSecret }}
{{- else }}
{{- include "phoenix-liveview.fullname" . }}
{{- end }}
{{- end }}

{{/* Image reference */}}
{{- define "phoenix-liveview.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end }}
