{{/*
The RELATED_IMAGE_<component>_<image> env of the operator for every image the
image override table changes, as a YAML list, or nothing. The operator takes
such an env as the whole reference before it joins base, image and tag from
its image-config (pkg/imageversions/versions.go), the per-image form covering
each OS-specific image of a match rule as well. The defaults are the files
upstream generates image-config from, which `make update` keeps beside the
chart, so the two cannot drift. Called from the vendored deployment, which
patches/image-overrides.diff extends, in the subchart's context: the table is
piraeus.cozystackImageOverrides.
*/}}
{{- define "piraeus-operator.cozystackImageEnv" -}}
{{- $root := . }}
{{- $env := list }}
{{- $seen := dict }}
{{- range $path, $_ := .Files.Glob "cozystack-image-config/*.yaml" }}
{{-   $config := $root.Files.Get $path | fromYaml }}
{{-   range $component, $c := $config.components }}
{{-     $images := list }}
{{-     with $c.image }}
{{-       $images = append $images (dict "image" . "digest" ($c.digest | default "")) }}
{{-     end }}
{{-     range $c.match }}
{{-       $images = append $images (dict "image" .image "digest" (.digest | default "")) }}
{{-     end }}
{{-     range $images }}
{{-       $name := printf "RELATED_IMAGE_%s_%s" $component .image }}
{{-       if not (hasKey $seen $name) }}
{{-         $_ := set $seen $name true }}
{{-         $ref := printf "%s/%s:%s" $config.base .image $c.tag }}
{{-         with .digest }}
{{-           $ref = printf "%s@%s" $ref . }}
{{-         end }}
{{-         $image := include "cozy-lib.image" (list $ref $root) }}
{{-         if ne $image $ref }}
{{-           $env = append $env (dict "name" $name "value" $image) }}
{{-         end }}
{{-       end }}
{{-     end }}
{{-   end }}
{{- end }}
{{- with $env }}
{{-   toYaml . }}
{{- end }}
{{- end }}
