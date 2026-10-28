{{- define "cozystack.platform.package" -}}
{{- $name := index . 0 -}}
{{- $variant := default "default" (index . 1) -}}
{{- $root := default $ (index . 2) -}}
{{- $components := dict -}}
{{- if gt (len .) 3 -}}
{{- $components = index . 3 -}}
{{- end -}}
{{- $disabled := default (list) $root.Values.bundles.disabledPackages -}}
{{- if not (has $name $disabled) -}}
{{- if eq $name "cozystack.networking" -}}
{{- include "cozystack.platform.networking.variantGuard" (list $root $variant) -}}
{{- end }}
---
apiVersion: cozystack.io/v1alpha1
kind: Package
metadata:
  name: {{ $name }}
  annotations:
    helm.sh/resource-policy: keep
spec:
  variant: {{ $variant }}
{{- if $components }}
  components:
{{ toYaml $components | indent 4 }}
{{- end }}
{{- end }}
{{ end }}

{{/*
Refuses to change the variant of a live cozystack.networking Package. The
operator deletes every HelmRelease of a Package that its new variant does not
install, so isp-full -> isp-hosted removes cilium and kubeovn and leaves the
cluster without a CNI. The acknowledgement names the target variant rather than
being a boolean, so a value left set after one switch does not cover the next.
Inert where lookup returns nothing: helm template, client-side dry-run, first
install.
Call as (list $ <variant about to be rendered>).
*/}}
{{- define "cozystack.platform.networking.variantGuard" -}}
{{- $root := index . 0 -}}
{{- $variant := index . 1 -}}
{{- $live := lookup "cozystack.io/v1alpha1" "Package" "" "cozystack.networking" -}}
{{- if $live -}}
{{- $liveVariant := default "default" (dig "spec" "variant" "" $live) -}}
{{- $ack := dig "acknowledgeVariantChange" "" ($root.Values.networking | default dict) | toString -}}
{{- if and (ne $liveVariant $variant) (ne $ack $variant) -}}
{{- fail (printf "the live cozystack.networking Package runs variant %q and this render would switch it to %q (bundles.system.variant: %s). The operator then deletes any HelmRelease of that Package the new variant does not install (none if it installs everything the current one does): isp-full to isp-hosted removes Cilium and Kube-OVN and leaves every pod without networking, isp-full to isp-slim removes Kube-OVN. Either restore the previous spec.variant of the cozystack.cozystack-platform Package, or, once the cluster has another CNI or no longer needs the removed one, set networking.acknowledgeVariantChange: %q in its spec.components.platform.values to confirm this exact switch. If the live variant was set by hand and has to stay, add cozystack.networking to bundles.disabledPackages: acknowledging lets this render replace it." $liveVariant $variant $root.Values.bundles.system.variant $variant) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "cozystack.platform.package.default" -}}
{{- $name := index . 0 -}}
{{- $root := index . 1 -}}
{{- include "cozystack.platform.package" (list $name "default" $root) }}
{{ end }}

{{- define "cozystack.platform.package.optional" -}}
{{- $name := index . 0 -}}
{{- $variant := default "default" (index . 1) -}}
{{- $root := default $ (index . 2) -}}
{{- /* Components are accepted here for the same reason the always-on helper
       above accepts them: an opt-in package can need platform configuration
       just as much as a default one. Omitting this silently dropped whatever
       the caller passed, which is worse than not supporting it at all. */ -}}
{{- $components := dict -}}
{{- if gt (len .) 3 -}}
{{- $components = index . 3 -}}
{{- end -}}
{{- $disabled := default (list) $root.Values.bundles.disabledPackages -}}
{{- $enabled := default (list) $root.Values.bundles.enabledPackages -}}
{{- if and (has $name $enabled) (not (has $name $disabled)) -}}
---
apiVersion: cozystack.io/v1alpha1
kind: Package
metadata:
  name: {{ $name }}
  annotations:
    helm.sh/resource-policy: keep
spec:
  variant: {{ $variant }}
{{- if $components }}
  components:
{{ toYaml $components | indent 4 }}
{{- end }}
{{- end }}
{{ end }}

