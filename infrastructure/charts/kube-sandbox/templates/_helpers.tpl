{{/*
Expand the name of the chart.
*/}}
{{- define "kube-sandbox.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to
this (DNS-1123 subdomain). When the release name is "apps" and chart name
is "kube-sandbox", this becomes "apps-kube-sandbox" — and the Service for
the auth app becomes "apps-kube-sandbox-auth".
*/}}
{{- define "kube-sandbox.fullname" -}}
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

{{/*
App-scoped fullname: <release>-<chart>-<app>
Examples:
  .Values.apps.auth.enabled  -> apps-kube-sandbox-auth
  .Values.apps.frontend -> apps-kube-sandbox-frontend
*/}}
{{- define "kube-sandbox.appFullname" -}}
{{- $ctx := .ctx -}}
{{- $appName := .appName -}}
{{- printf "%s-%s" ($ctx | include "kube-sandbox.fullname") $appName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Chart label.
*/}}
{{- define "kube-sandbox.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every resource.
These are what ArgoCD, Grafana, and `kubectl get -L` see. Don't change them
without also updating dashboards.
*/}}
{{- define "kube-sandbox.labels" -}}
helm.sh/chart: {{ include "kube-sandbox.chart" . }}
{{ include "kube-sandbox.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kube-sandbox
{{- end -}}

{{/*
Selector labels — stable across reloads, used in selector.matchLabels.
NEVER add a templated value here; selectors are immutable.
`part-of` lives only in `labels` (above) — selectors stay minimal.
The per-app `appSelectorLabels` overrides `component` with the app name.
*/}}
{{- define "kube-sandbox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kube-sandbox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Per-app selector — pairs with the Deployment `selector.matchLabels`.
`app.kubernetes.io/component` is what `kubectl get pods -l ...` filters on.
*/}}
{{- define "kube-sandbox.appSelectorLabels" -}}
{{- $ctx := .ctx -}}
{{- $appName := .appName -}}
{{ include "kube-sandbox.selectorLabels" $ctx }}
app.kubernetes.io/component: {{ $appName }}
{{- end -}}

{{/*
Cluster-internal DNS name for an app's Service.
Example: apps-kube-sandbox-auth.apps.svc.cluster.local
Use this when one pod needs to call another (frontend → auth-service).
*/}}
{{- define "kube-sandbox.serviceDNS" -}}
{{- $ctx := .ctx -}}
{{- $appName := .appName -}}
{{- $ns := $ctx.Release.Namespace -}}
{{- $fullname := include "kube-sandbox.appFullname" (dict "ctx" $ctx "appName" $appName) -}}
{{- printf "%s.%s.svc.cluster.local" $fullname $ns -}}
{{- end -}}

{{/*
Service URL (http://fullname.ns.svc.cluster.local:port) for env vars.
*/}}
{{- define "kube-sandbox.serviceURL" -}}
{{- $ctx := .ctx -}}
{{- $appName := .appName -}}
{{- $port := .port -}}
{{- $dns := include "kube-sandbox.serviceDNS" (dict "ctx" $ctx "appName" $appName) -}}
{{- printf "http://%s:%v" $dns $port -}}
{{- end -}}

{{/*
Image reference: ghcr.io/minhajul/auth-service:<tag>
Falls back to `:<tag>` (no registry) if .Values.registry is empty,
useful for `helm template` smoke tests.
*/}}
{{- define "kube-sandbox.image" -}}
{{- $ctx := .ctx -}}
{{- $appName := .appName -}}
{{- $app := index $ctx.Values.apps $appName -}}
{{- $repo := $app.image.repository -}}
{{- $tag := $app.image.tag | default $ctx.Chart.AppVersion -}}
{{- if $ctx.Values.registry -}}
{{- printf "%s/%s/%s:%s" $ctx.Values.registry $ctx.Values.org $repo $tag -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end -}}
