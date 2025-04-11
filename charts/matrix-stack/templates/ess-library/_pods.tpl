{{- /*
Copyright 2024 New Vector Ltd

SPDX-License-Identifier: AGPL-3.0-only
*/ -}}

{{- define "element-io.ess-library.pods.commonSpec" -}}
{{- $root := .root -}}
{{- with required "element-io.ess-library.pods.commonSpec missing context" .context -}}
{{- $key := required "element-io.ess-library.pods.commonSpec missing context.key" .key -}}
{{- $usesMatrixTools := .usesMatrixTools | default false -}}
{{- $mountServiceAccountToken := .mountServiceAccountToken | default false -}}
{{- $deployment := required "element-io.ess-library.pods.commonSpec missing context.deployment" .deployment -}}
{{- with required "element-io.ess-library.pods.commonSpec missing context.componentValues" .componentValues -}}
automountServiceAccountToken: {{ $mountServiceAccountToken }}
serviceAccountName: {{ include "element-io.ess-library.serviceAccountName" (dict "root" $root "context" (dict "serviceAccount" .serviceAccount "key" $key)) }}
{{- include "element-io.ess-library.pods.pullSecrets" (dict "root" $root "context" (dict "pullSecrets" ((.image).pullSecrets | default list) "usesMatrixTools" $usesMatrixTools)) }}
{{- with .podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- include "element-io.ess-library.pods.tolerations" (dict "root" $root "context" .tolerations) }}
{{- include "element-io.ess-library.pods.topologySpreadConstraints" (dict "root" $root "context" (dict "instanceSuffix" $key "deployment" $deployment "topologySpreadConstraints" .topologySpreadConstraints)) }}
{{- end }}
{{- end }}
{{- end }}

{{- define "element-io.ess-library.pods.pullSecrets" -}}
{{- $root := .root -}}
{{- with required "element-io.ess-library.pods.pullSecrets missing context" .context -}}
{{- $pullSecrets := list }}
{{- $pullSecrets = concat .pullSecrets $root.Values.imagePullSecrets }}
{{- if .usesMatrixTools -}}
{{- $pullSecrets = concat $pullSecrets $root.Values.matrixTools.image.pullSecrets }}
{{- end }}
{{- with ($pullSecrets | uniq) }}
imagePullSecrets:
{{ tpl (toYaml .) $root }}
{{- end }}
{{- end }}
{{- end }}

{{- define "element-io.ess-library.pods.tolerations" -}}
{{- $root := .root -}}
{{- if not (hasKey . "context") -}}
{{- fail "element-io.ess-library.pods.tolerations missing context" -}}
{{- end }}
{{- $tolerations := concat .context $root.Values.tolerations }}
{{- with ($tolerations | uniq) }}
tolerations:
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "element-io.ess-library.pods.topologySpreadConstraints" -}}
{{- $root := .root -}}
{{- with required "element-io.ess-library.pods.topologySpreadConstraints missing context" .context -}}
{{- $labelSelector := (dict "matchLabels" (dict "app.kubernetes.io/instance" (printf "%s-%s" $root.Release.Name .instanceSuffix))) }}
{{- $matchLabelKeys := .deployment | ternary (list "pod-template-hash") list }}
{{- $defaultConstraintSettings := dict "labelSelector" $labelSelector "matchLabelKeys" $matchLabelKeys "whenUnsatisfiable" "DoNotSchedule" }}
{{- $topologySpreadConstraints := list -}}
{{- range $constraint := coalesce .topologySpreadConstraints $root.Values.topologySpreadConstraints -}}
{{- $constraintWithDefault := (mergeOverwrite (deepCopy $defaultConstraintSettings) $constraint) -}}
{{- $defaultMatchLabels := $constraintWithDefault.labelSelector.matchLabels | deepCopy -}}
{{- range $key, $value := $constraintWithDefault.labelSelector.matchLabels -}}
{{- if eq $value nil -}}
{{- $defaultMatchLabels = (omit $defaultMatchLabels $key) -}}
{{- end -}}
{{- end -}}
{{- $_ := set $constraintWithDefault.labelSelector "matchLabels" $defaultMatchLabels -}}
{{- $topologySpreadConstraints = append $topologySpreadConstraints $constraintWithDefault -}}
{{- end }}
{{- with $topologySpreadConstraints }}
topologySpreadConstraints:
{{ toYaml . }}
{{- end }}
{{- end }}
{{- end }}
