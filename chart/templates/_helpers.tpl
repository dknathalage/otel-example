{{/* Release-derived short backend key (strips the <appName>- prefix, or nameOverride). */}}
{{- define "otel-stack.release" -}}
{{- $p := .Values.nameOverride | default .Values.appName -}}
{{- .Release.Name | trimPrefix (printf "%s-" $p) -}}
{{- end -}}

{{/* Kubernetes ServiceAccount name. Defaults to appName; MUST equal the tofu ksa_name. */}}
{{- define "otel-stack.serviceAccountName" -}}{{ .Values.serviceAccountName | default .Values.appName }}{{- end -}}

{{/* GSA email for the Workload Identity annotation: explicit value, else <ksa>@<project>.iam… */}}
{{- define "otel-stack.gcpServiceAccount" -}}
{{- .Values.gcpServiceAccount | default (printf "%s@%s.iam.gserviceaccount.com" (include "otel-stack.serviceAccountName" .) .Values.gcpProject) -}}
{{- end -}}

{{/* Target namespace: explicit value, else the release namespace. */}}
{{- define "otel-stack.namespace" -}}{{ .Values.namespace | default .Release.Namespace }}{{- end -}}

{{/* Per-release Pub/Sub topic and subscription. */}}
{{- define "otel-stack.topic" -}}orders-{{ include "otel-stack.release" . }}{{- end -}}
{{- define "otel-stack.subscription" -}}orders-{{ include "otel-stack.release" . }}-sub{{- end -}}

{{/* Per-release Postgres database name. */}}
{{- define "otel-stack.pgdb" -}}orders_{{ include "otel-stack.release" . }}{{- end -}}

{{/* Per-release key/collection prefix (used by Redis + Firestore). */}}
{{- define "otel-stack.prefix" -}}{{ include "otel-stack.release" . }}:{{- end -}}

{{/* OTLP collector endpoint shared by every app. */}}
{{- define "otel-stack.otlpEndpoint" -}}http://collector:4318{{- end -}}

{{/* Standard resource attributes for the auto-instrumentation agents. */}}
{{- define "otel-stack.resourceAttributes" -}}service.namespace={{ .Values.appName }},deployment.environment={{ include "otel-stack.release" . }}{{- end -}}

{{/*
Component image reference: <registry>/<repo>:<tag>.
Call with (dict "comp" .Values.components.api "root" .). registry/tag fall back to the
global .Values.image.* unless the component overrides them.
*/}}
{{- define "otel-stack.image" -}}
{{- $reg := .comp.image.registry | default .root.Values.image.registry -}}
{{- $tag := .comp.image.tag | default .root.Values.image.tag -}}
{{- printf "%s/%s:%s" $reg .comp.image.repo (toString $tag) -}}
{{- end -}}

{{/*
GSM confmap reference for the collector. Call with (dict "root" $ "name" "dash0-token").
Emits the literal ${googlesecretmanager:...} token — DO NOT pass the result through tpl.
*/}}
{{- define "otel-stack.secretRef" -}}
${googlesecretmanager:projects/{{ .root.Values.gcpProject }}/secrets/{{ .name }}/versions/latest}
{{- end -}}

{{/* Common labels. */}}
{{- define "otel-stack.labels" -}}
app.kubernetes.io/part-of: {{ .Values.appName }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
otel-stack.io/release: {{ include "otel-stack.release" . }}
otel-stack.io/backend: {{ .Values.backend.type }}
{{- end -}}
