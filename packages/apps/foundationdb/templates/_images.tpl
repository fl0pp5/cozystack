{{/*
The imageConfigs entry for one image the operator picks itself, as a YAML
list: empty when cozy-lib.image leaves <base>:<tag> as it is, so that without
an image override table the operator keeps choosing, otherwise the entry for
that version alone. The operator joins baseImage and tag with ':', which
carries tag@digest but cannot express a digest without a tag.
Usage: {{ include "foundationdb.imageConfigs" (list "foundationdb/foundationdb" "7.3.63" "7.3.63" $) | fromYamlArray }}
*/}}
{{- define "foundationdb.imageConfigs" -}}
{{- $base := index . 0 }}
{{- $version := index . 1 }}
{{- $tag := index . 2 }}
{{- $root := index . 3 }}
{{- $ref := printf "%s:%s" $base $tag }}
{{- $image := include "cozy-lib.image" (list $ref $root) }}
{{- if ne $image $ref }}
{{-   $parts := include "cozy-lib.imageOverrides.split" $image | fromYaml }}
{{-   if not $parts.tag }}
{{-     printf "the image override table turns %s into %s, which has no tag; the FoundationDB operator builds the image as baseImage:tag and cannot run it. Give the entry a newTag beside its digest." $ref $image | fail }}
{{-   end }}
{{-   $imageTag := $parts.tag }}
{{-   with $parts.digest }}
{{-     $imageTag = printf "%s@%s" $imageTag . }}
{{-   end }}
{{-   if gt (len $imageTag) 100 }}
{{-     printf "the image override table turns %s into %s, whose tag the FoundationDB operator stores in a field of at most 100 characters; %q is %d. Use a shorter newTag." $ref $image $imageTag (len $imageTag) | fail }}
{{-   end }}
{{-   list (dict "version" $version "baseImage" $parts.name "tag" $imageTag) | toYaml }}
{{- else }}
{{-   list | toYaml }}
{{- end }}
{{- end }}