{{- define "cozystack.platform.package.optional.default" -}}
{{- $name := index . 0 -}}
{{- $root := index . 1 -}}
{{- $components := dict -}}
{{- if gt (len .) 2 -}}
{{- $components = index . 2 -}}
{{- end -}}
{{- include "cozystack.platform.package.optional" (list $name "default" $root $components) }}
{{ end }}

{{/*
Emits "true" on the slim variants, empty otherwise.
*/}}
{{- define "cozystack.platform.slim" -}}
{{- if has .Values.bundles.system.variant (list "isp-slim" "isp-slim-generic" "isp-hosted-slim") }}true{{ end -}}
{{- end }}

{{/*
A package that is always on in the full variants and opt-in (bundles.enabledPackages)
on the slim ones. Takes the same arguments as cozystack.platform.package.
*/}}
{{- define "cozystack.platform.package.full" -}}
{{- if include "cozystack.platform.slim" (index . 2) -}}
{{- include "cozystack.platform.package.optional" . }}
{{- else -}}
{{- include "cozystack.platform.package" . }}
{{- end -}}
{{ end }}

{{/*
Emits the cozystack.networking Package. Call as
(list $ <components> <full variant> <slim variant>). The slim variants run Cilium
alone: no KubeOVN component, and Cilium L2 announcements stand in for MetalLB.
*/}}
{{- define "cozystack.platform.package.networking" -}}
{{- $root := index . 0 -}}
{{- $components := index . 1 -}}
{{- $variant := index . 2 -}}
{{- if include "cozystack.platform.slim" $root -}}
{{- if dig "encryption" "enabled" false ($root.Values.networking | default dict) -}}
{{- fail "networking.encryption.enabled is not supported on the slim variants: their Cilium-only datapath has no encryption wiring yet" -}}
{{- end -}}
{{- $variant = index . 3 -}}
{{- $_ := unset $components "kubeovn" -}}
{{- $cilium := dig "cilium" "values" "cilium" dict $components -}}
{{- $_ := set $cilium "l2announcements" (dict "enabled" true) -}}
{{- $_ := set $components "cilium" (dict "values" (dict "cilium" $cilium)) -}}
{{- end -}}
{{- include "cozystack.platform.package" (list "cozystack.networking" $variant $root $components) }}
{{- end }}

{{- define "cozystack.platform.package.full.default" -}}
{{- include "cozystack.platform.package.full" (list (index . 0) "default" (index . 1)) }}
{{ end }}

{{/*
Resolve networking.stageCniPlugins for a bundle, given that bundle's default.
Call as (list $ <default-bool>); emits the string "true" or "false".

Two things this exists for, both of which a bare `dig` gets wrong.

`dig` returns its default only when the key is ABSENT. A key present with a nil
value returns nil, and nil is how an operator clears an inherited override --
deleting `stageCniPlugins: true` from spec.components.platform.values by setting
it to null. A bare dig would hand that straight through as nil, the chart would
read it as off, and a generic-Linux cluster would silently go back to failing
bridge-type NADs while values.yaml documents the default as on. Nil is therefore
folded back onto the variant default, which is what "unset" means to a reader.

And the value can arrive as a string. Today a values file does not produce one
for a boolean spelling -- measured on Helm v4: yes/no/on/off and true/false all
resolve to booleans, YAML 1.1 style -- but --set-string does, and that "today"
is why the spellings are normalised rather than relied on: which of them the
parser folds is a property of whichever YAML library Helm links, not of this
chart. A parser that stopped folding yes/no would hand this template the string
instead, and normalising costs nothing either way. Since this key is how an
operator declines a behaviour change, a spelling the template does not
understand must not quietly mean the opposite of what was written: anything
unrecognised stops the render.
*/}}
{{- define "cozystack.platform.stageCniPlugins" -}}
{{- $root := index . 0 -}}
{{- $default := index . 1 -}}
{{- $value := dig "stageCniPlugins" nil ($root.Values.networking | default dict) -}}
{{- if kindIs "invalid" $value -}}
{{- $default | toString -}}
{{- else -}}
{{- $spelling := $value | toString | lower -}}
{{- if or (eq $spelling "true") (eq $spelling "yes") (eq $spelling "on") (eq $spelling "1") -}}
true
{{- else if or (eq $spelling "false") (eq $spelling "no") (eq $spelling "off") (eq $spelling "0") -}}
false
{{- else -}}
{{- fail (printf "networking.stageCniPlugins: expected a boolean, got %q -- leaving it unset follows the bundle variant" ($value | toString)) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Values of the cozystack.multus Package. Call as (list $ <stageCniPlugins default>);
emits YAML. networking.multus.resources is passed only when set, so an unset key
leaves the multus chart default in charge.
*/}}
{{- define "cozystack.platform.multus.values" -}}
{{- $root := index . 0 -}}
{{- $values := dict "stageCniPlugins" (eq (include "cozystack.platform.stageCniPlugins" .) "true") -}}
{{- $multus := index ($root.Values.networking | default dict) "multus" -}}
{{- if kindIs "invalid" $multus -}}
{{- $multus = dict -}}
{{- end -}}
{{- if not (kindIs "map" $multus) -}}
{{- fail (printf "networking.multus: expected a map, got %s" (kindOf $multus)) -}}
{{- end -}}
{{- $resources := index $multus "resources" -}}
{{- if not (kindIs "invalid" $resources) -}}
{{- if not (kindIs "map" $resources) -}}
{{- fail (printf "networking.multus.resources: expected a map, got %s" (kindOf $resources)) -}}
{{- end -}}
{{- $_ := set $values "resources" $resources -}}
{{- end -}}
{{- toYaml $values -}}
{{- end }}

