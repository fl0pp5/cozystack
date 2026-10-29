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
#
# --coverage checks those charts instead (the CI guard of the proposal): each
# render is repeated with a table that renames every image the first one
# found, the way the platform hands it over, and any image left under its old
# name outside a container, which the post-renderer rewrites, is reported.
# hack/image-overrides-coverage.allowlist holds the known exceptions.
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
    apps/foundationdb)
      while read -r ref; do
        case "$ref" in ""|---|null) continue ;; esac
        add "${ref#"$PROBE"/}" "$chart" 1 true
      done < <(yq 'select(.kind == "FoundationDBCluster" or .kind == "FoundationDBBackup") | (.spec.mainContainer.imageConfigs // []) + (.spec.sidecarContainer.imageConfigs // []) | .[] | .baseImage + ":" + .tag' "$out")
      ;;
    system/piraeus-operator)
      # The defaults the operator builds images from, each OS-specific image
      # of a match rule included; the env the patch adds names them only when
      # the table changes them.
      while read -r ref; do
        case "$ref" in ""|---|null) continue ;; esac
        add "$ref" "$chart" 3
      done < <(yq 'select(.kind == "ConfigMap" and (.metadata.name | test("-image-config$"))) | .data | to_entries[] | select(.key | test("^0_")) | .value' "$out" \
               | yq ea '. as $c | $c.components | to_entries[] | .value as $v | ([$v.image] + [($v.match // [])[] | .image])[] | select(. != null) | $c.base + "/" + . + ":" + $v.tag')
      ;;
    system/kafka-operator)
      # Strimzi's operator env, each Kafka version of the maps a line of its
      # own as <version>=<reference>.
      while read -r ref; do
        case "$ref" in ""|---|null) continue ;; esac
        add "${ref#*=}" "$chart" 3
      done < <(yq 'select(.kind == "Deployment" and .metadata.name == "strimzi-cluster-operator") | .spec.template.spec.containers[0].env[] | select(.name | test("^STRIMZI_(DEFAULT_.*_IMAGE|DEFAULT_MAVEN_BUILDER|KAFKA_.*IMAGES)$")) | .value' "$out" | tr -s ' \n' '\n')
      ;;
    system/gpu-operator)
      # Every repository/image/version triple of the ClusterPolicy; a version
      # starting with sha256: is a digest. The operator appends the node's OS
      # to a driver tag itself.
      while read -r ref; do
        case "$ref" in ""|---|null) continue ;; esac
        add "$ref" "$chart" 3
      done < <(yq 'select(.kind == "ClusterPolicy") | .. | select(tag == "!!map" and has("repository") and has("image") and .repository != null and .repository != "") | .repository + "/" + .image + "\t" + .version' "$out" \
               | awk -F'\t' '{print $1 ($2 ~ /^sha256:/ ? "@" : ":") $2}')
      ;;
    system/kubeovn)
      while read -r ref; do
        add "$ref" "$chart" 3
      done < <(yq 'select(.kind == "Deployment" and .metadata.name == "kube-ovn-controller") | .spec.template.spec.containers[].args[] | select(test("^--image=")) | sub("^--image=", "")' "$out"
               yq 'select(.kind == "ConfigMap" and .metadata.name == "ovn-vpc-nat-config") | .data.image' "$out")
      ;;
  esac
}

# renders: call $EACH once per render, with the chart and its helm arguments.
renders() {
  for version in $(yq 'keys | .[]' "$ROOT/packages/apps/postgres/files/versions.yaml"); do
    "$EACH" apps/postgres --set-json '_cluster.scheduling={}' --set _namespace.host=example.org --set "version=$version"
  done
  for version in $(yq 'keys | .[]' "$ROOT/packages/apps/postgres/files/postgis-versions.yaml"); do
    "$EACH" apps/postgres --set-json '_cluster.scheduling={}' --set _namespace.host=example.org --set "version=$version" --set flavor=postgis
  done
  for version in $(yq 'keys | .[]' "$ROOT/packages/apps/mariadb/files/versions.yaml"); do
    "$EACH" apps/mariadb --set _namespace.host=example.org --set "version=$version"
  done
  # The FoundationDB operator picks every image it runs; the chart names one only
  # when the table changes it, which the probe registry always does. The
  # in-chart backup runs the unified image whatever the cluster runs.
  for version in $(yq 'keys | .[]' "$ROOT/packages/apps/foundationdb/files/versions.yaml"); do
    for type in split unified; do
      "$EACH" apps/foundationdb --set-string _cluster.cluster-domain=cozy.local --set "version=$version" \
        --set "imageType=$type" --set backup.enabled=true --set backup.s3.bucket=list \
        --set backup.s3.credentials.accessKeyId=list --set backup.s3.credentials.secretAccessKey=list
    done
  done
  for version in $(yq 'keys | .[]' "$ROOT/packages/apps/redis/files/versions.yaml"); do
    "$EACH" apps/redis --set _namespace.host=example.org --set "version=$version"
  done
  # The kubelet of tenant workers is tagged with the Kubernetes version of the
  # pool.
  for version in $(yq 'keys | .[]' "$ROOT/packages/apps/kubernetes-nodes/files/versions.yaml"); do
    RELEASE=kubernetes-nodes-list-pool "$EACH" apps/kubernetes-nodes --set-string cluster=list --set resources.cpu=2 --set resources.memory=4Gi \
      --set-string _cluster.cluster-domain=cozy.local --set "version=$version"
  done
  for chart in system/mariadb-operator system/etcd-operator system/monitoring-agents \
      system/capi-providers-core system/capi-providers-infraprovider system/cert-manager system/foundationdb-operator \
      system/kubeovn system/keycloak system/monitoring system/seaweedfs-db system/kubevirt-operator \
      system/piraeus-operator system/kafka-operator system/gpu-operator; do
    "$EACH" "$chart"
  done
  # apps/harbor runs Harbor on a CloudNativePG database and a RedisFailover of
  # its own, never on the images of the chart's internal ones.
  "$EACH" system/harbor --set harbor.database.type=external --set harbor.redis.type=external
}

