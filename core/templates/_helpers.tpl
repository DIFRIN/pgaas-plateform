{{/*
Cluster name - pre-computed by generate-values.sh
*/}}
{{- define "pgaas.clusterName" -}}
{{- required "clusterName is required" .Values.clusterName -}}
{{- end -}}

{{/*
Namespace
*/}}
{{- define "pgaas.namespace" -}}
{{- required "namespace is required" .Values.namespace -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "pgaas.labels" -}}
app.kubernetes.io/name: pgaas
app.kubernetes.io/instance: {{ include "pgaas.clusterName" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
pgaas.io/ins: {{ .Values.ins }}
pgaas.io/env: {{ .Values.env }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "pgaas.selectorLabels" -}}
app.kubernetes.io/name: pgaas
app.kubernetes.io/instance: {{ include "pgaas.clusterName" . }}
{{- end -}}

{{/*
S3 credentials secret name
*/}}
{{- define "pgaas.s3SecretName" -}}
{{ include "pgaas.clusterName" . }}-s3-creds
{{- end -}}

{{/*
Server certificate name
*/}}
{{- define "pgaas.serverCertName" -}}
{{ include "pgaas.clusterName" . }}-server-tls
{{- end -}}

{{/*
Client certificate name for a given owner
*/}}
{{- define "pgaas.clientCertName" -}}
{{ . }}-client-tls
{{- end -}}

{{/*
ImageCatalog name
*/}}
{{- define "pgaas.imageCatalogName" -}}
{{ .Values.imageCatalog.name }}
{{- end -}}

{{/*
CA secret name (root CA public cert, distributed to namespace)
*/}}
{{- define "pgaas.caSecretName" -}}
pgaas-root-ca
{{- end -}}