{{/*
Common system packages shared between the isp-full, isp-full-generic, isp-slim and
isp-slim-generic bundles.
Does NOT include the packages each variant emits itself: networking (variant
differs), linstor (talos.enabled differs), multus (stageCniPlugins differs) and
cozystack-scheduler (emitted with its own variant in both branches)
*/}}
{{- define "cozystack.platform.system.common-packages" -}}
{{- $root := . -}}
{{- if not (include "cozystack.platform.slim" $root) -}}
{{include "cozystack.platform.package.default" (list "cozystack.kubeovn-webhook" $root) }}
{{include "cozystack.platform.package.default" (list "cozystack.kubeovn-plunger" $root) }}
{{- end }}
{{include "cozystack.platform.package.full.default" (list "cozystack.cozy-proxy" $root) }}
{{include "cozystack.platform.package.full.default" (list "cozystack.metallb" $root) }}
{{include "cozystack.platform.package.default" (list "cozystack.reloader" $root) }}
{{include "cozystack.platform.package.default" (list "cozystack.linstor-scheduler" $root) }}
{{include "cozystack.platform.package.default" (list "cozystack.snapshot-controller" $root) }}
{{- /* securitygroup-controller maintains membership labels for CiliumNetworkPolicy-backed
       SecurityGroups, so it only makes sense where Cilium runs. Keeping it here with the
       other data-plane packages (rather than in the variant-agnostic body of system.yaml)
       keeps it out of the isp-hosted (networking=noop) variant, which never calls
       common-packages and has no cilium.io CRD for the controller to watch. */ -}}
{{include "cozystack.platform.package.default" (list "cozystack.securitygroup-controller" $root) }}
{{- end }}

{{/*
The block Cilium takes its own addresses from on the kube-ovn variants, the
last /21 of the pod CIDR, which kube-ovn is told to exclude. Called with the
pod CIDR, "cozystack.platform.ciliumPool" emits the block as a CIDR for the
Cilium operator and "cozystack.platform.ciliumPoolRange" as a first..last range
for kube-ovn excludeIps.

The block has to sit inside the pod CIDR rather than next to it. Envoy reaches
Gateway API backends from the node's Ingress IP, and kube-ovn masquerades
host-originated traffic only when its source lies in one of its subnets.
Outside them the backend's reply is routed to the backend's own node and lost.
The end of the range is the part kube-ovn reaches last, since it hands out
free addresses in ascending order and reuses released ones only once the rest
are gone. A /21 cut into /29s serves 256 nodes, the most a /16 cluster CIDR
sliced into /24s ever allowed.
*/}}
{{- define "cozystack.platform.ciliumPoolBounds" -}}
{{- $cidr := toString . -}}
{{- if not (regexMatch "^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$" $cidr) -}}
{{- fail (printf "networking.podCIDR %q is not an IPv4 CIDR" $cidr) -}}
{{- end -}}
{{- $parts := splitList "/" $cidr -}}
{{- $prefix := atoi (last $parts) -}}
{{- if gt $prefix 20 -}}
{{- fail (printf "networking.podCIDR %s is too small. The kube-ovn variants reserve its last /21 for Cilium, so it needs a prefix of /20 or shorter" $cidr) -}}
{{- end -}}
{{- $address := 0 -}}
{{- range splitList "." (first $parts) -}}
{{- $address = add (mul $address 256) (atoi .) -}}
{{- end -}}
{{- $size := 1 -}}
{{- range until (sub 32 $prefix | int) -}}
{{- $size = mul $size 2 -}}
{{- end -}}
{{- $first := add (sub $address (mod $address $size)) (sub $size 2048) -}}
{{- printf "%s %s" (include "cozystack.platform.ipv4" $first) (include "cozystack.platform.ipv4" (add $first 2047)) -}}
{{- end }}

