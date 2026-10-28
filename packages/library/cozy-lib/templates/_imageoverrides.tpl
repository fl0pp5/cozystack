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

{{/*
The image override table as a chart sees it, as YAML under the key "table".
Our charts read it from _cluster.image-overrides. A vendored subchart does not
see _cluster, so a chart that patches one (route 3) gets the table from the
platform under its own key, cozystackImageOverrides; it never goes into global,
which every chart reads and some act on whenever it is non-empty.
*/}}
{{- define "cozy-lib.imageOverrides.table" -}}
{{- $table := index (.Values._cluster | default dict) "image-overrides" }}
{{- if not $table }}
{{-   $table = .Values.cozystackImageOverrides }}
{{- end }}
{{- dict "table" ($table | default list) | toYaml }}
{{- end }}

{{/*
A reference split into name, tag and digest as YAML, the way
sigs.k8s.io/kustomize/api/internal/image.Split does it: the first path
component may be a host with a port, so ':' and '@' are only looked for after
it.
*/}}
{{- define "cozy-lib.imageOverrides.split" -}}
{{- $host := "" }}
{{- $rest := . }}
{{- if regexMatch "^[^/]+/" . }}
{{-   $host = regexFind "^[^/]+" . }}
{{-   $rest = trimPrefix $host . }}
{{- end }}
{{- $name := . }}
{{- $tag := "" }}
{{- $digest := "" }}
{{- if regexMatch "^[^@:]*@" $rest }}
{{-   $name = printf "%s%s" $host (regexReplaceAll "@.*$" $rest "") }}
{{-   $digest = regexReplaceAll "^[^@]*@" $rest "" }}
{{- else if contains ":" $rest }}
{{-   $name = printf "%s%s" $host (regexReplaceAll ":.*$" $rest "") }}
{{-   $tag = regexReplaceAll "^[^:]*:" $rest "" }}
{{-   if contains "@" $tag }}
{{-     $digest = regexReplaceAll "^[^@]*@" $tag "" }}
{{-     $tag = regexReplaceAll "@.*$" $tag "" }}
{{-   end }}
{{- end }}
{{- dict "name" $name "tag" $tag "digest" $digest | toYaml }}
{{- end }}

{{/*
Apply an image override table to one reference, as the kustomize images
post-renderer does to a container image: entries in order, each against the
result of the ones before it, an entry's match folded into the name kustomize
selects by. pkg/imageoverrides.Apply implements the same rules, and both are
held to pkg/imageoverrides/testdata/parity.yaml.

Charts read the table from their values through cozy-lib.image; this form takes
it as an argument, for a patched vendored template whose context is not the
chart's own.
Usage: {{ include "cozy-lib.imageWith" (list "quay.io/org/app:v1" $table) }}
*/}}
{{- define "cozy-lib.imageWith" -}}
{{- $ref := index . 0 }}
{{- range (index . 1 | default list) }}
{{-   $selector := .name }}
{{-   with .match }}
{{-     $selector = ternary (printf "%s:%s" $selector .tag) (printf "%s@%s" $selector .digest) (not (empty .tag)) }}
{{-   end }}
{{-   if regexMatch (printf "^%s(:[a-zA-Z0-9_.{}-]*)?(@sha256:[a-zA-Z0-9_.{}-]*)?$" $selector) $ref }}
{{-     $parts := include "cozy-lib.imageOverrides.split" $ref | fromYaml }}
{{-     $name := .newName | default $parts.name }}
{{-     $tag := $parts.tag }}
{{-     $digest := $parts.digest }}
{{-     if and .newTag .digest }}
{{-       $tag = .newTag }}
{{-       $digest = .digest }}
{{-     else if .newTag }}
{{-       $tag = .newTag }}
{{-       $digest = "" }}
{{-     else if .digest }}
{{-       $tag = "" }}
{{-       $digest = .digest }}
{{-     end }}
{{-     $ref = $name }}
{{-     with $tag }}
{{-       $ref = printf "%s:%s" $ref . }}
{{-     end }}
{{-     with $digest }}
{{-       $ref = printf "%s@%s" $ref . }}
{{-     end }}
{{-   end }}
{{- end }}
{{- $ref }}
{{- end }}

{{/*
cozy-lib.image split into the parts a custom resource field or a chart value
takes, as YAML: registry (empty when the first path component is not a host,
as for docker.io short names), repository, tag and digest.
Usage: {{ $image := include "cozy-lib.imageParts" (list "quay.io/org/app:v1" $) | fromYaml }}
*/}}
{{- define "cozy-lib.imageParts" -}}
{{- $parts := include "cozy-lib.imageOverrides.split" (include "cozy-lib.image" .) | fromYaml }}
{{- $registry := "" }}
{{- $repository := $parts.name }}
{{- if regexMatch "^([^/]*[.:][^/]*|localhost)/" $parts.name }}
{{-   $registry = regexFind "^[^/]+" $parts.name }}
{{-   $repository = trimPrefix (printf "%s/" $registry) $parts.name }}
{{- end }}
{{- dict "registry" $registry "repository" $repository "tag" $parts.tag "digest" $parts.digest | toYaml }}
{{- end }}

{{/*
The name cozy-lib.image gives an image, without tag or digest, for a field that
takes a repository and adds the tag itself. Only entries without match reach a
name with no version, and only their newName shows here.
Usage: {{ include "cozy-lib.imageName" (list "quay.io/coreos/etcd" $) }}
*/}}
{{- define "cozy-lib.imageName" -}}
{{- (include "cozy-lib.imageOverrides.split" (include "cozy-lib.image" .) | fromYaml).name }}
{{- end }}

{{/*
What the entries without match do to an image whose tag the caller does not
know, as the YAML fields of a kustomize images entry: newName, newTag, digest,
and dropTag when the result keeps no tag. The platform chart passes this to a
vendored chart that takes an image in parts and keeps its own default for the
parts left unset (route 2); entries with match need the tag and cannot apply.
Usage: {{ include "cozy-lib.imageOverrideEntry" (list "quay.io/jetstack/cert-manager-acmesolver" $table) | fromYaml }}
*/}}
{{- define "cozy-lib.imageOverrideEntry" -}}
{{- $name := index . 0 }}
{{- /* A tag no table selects stands in for the unknown one. */}}
{{- $unknown := "cozy-lib-unknown-tag" }}
{{- $table := list }}
{{- range (index . 1 | default list) }}
{{-   if not .match }}
{{-     $table = append $table . }}
{{-   end }}
{{- end }}
{{- $parts := include "cozy-lib.imageOverrides.split" (include "cozy-lib.imageWith" (list (printf "%s:%s" $name $unknown) $table)) | fromYaml }}
{{- $entry := dict }}
{{- if ne $parts.name $name }}
{{-   $_ := set $entry "newName" $parts.name }}
{{- end }}
{{- if and $parts.tag (ne $parts.tag $unknown) }}
{{-   $_ := set $entry "newTag" $parts.tag }}
{{- end }}
{{- with $parts.digest }}
{{-   $_ := set $entry "digest" . }}
{{- end }}
{{- if not $parts.tag }}
{{-   $_ := set $entry "dropTag" true }}
{{- end }}
{{- toYaml $entry }}
{{- end }}
