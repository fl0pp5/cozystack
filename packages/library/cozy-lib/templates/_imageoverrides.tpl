{{/*
Render the postRenderers field of a HelmRelease a chart emits, carrying the
platform's image override table (_cluster.image-overrides) as a kustomize
images post-renderer.

Registry mirrors on the nodes serve an image only under the name it was pinned
with; an override can also rename it, retag it and repin its digest. The
releases cozystack-operator and cozystack-api build get the same renderer in
Go (pkg/imageoverrides). A HelmRelease rendered by a chart is built by nobody
else, so every chart that emits one must call this helper, or the images that
release installs keep their upstream names. hack/helmrelease-postrenderers_test.bats
holds every HelmRelease template in the tree to that.

An entry's match, which narrows it to one version of the image, is folded into
the name as name:tag or name@digest, the way pkg/imageoverrides.Compile does:
kustomize matches the name as the reference up to the tag and digest it does
not name.

The first argument is the release's own post-renderers (a list, possibly
empty); they are kept ahead of the override renderer, so that it rewrites what
they render. Nothing is rendered when there are neither own post-renderers nor
overrides.

Usage, inside the HelmRelease spec:
  {{- include "cozy-lib.postRenderers" (list (list) $) | nindent 2 }}
*/}}
{{- define "cozy-lib.postRenderers" -}}
{{-   include "cozy-lib.checkInput" . }}
{{-   $own := index . 0 | default list }}
{{-   if not (kindIs "slice" $own) }}
{{-     fail (printf "cozy-lib.postRenderers: own post-renderers must be a list, got %s" (kindOf $own)) }}
{{-   end }}
{{-   $ctx := index . 1 }}
{{-   $overrides := index ($ctx.Values._cluster | default dict) "image-overrides" | default list }}
{{-   $all := $own }}
{{-   $images := list }}
{{-   range $overrides }}
{{-     $image := omit . "match" }}
{{-     with .match }}
{{-       $_ := set $image "name" (ternary (printf "%s:%s" $image.name .tag) (printf "%s@%s" $image.name .digest) (not (empty .tag))) }}
{{-     end }}
{{-     $images = append $images $image }}
{{-   end }}
{{-   if $images }}
{{-     $all = append $own (dict "kustomize" (dict "images" $images)) }}
{{-   end }}
{{-   with $all }}
postRenderers:
{{ toYaml . }}
{{-   end }}
{{- end }}