{{- define "cozystack.platform.ipv4" -}}
{{- printf "%d.%d.%d.%d" (div . 16777216) (mod (div . 65536) 256) (mod (div . 256) 256) (mod . 256) -}}
{{- end }}

{{- define "cozystack.platform.ciliumPool" -}}
{{- printf "%s/21" (first (splitList " " (include "cozystack.platform.ciliumPoolBounds" .))) -}}
{{- end }}

{{- define "cozystack.platform.ciliumPoolRange" -}}
{{- join ".." (splitList " " (include "cozystack.platform.ciliumPoolBounds" .)) -}}
{{- end }}

{{/*
The image override table every release gets as _cluster.image-overrides, as
a YAML list: registries.imageOverrides validated, then the entries
registries.imageRewrites expands to, then checked against the images the
release runs (files/images.yaml). cozystack-operator and cozystack-api refuse
to build releases from a table they cannot apply, so a broken table fails
this render instead, where the error names the value that is wrong. The
checks of single entries match pkg/imageoverrides.Validate.
*/}}
{{- define "cozystack.platform.imageOverrides" -}}
{{- /* Checked before defaulting: default would turn false or 0 into an empty
list and drop the table without a word. */}}
{{- $overrides := (.Values.registries | default dict).imageOverrides }}
{{- if and (not (kindIs "invalid" $overrides)) (not (kindIs "slice" $overrides)) }}
{{-   fail (printf "registries.imageOverrides must be a list, got %s" (kindOf $overrides)) }}
{{- end }}
{{- $overrides = $overrides | default list }}
{{- $seen := dict }}
{{- range $i, $o := $overrides }}
{{-   if not (kindIs "map" $o) }}
{{-     fail (printf "registries.imageOverrides[%d] must be a map" $i) }}
{{-   end }}
{{-   range $k, $v := $o }}
{{-     if not (has $k (list "name" "newName" "newTag" "digest" "match")) }}
{{-       fail (printf "registries.imageOverrides[%d]: unknown field %q" $i $k) }}
{{-     end }}
{{- /* An unquoted tag such as 1.20 arrives as the number 1.2. */}}
{{-     if and (ne $k "match") (not (kindIs "string" $v)) }}
{{-       fail (printf "registries.imageOverrides[%d].%s must be a string, got %s; quote it" $i $k (kindOf $v)) }}
{{-     end }}
{{-   end }}
{{-   $name := $o.name | default "" | toString }}
{{-   if not $name }}
{{-     fail (printf "registries.imageOverrides[%d]: name is required" $i) }}
{{-   end }}
{{-   if or (contains "@" $name) (contains ":" (last (splitList "/" $name))) }}
{{-     fail (printf "registries.imageOverrides[%d]: name %q must not carry a tag or digest" $i $name) }}
{{-   end }}
{{- /* kustomize turns the name into a regular expression unescaped. */}}
{{-   if not (regexMatch "^[A-Za-z0-9]([A-Za-z0-9._/:-]*[A-Za-z0-9])?$" $name) }}
{{-     fail (printf "registries.imageOverrides[%d]: name %q is not an image name" $i $name) }}
{{-   end }}
{{-   if not (or $o.newName $o.newTag $o.digest) }}
{{-     fail (printf "registries.imageOverrides[%d]: %q sets none of newName, newTag, digest" $i $name) }}
{{-   end }}
{{-   if and $o.digest (not (regexMatch "^sha256:[0-9a-f]{64}$" (toString $o.digest))) }}
{{-     fail (printf "registries.imageOverrides[%d]: digest %q is not sha256:<64 hex>" $i (toString $o.digest)) }}
{{-   end }}
{{-   $selector := $name }}
{{-   if hasKey $o "match" }}
{{-     $m := $o.match }}
{{-     if not (kindIs "map" $m) }}
{{-       fail (printf "registries.imageOverrides[%d].match must be a map" $i) }}
{{-     end }}
{{-     range $k, $v := $m }}
{{-       if not (has $k (list "tag" "digest")) }}
{{-         fail (printf "registries.imageOverrides[%d].match: unknown field %q" $i $k) }}
{{-       end }}
{{-       if not (kindIs "string" $v) }}
{{-         fail (printf "registries.imageOverrides[%d].match.%s must be a string, got %s; quote it" $i $k (kindOf $v)) }}
{{-       end }}
{{-     end }}
{{-     if eq (not $m.tag) (not $m.digest) }}
{{-       fail (printf "registries.imageOverrides[%d]: match on %q must set exactly one of tag, digest" $i $name) }}
{{-     end }}
{{-     if and $m.tag (not (regexMatch "^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$" $m.tag)) }}
{{-       fail (printf "registries.imageOverrides[%d]: match.tag %q is not an image tag" $i $m.tag) }}
{{-     end }}
{{-     if and $m.digest (not (regexMatch "^sha256:[0-9a-f]{64}$" $m.digest)) }}
{{-       fail (printf "registries.imageOverrides[%d]: match.digest %q is not sha256:<64 hex>" $i $m.digest) }}
{{-     end }}
{{-     $selector = ternary (printf "%s:%s" $name $m.tag) (printf "%s@%s" $name $m.digest) (not (empty $m.tag)) }}
{{-   end }}
{{- /* One entry per name and version: match lets the same name appear once
per tag or digest besides the entry without match. */}}
{{-   if hasKey $seen $selector }}
{{-     fail (printf "registries.imageOverrides[%d]: %q is listed twice" $i $selector) }}
{{-   end }}
{{-   $_ := set $seen $selector true }}
{{- end }}
{{- $images := (include "cozystack.platform.imageList" . | fromYaml).images }}
{{- $table := concat $overrides ((include "cozystack.platform.imageRewrites" (list . $overrides $images) | fromYaml).entries | default list) }}
{{- include "cozystack.platform.checkImageOverrides" (list . $table $images) }}
{{- toYaml $table }}
{{- end }}

