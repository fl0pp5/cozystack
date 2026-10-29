#!/usr/bin/env bash
# Write the release image list the platform chart validates the image
# override table against (packages/core/platform/files/images.yaml): every
# reference the listed charts render, with the chart and the route that
# reaches it.
#
#   route 0  a container image, rewritten by the post-renderer
#   route 1  passed through a cozy-lib helper in a template of ours
#   route 2  a vendored chart value the platform sets in parts; it cannot
#            honour match
#   route 3  a patched vendored template, reading the table under its own key
#
# Charts that name an image only when the table changes it render nothing for
# it without a table, so every chart is rendered with a probe images-registry:
# cozy-lib.image prefixes it to every reference it handles, which makes those
# fields appear and marks what a helper reached. Routes 2 and 3 do not see
# _cluster and are read from the objects that carry them.
#
# joinsTag marks a reference an operator rebuilds as repository:tag, which
# cannot express a digest without a tag.
#
# Proof of concept: it covers the charts below, each at every version it
# offers, and its output is committed by hand. The proposal generates the
# list for every chart when the packages artifact is built.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE=probe.invalid
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ref<TAB>chart<TAB>route<TAB>joinsTag
: > "$TMP/refs"

add() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-false}" >> "$TMP/refs"
}

# render <chart> <helm args...>: collect routes 0 and 1 from a probe render,
# then whatever the chart-specific extractor reads. RELEASE names the release
# for a chart that checks its name.
render() {
  local chart="$1" out="$TMP/out.yaml" ref
  shift
  if ! helm template "${RELEASE:-release}" "$ROOT/packages/$chart" --namespace tenant-x \
      --set-string "_cluster.images-registry=$PROBE" "$@" > "$out" 2>/dev/null; then
    echo "image-list: $chart did not render with: $*" >&2
    return 1
  fi
  while read -r ref; do
    # yq separates the documents of a multi-document render with ---, and a
    # container without an image yields null.
    case "$ref" in ""|---|null) continue ;; esac
    case "$ref" in
      "$PROBE"/*) add "${ref#"$PROBE"/}" "$chart" 1 ;;
      *) add "$ref" "$chart" 0 ;;
    esac
  done < <(yq '.. | select(tag == "!!map" and (has("containers") or has("initContainers"))) | ((.containers // []) + (.initContainers // []))[] | .image' "$out")
  while read -r ref; do
    add "${ref#"$PROBE"/}" "$chart" 1
  done < <(grep -o "$PROBE/[A-Za-z0-9._/:@-]*" "$out" | sort -u)
  extract "$chart" "$out"
}

extract() {
  local chart="$1" out="$2" ref
  case "$chart" in
    system/monitoring-agents)
      while read -r ref; do
        add "${ref#"$PROBE"/}" "$chart" 1 true
      done < <(yq 'select(.kind == "VMAgent" and .spec.image) | .spec.image.repository + ":" + .spec.image.tag' "$out")
      ;;
    system/cert-manager)
      while read -r ref; do
        add "$ref" "$chart" 2
      done < <(grep -o -- '--acme-http01-solver-image=[^"'"'"' ]*' "$out" | cut -d= -f2-)
      ;;
    system/mariadb-operator)
      while read -r ref; do
        add "$ref" "$chart" 3
      done < <(yq 'select(.kind == "ConfigMap" and .metadata.name == "mariadb-operator-env") | .data | to_entries[] | select(.key | test("^(RELATED_IMAGE_|MARIADB_OPERATOR_IMAGE$)")) | .value' "$out")
      ;;
    system/kubeovn)
      while read -r ref; do
        add "$ref" "$chart" 3
      done < <(yq 'select(.kind == "Deployment" and .metadata.name == "kube-ovn-controller") | .spec.template.spec.containers[].args[] | select(test("^--image=")) | sub("^--image=", "")' "$out"
               yq 'select(.kind == "ConfigMap" and .metadata.name == "ovn-vpc-nat-config") | .data.image' "$out")
      ;;
  esac
}

for version in $(yq 'keys | .[]' "$ROOT/packages/apps/postgres/files/versions.yaml"); do
  render apps/postgres --set-json '_cluster.scheduling={}' --set _namespace.host=example.org --set "version=$version"
done
for version in $(yq 'keys | .[]' "$ROOT/packages/apps/postgres/files/postgis-versions.yaml"); do
  render apps/postgres --set-json '_cluster.scheduling={}' --set _namespace.host=example.org --set "version=$version" --set flavor=postgis
done
for version in $(yq 'keys | .[]' "$ROOT/packages/apps/mariadb/files/versions.yaml"); do
  render apps/mariadb --set _namespace.host=example.org --set "version=$version"
done
# The kubelet of tenant workers is tagged with the Kubernetes version of the
# pool.
for version in $(yq 'keys | .[]' "$ROOT/packages/apps/kubernetes-nodes/files/versions.yaml"); do
  RELEASE=kubernetes-nodes-list-pool render apps/kubernetes-nodes --set-string cluster=list --set resources.cpu=2 --set resources.memory=4Gi \
    --set-string _cluster.cluster-domain=cozy.local --set "version=$version"
done
for chart in system/mariadb-operator system/etcd-operator system/monitoring-agents \
    system/capi-providers-core system/cert-manager system/foundationdb-operator \
    system/kubeovn system/keycloak system/monitoring system/seaweedfs-db; do
  render "$chart"
done
# apps/harbor runs Harbor on a CloudNativePG database and a RedisFailover of
# its own, never on the images of the chart's internal ones.
render system/harbor --set harbor.database.type=external --set harbor.redis.type=external

cat <<'EOF'
# Generated by hack/image-list.sh; do not edit. The release image list the
# platform chart checks registries.imageOverrides, imageRewrites and
# allowedRegistries against. Proof of concept: it covers a subset of charts.
EOF
echo "images:"
sort -u "$TMP/refs" | while IFS=$'\t' read -r ref chart route joins; do
  printf -- '- ref: %s\n  chart: %s\n  route: %s\n' "$ref" "$chart" "$route"
  [ "$joins" = true ] && printf '  joinsTag: true\n'
  :
done
