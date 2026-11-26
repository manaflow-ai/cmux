{{- define "cmux-agent-host.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cmux-agent-host.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "cmux-agent-host.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "cmux-agent-host.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "cmux-agent-host.agentSelector" -}}
app.kubernetes.io/name: {{ include "cmux-agent-host.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: host-agent
{{- end -}}

{{/* The labels every slot pod and PVC carries; the agent adds cmux.dev/slot=<uuid> per slot. */}}
{{- define "cmux-agent-host.slotSelector" -}}
app.kubernetes.io/name: {{ include "cmux-agent-host.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: agent-slot
{{- end -}}

{{- define "cmux-agent-host.serviceAccountName" -}}
{{- default (include "cmux-agent-host.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{- define "cmux-agent-host.hostCredentialSecret" -}}
{{- default (printf "%s-host-credential" (include "cmux-agent-host.fullname" .)) .Values.hostCredential.secretName -}}
{{- end -}}

{{- define "cmux-agent-host.joinSecret" -}}
{{- if .Values.join.existingSecret -}}
{{- .Values.join.existingSecret -}}
{{- else -}}
{{- printf "%s-join" (include "cmux-agent-host.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "cmux-agent-host.image" -}}
{{- $repo := required "image.repository is required: the acpmux container image" .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (required "image.tag or image.digest is required" .Values.image.tag) -}}
{{- end -}}
{{- end -}}

{{- define "cmux-agent-host.vmBoundary" -}}
{{- $v := toString .Values.slot.vmBoundary -}}
{{- if eq $v "auto" -}}
{{- ternary "true" "false" (ne .Values.slot.runtimeClassName "") -}}
{{- else if or (eq $v "true") (eq $v "false") -}}
{{- $v -}}
{{- else -}}
{{- fail "slot.vmBoundary must be auto, true or false" -}}
{{- end -}}
{{- end -}}