{{/*
The images the release runs, as YAML under "images": each with ref, chart,
route (0 container, 1 cozy-lib helper, 2 vendored value set in parts, 3
patched vendored template) and joinsTag when an operator rebuilds it as
repository:tag. hack/image-list.sh writes files/images.yaml. _images replaces
the file in this chart's tests, so that they do not follow every version bump.
*/}}
{{- define "cozystack.platform.imageList" -}}
{{- $images := .Values._images }}
{{- if kindIs "invalid" $images }}
{{-   $images = (.Files.Get "files/images.yaml" | fromYaml).images }}
{{- end }}
{{- dict "images" ($images | default list) | toYaml }}
{{- end }}

{{/*
The registry a reference is pulled from: its first path component when that
looks like a host, docker.io otherwise.
*/}}
{{- define "cozystack.platform.imageRegistry" -}}
{{- if regexMatch "^([^/]*[.:][^/]*|localhost)/" . }}{{ regexFind "^[^/]+" . }}{{ else }}docker.io{{ end }}
{{- end }}

{{/*
An image name as Docker reads it: busybox is docker.io/library/busybox and
clastix/kubectl is docker.io/clastix/kubectl. The tree writes some images
both ways, and a prefix rule for docker.io/ must catch both.
*/}}
{{- define "cozystack.platform.normalizedImageName" -}}
{{- if regexMatch "^([^/]*[.:][^/]*|localhost)/" . }}{{ . }}
{{- else if contains "/" . }}docker.io/{{ . }}
{{- else }}docker.io/library/{{ . }}
{{- end }}
{{- end }}