COVERAGE="$ROOT/hack/image-overrides-coverage.py"
ALLOWLIST="$ROOT/hack/image-overrides-coverage.allowlist"
SENTINEL=coverage.invalid
COVERAGE_FAILED=0

# coverage <chart> <helm args...>: render, rename every image found, render
# again, and report what kept its name.
coverage() {
  local chart="$1" names="$TMP/names" table found
  shift
  : > "$TMP/refs"
  render "$chart" "$@"
  helm template "${RELEASE:-release}" "$ROOT/packages/$chart" --namespace tenant-x "$@" > "$TMP/default.yaml" 2>/dev/null
  { cut -f1 "$TMP/refs"; python3 -I "$COVERAGE" refs "$TMP/default.yaml"; } \
    | python3 -I "$COVERAGE" names /dev/stdin | sort -u > "$names"
  table="$(python3 -I "$COVERAGE" table "$names")"
  # What the platform passes beside _cluster: route 3 under the subchart's
  # key, route 2 in parts (bundles/system.yaml for the solver image).
  local -a extra=()
  case "$chart" in
    system/mariadb-operator) extra=(--set-json "mariadb-operator.cozystackImageOverrides=$table") ;;
    system/kubeovn) extra=(--set-json "kube-ovn.cozystackImageOverrides=$table") ;;
    system/piraeus-operator) extra=(--set-json "piraeus.cozystackImageOverrides=$table") ;;
    system/kafka-operator) extra=(--set-json "strimzi-kafka-operator.cozystackImageOverrides=$table") ;;
    system/gpu-operator) extra=(--set-json "gpu-operator.cozystackImageOverrides=$table") ;;
    system/cert-manager) extra=(--set-string "cert-manager.acmesolver.image.repository=$SENTINEL/quay.io/jetstack/cert-manager-acmesolver") ;;
  esac
  if ! helm template "${RELEASE:-release}" "$ROOT/packages/$chart" --namespace tenant-x "$@" \
      --set-json "_cluster.image-overrides=$table" "${extra[@]}" > "$TMP/table.yaml" 2>"$TMP/err"; then
    echo "coverage: $chart did not render with the table: $(cat "$TMP/err")" >&2
    COVERAGE_FAILED=1
    return 0
  fi
  : > "$TMP/refs"
  case "$chart" in
    system/piraeus-operator)
      # image-config keeps the defaults by design: the operator takes the
      # RELATED_IMAGE_<component>_<image> env instead, so a default without
      # its env is what kept its name.
      local wanted
      wanted="$(yq 'select(.kind == "ConfigMap" and (.metadata.name | test("-image-config$"))) | .data | to_entries[] | select(.key | test("^0_")) | .value' "$TMP/table.yaml" \
        | yq ea '. as $c | $c.components | to_entries[] | .key as $k | .value as $v | ([$v.image] + [($v.match // [])[] | .image])[] | select(. != null) | "RELATED_IMAGE_" + $k + "_" + . + " " + $c.base + "/" + . + ":" + $v.tag' | sort -u)"
      while read -r env ref; do
        [ -n "$env" ] || continue
        yq -e "select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$env\")" "$TMP/table.yaml" >/dev/null 2>&1 \
          || add "$ref" "$chart" 3
      done <<< "$wanted"
      ;;
    *) extract "$chart" "$TMP/table.yaml" ;;
  esac
  found="$(python3 -I "$COVERAGE" leftovers "$TMP/table.yaml" "$names" <(cut -f1 "$TMP/refs") "$chart" "$ALLOWLIST" "$TMP/used")"
  if [ -n "$found" ]; then
    printf '%s\n' "$found" | sed "s|^|$chart: |" >&2
    COVERAGE_FAILED=1
  fi
}

if [ "${1:-}" = --coverage ]; then
  EACH=coverage
  : > "$TMP/used"
  renders
  found="$(python3 -I "$COVERAGE" unused "$ALLOWLIST" "$TMP/used")"
  if [ -n "$found" ]; then
    printf 'allowlist entry that matched nothing: %s\n' "$found" >&2
    COVERAGE_FAILED=1
  fi
  exit "$COVERAGE_FAILED"
fi

EACH=render
renders

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
