{{/*
The env through which virt-operator learns the images it deploys, rendered in
place of the VIRT_OPERATOR_IMAGE entry of the vendored manifest (`make update`
puts the call there). Usage:
{{- include "kubevirt-operator.imageEnv" (list "quay.io/kubevirt/virt-operator:v1.9.0" $) | nindent 8 }}

virt-operator derives the registry, prefix and tag of every component from
VIRT_OPERATOR_IMAGE, a copy of its own image the post-renderer does not see,
unless a component has an env of its own, which it takes as the whole
reference (pkg/virt-operator/util/config.go). So VIRT_OPERATOR_IMAGE goes
through the image override table, and a component gets its env when the table
changes its image, or the operator's: renaming the operator alone would move
every component into the new registry along with it. Without a table nothing
is added, which keeps the install strategy, whose ID covers these images, as
it is.

An operator image with a digest is given as name@digest, the form OLM uses:
the operator then takes the version from KUBEVIRT_VERSION rather than from a
tag carrying the digest.
*/}}
{{- define "kubevirt-operator.imageEnv" -}}
{{- $upstream := index . 0 }}
{{- $root := index . 1 }}
{{- $operator := include "cozy-lib.image" (list $upstream $root) }}
{{- $operatorParts := include "cozy-lib.imageOverrides.split" $operator | fromYaml }}
{{- $operatorEnv := $operator }}
{{- with $operatorParts.digest }}
{{-   $operatorEnv = printf "%s@%s" $operatorParts.name . }}
{{- end }}
{{- $env := list (dict "name" "VIRT_OPERATOR_IMAGE" "value" $operatorEnv) }}
{{- $upstreamParts := include "cozy-lib.imageOverrides.split" $upstream | fromYaml }}
{{- $base := trimSuffix "virt-operator" $upstreamParts.name }}
{{- $components := list
      (list "VIRT_API_IMAGE" "virt-api")
      (list "VIRT_CONTROLLER_IMAGE" "virt-controller")
      (list "VIRT_HANDLER_IMAGE" "virt-handler")
      (list "VIRT_LAUNCHER_IMAGE" "virt-launcher")
      (list "VIRT_EXPORTPROXY_IMAGE" "virt-exportproxy")
      (list "VIRT_EXPORTSERVER_IMAGE" "virt-exportserver")
      (list "VIRT_SYNCHRONIZATIONCONTROLLER_IMAGE" "virt-synchronization-controller")
      (list "PR_HELPER_IMAGE" "pr-helper")
      (list "SIDECAR_SHIM_IMAGE" "sidecar-shim")
      (list "GS_IMAGE" "libguestfs-tools") }}
{{- range $components }}
{{-   $ref := printf "%s%s:%s" $base (index . 1) $upstreamParts.tag }}
{{-   $image := include "cozy-lib.image" (list $ref $root) }}
{{-   if or (ne $image $ref) (ne $operator $upstream) }}
{{-     $env = append $env (dict "name" (index . 0) "value" $image) }}
{{-   end }}
{{- end }}
{{- toYaml $env }}
{{- end }}