{{/*
The entries registries.imageRewrites expands to, as YAML under "entries".
A rule renames every image of the release whose normalized name starts with
prefix, keeping the rest of the name and the tag; the entry carries the name
as the tree writes it. The first rule that applies wins, and an explicit
entry with the same name and match takes precedence. With dropDigest an image
pinned by digest gets an entry per tag that retags it to the same tag, which
is how kustomize drops a digest; those come before the plain renames, which
would otherwise rename the image before they are reached.
Call as (list $ <explicit entries> <images>).
*/}}
{{- define "cozystack.platform.imageRewrites" -}}
{{- $root := index . 0 }}
{{- $rules := ($root.Values.registries | default dict).imageRewrites }}
{{- if and (not (kindIs "invalid" $rules)) (not (kindIs "slice" $rules)) }}
{{-   fail (printf "registries.imageRewrites must be a list, got %s" (kindOf $rules)) }}
{{- end }}
{{- range $i, $r := $rules | default list }}
{{-   if not (kindIs "map" $r) }}
{{-     fail (printf "registries.imageRewrites[%d] must be a map" $i) }}
{{-   end }}
{{-   range $k, $v := $r }}
{{-     if not (has $k (list "prefix" "newPrefix" "dropDigest")) }}
{{-       fail (printf "registries.imageRewrites[%d]: unknown field %q" $i $k) }}
{{-     end }}
{{-   end }}
{{-   if not (and (kindIs "string" $r.prefix) $r.prefix (kindIs "string" $r.newPrefix) $r.newPrefix) }}
{{-     fail (printf "registries.imageRewrites[%d]: prefix and newPrefix must be non-empty strings" $i) }}
{{-   end }}
{{-   if and (hasKey $r "dropDigest") (not (kindIs "bool" $r.dropDigest)) }}
{{-     fail (printf "registries.imageRewrites[%d].dropDigest must be true or false" $i) }}
{{-   end }}
{{- end }}
{{- $taken := dict }}
{{- range index . 1 }}
{{-   $_ := set $taken (printf "%s|%s|%s" .name (dig "match" "tag" "" .) (dig "match" "digest" "" .)) true }}
{{- end }}
{{- $retags := list }}
{{- $renames := list }}
{{- range $image := index . 2 }}
{{-   $parts := include "cozy-lib.imageOverrides.split" $image.ref | fromYaml }}
{{-   $normalized := include "cozystack.platform.normalizedImageName" $parts.name }}
{{-   $rule := dict }}
{{-   range $rules | default list }}
{{-     if and (not $rule) (hasPrefix .prefix $normalized) }}
{{-       $rule = . }}
{{-     end }}
{{-   end }}
{{-   if $rule }}
{{-     $newName := printf "%s%s" $rule.newPrefix (trimPrefix $rule.prefix $normalized) }}
{{-     if and $rule.dropDigest $parts.digest }}
{{-       if not $parts.tag }}
{{-         fail (printf "registries.imageRewrites: %s has a digest and no tag, so dropDigest cannot drop it; list it in imageOverrides with its new digest" $image.ref) }}
{{-       end }}
{{-       $key := printf "%s|%s|" $parts.name $parts.tag }}
{{-       if not (hasKey $taken $key) }}
{{-         $_ := set $taken $key true }}
{{-         $retags = append $retags (dict "name" $parts.name "match" (dict "tag" $parts.tag) "newName" $newName "newTag" $parts.tag) }}
{{-       end }}
{{-     end }}
{{-     $key := printf "%s||" $parts.name }}
{{-     if not (hasKey $taken $key) }}
{{-       $_ := set $taken $key true }}
{{-       $renames = append $renames (dict "name" $parts.name "newName" $newName) }}
{{-     end }}
{{-   end }}
{{- end }}
{{- dict "entries" (concat $retags $renames) | toYaml }}
{{- end }}

