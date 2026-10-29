{{/*
The PostgreSQL image of a CloudNativePG Cluster a chart keeps across upgrades,
as YAML: image is the reference for spec.imageName, major the value of the
postgres.cozystack.io/major annotation, empty when the tag shows the major
version itself.

Usage: {{ include "cozy-lib.cnpg.image" (list $existingCluster "<chart image>" $) | fromYaml }}

A cluster on the major version of the chart image, or no cluster yet, runs the
chart image through cozy-lib.image, so a chart upgrade moves it to the new
minor release and the image override table applies. A cluster on another
major version keeps its image: CloudNativePG does not change a major version
in place. That image only gains the -standard-trixie suffix the old images
lacked, and the table.

The major version is read from the annotation before the tag, because the
table can give the image a tag that does not show it; without the annotation
such a cluster would look like another major version and stay on its image
through every chart upgrade.
*/}}
{{- define "cozy-lib.cnpg.image" -}}
{{- $cluster := index . 0 | default dict }}
{{- $chartImage := index . 1 }}
{{- $ctx := index . 2 }}
{{- $chartMajor := include "cozy-lib.cnpg.majorOf" $chartImage }}
{{- $live := dig "spec" "imageName" "" $cluster }}
{{- $major := dig "metadata" "annotations" "postgres.cozystack.io/major" "" $cluster | toString }}
{{- if and $live (not $major) }}
{{-   $major = include "cozy-lib.cnpg.majorOf" $live }}
{{- end }}
{{- $image := "" }}
{{- if or (not $live) (eq $major $chartMajor) }}
{{-   $image = include "cozy-lib.image" (list $chartImage $ctx) }}
{{-   $major = $chartMajor }}
{{- else }}
{{-   $image = $live }}
{{-   if regexMatch ":[0-9]+\\.[0-9]+$" $image }}
{{-     $image = printf "%s-standard-trixie" $image }}
{{-   end }}
{{-   $image = include "cozy-lib.imageWith" (list $image (include "cozy-lib.imageOverrides.table" $ctx | fromYaml).table) }}
{{- end }}
{{- if eq (include "cozy-lib.cnpg.majorOf" $image) $major }}
{{-   $major = "" }}
{{- end }}
{{- dict "image" $image "major" $major | toYaml }}
{{- end }}

{{/*
The major version a PostgreSQL image tag starts with ("17" for
17.7-standard-trixie), or nothing.
*/}}
{{- define "cozy-lib.cnpg.majorOf" -}}
{{- $tag := (include "cozy-lib.imageOverrides.split" . | fromYaml).tag | default "" }}
{{- if regexMatch "^[0-9]+\\." $tag }}
{{-   regexFind "^[0-9]+" $tag }}
{{- end }}
{{- end }}
