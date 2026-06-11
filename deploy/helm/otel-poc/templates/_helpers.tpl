{{/* Release-derived short name (strips the otel-poc- prefix). */}}
{{- define "otel-poc.release" -}}{{ .Release.Name | trimPrefix "otel-poc-" }}{{- end -}}

{{/* Per-release Pub/Sub topic and subscription. */}}
{{- define "otel-poc.topic" -}}orders-{{ include "otel-poc.release" . }}{{- end -}}
{{- define "otel-poc.subscription" -}}orders-{{ include "otel-poc.release" . }}-sub{{- end -}}

{{/* Per-release Postgres database name. */}}
{{- define "otel-poc.pgdb" -}}orders_{{ include "otel-poc.release" . }}{{- end -}}

{{/* Per-release key/collection prefix (used by Redis + Firestore). */}}
{{- define "otel-poc.prefix" -}}{{ include "otel-poc.release" . }}:{{- end -}}

{{/* OTLP collector endpoint shared by every app. */}}
{{- define "otel-poc.otlpEndpoint" -}}http://collector:4318{{- end -}}

{{/* Standard resource attributes for the auto-instrumentation agents. */}}
{{- define "otel-poc.resourceAttributes" -}}service.namespace=otel-poc,deployment.environment={{ include "otel-poc.release" . }}{{- end -}}

{{/* Common labels. */}}
{{- define "otel-poc.labels" -}}
app.kubernetes.io/part-of: otel-poc
app.kubernetes.io/managed-by: {{ .Release.Service }}
otel-poc.io/release: {{ include "otel-poc.release" . }}
otel-poc.io/provider: {{ .Values.provider }}
{{- end -}}