{{/*
Checks the table against the images the release runs; renders nothing.
- An entry with match that applies to no image names a version the release
  does not run, most likely one an upgrade moved past: without the check that
  image would silently fall back to its upstream name.
- Route 2 cannot honour match, so an entry with match that applies only to
  images route 2 reaches would do nothing.
- An operator that rebuilds a reference as repository:tag cannot express a
  digest without a tag, so an entry that leaves only a digest is refused for
  its images.
- A reference can pass through a helper and then the post-renderer, so the
  table must leave its own result unchanged.
- With allowedRegistries, every image must end up in one of them.
Without a list of images, as in a chart built without one, only the entries
themselves are checked.
Call as (list $ <table> <images>).
*/}}
{{- define "cozystack.platform.checkImageOverrides" -}}
{{- $root := index . 0 }}
{{- $table := index . 1 }}
{{- $images := index . 2 }}
{{- if $images }}
{{-   range $e := $table }}
{{-     $hits := list }}
{{-     range $images }}
{{-       if include "cozy-lib.imageOverrides.selects" (list .ref $e) }}
{{-         $hits = append $hits . }}
{{-       end }}
{{-     end }}
{{-     $selector := $e.name }}
{{-     with $e.match }}
{{-       $selector = ternary (printf "%s:%s" $selector .tag) (printf "%s@%s" $selector .digest) (not (empty .tag)) }}
{{-     end }}
{{-     if $e.match }}
{{-       if not $hits }}
{{-         fail (printf "registries.imageOverrides: %s matches no image this release runs; see files/images.yaml of the platform chart for the versions it does" $selector) }}
{{-       end }}
{{-       $honoured := false }}
{{-       range $hits }}
{{-         if ne (toString .route) "2" }}
{{-           $honoured = true }}
{{-         end }}
{{-       end }}
{{-       if not $honoured }}
{{-         fail (printf "registries.imageOverrides: %s selects a version, but %s reaches that image only through chart values that cannot select one; drop match" $selector (index $hits 0).chart) }}
{{-       end }}
{{-     end }}
{{-     if and $e.digest (not $e.newTag) }}
{{-       range $hits }}
{{-         if .joinsTag }}
{{-           fail (printf "registries.imageOverrides: %s sets a digest without newTag, but the operator %s configures builds %s as repository:tag; set newTag as well" $selector .chart .ref) }}
{{-         end }}
{{-       end }}
{{-     end }}
{{-   end }}
{{-   $allowed := ($root.Values.registries | default dict).allowedRegistries }}
{{-   if and (not (kindIs "invalid" $allowed)) (not (kindIs "slice" $allowed)) }}
{{-     fail (printf "registries.allowedRegistries must be a list, got %s" (kindOf $allowed)) }}
{{-   end }}
{{-   $outside := list }}
{{-   range $images }}
{{-     $once := include "cozy-lib.imageWith" (list .ref $table) }}
{{-     $twice := include "cozy-lib.imageWith" (list $once $table) }}
{{-     if ne $once $twice }}
{{-       fail (printf "registries.imageOverrides: the table is not idempotent on %s (%s): %s, then %s; order the entries so that none rewrites what another produced" .ref .chart $once $twice) }}
{{-     end }}
{{-     if and $allowed (not (has (include "cozystack.platform.imageRegistry" $once) $allowed)) }}
{{-       $outside = append $outside (printf "%s (%s) -> %s" .ref .chart $once) }}
{{-     end }}
{{-   end }}
{{-   if $outside }}
{{-     fail (printf "registries.allowedRegistries: %d images resolve outside %s:\n  %s\nNode images and images operators pick at runtime are not in this list; cover them with registry mirrors" (len $outside) (join ", " $allowed) (join "\n  " (uniq $outside))) }}
{{-   end }}
{{- end }}
{{- end }}

{{/*
Warnings about the image override table for NOTES.txt: an entry without
match that applies to no image the release runs is most likely a misspelt
name.
*/}}
{{- define "cozystack.platform.imageOverridesWarnings" -}}
{{- $images := (include "cozystack.platform.imageList" . | fromYaml).images }}
{{- if $images }}
{{-   range (include "cozystack.platform.imageOverrides" . | fromYamlArray) }}
{{-     $e := . }}
{{-     if not $e.match }}
{{-       $hit := false }}
{{-       range $images }}
{{-         if include "cozy-lib.imageOverrides.selects" (list .ref $e) }}
{{-           $hit = true }}
{{-         end }}
{{-       end }}
{{-       if not $hit }}
WARNING: registries.imageOverrides: {{ $e.name }} matches no image this release runs; check the name against files/images.yaml of the platform chart.
{{-       end }}
{{-     end }}
{{-   end }}
{{- end }}
{{- end }}
