{{/*
Rewrites, in a copy of the gpu-operator values, every repository/image/version
triple the image override table changes, and leaves the rest alone. The
ClusterPolicy and NVIDIADriver templates read those triples, and the operator
starts each component from the reference it builds out of them
(api/nvidia/v1 imagePath), out of the post-renderer's reach.
patches/image-overrides.diff renders those two templates with the copy:

  {{- $values := deepCopy .Values }}
  {{- include "gpu-operator.cozystackImageValues" (list $values .) }}
  {{- with dict "Values" $values "Chart" .Chart ... -}}

A changed reference goes back as a triple: the operator joins
repository/image:version, or repository/image@version for a version starting
with sha256:, so a result that has both keeps the digest, which pins the same
image. For the driver images the operator appends the node's OS to a tag but
not to a digest, as it does without a table. Called in the subchart's
context: the table is gpu-operator.cozystackImageOverrides.
*/}}
{{- define "gpu-operator.cozystackImageValues" -}}
{{- include "gpu-operator.cozystackImageValues.walk" (list (index . 0) (index . 1) 0) }}
{{- end }}

{{- define "gpu-operator.cozystackImageValues.walk" -}}
{{- $node := index . 0 }}
{{- $root := index . 1 }}
{{- $depth := index . 2 }}
{{- if and (kindIs "map" $node) (lt $depth 3) }}
{{- /* validator and nodeStatusExporter carry no version, and the
         ClusterPolicy template defaults it to the chart's appVersion. */}}
{{-   if and (kindIs "string" (get $node "repository")) (get $node "repository") (kindIs "string" (get $node "image")) (get $node "image") }}
{{-     $version := get $node "version" | default $root.Chart.AppVersion | toString }}
{{-     $ref := printf "%s/%s%s%s" $node.repository $node.image (ternary "@" ":" (hasPrefix "sha256:" $version)) $version }}
{{-     $image := include "cozy-lib.image" (list $ref $root) }}
{{-     if ne $image $ref }}
{{-       $parts := include "cozy-lib.imageOverrides.split" $image | fromYaml }}
{{-       $_ := set $node "repository" (regexReplaceAll "/[^/]*$" $parts.name "") }}
{{-       $_ := set $node "image" (regexFind "[^/]*$" $parts.name) }}
{{-       $_ := set $node "version" ($parts.digest | default $parts.tag) }}
{{-     end }}
{{-   end }}
{{-   range $key, $child := $node }}
{{-     include "gpu-operator.cozystackImageValues.walk" (list $child $root (add1 $depth)) }}
{{-   end }}
{{- end }}
{{- end }}
