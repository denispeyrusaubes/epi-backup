{{/*
Génère la liste controller.quorum.voters pour KRaft.
Format: 0@pod-0.svc:9093,1@pod-1.svc:9093,2@pod-2.svc:9093
*/}}
{{- define "kafka.quorumVoters" -}}
{{- $releaseName := .Release.Name -}}
{{- $namespace := .Values.namespace -}}
{{- $replicas := int .Values.kafka.replicas -}}
{{- range $i := until $replicas -}}
{{- if gt $i 0 }},{{ end -}}
{{ $i }}@{{ $releaseName }}-kafka-{{ $i }}.{{ $releaseName }}-kafka.{{ $namespace }}.svc.cluster.local:9093
{{- end -}}
{{- end -}}
