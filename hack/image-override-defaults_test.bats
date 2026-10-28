#!/usr/bin/env bats
# Where an operator picks an image itself, the chart that renders its custom
# resource records the operator's default so that the platform's image override
# table can be applied to it, and names the image only when the table changes
# it. A recorded default that falls behind the operator does nothing without a
# table and, with one, pins every cluster that has a table to the older image.
# These hold each recorded default to the source it was read from, where that
# source is in the tree; the vmagent version is compiled into the operator and
# is re-pinned by `make update` in victoria-metrics-operator instead.

load test_helper

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"

# A reference without its digest.
strip_digest() {
  printf '%s\n' "${1%@*}"
}

@test "capi-providers-core managerImage is the manager image of core-components.yaml" {
  local recorded shipped
  recorded=$(yq '.managerImage' "$REPO_ROOT/packages/system/capi-providers-core/values.yaml")
  shipped=$(sed -n 's/^ *image: *//p' "$REPO_ROOT/packages/system/capi-providers-core/files/core-components.yaml")
  [ "$(printf '%s\n' "$shipped" | wc -l)" -eq 1 ] || { echo "core-components.yaml has more than one image: $shipped" >&2; return 1; }
  [ "$(strip_digest "$recorded")" = "$shipped" ] || {
    echo "values.yaml managerImage $recorded, core-components.yaml runs $shipped" >&2
    return 1
  }
}

@test "monitoring-agents configReloaderImage follows the vendored VictoriaMetrics operator" {
  local recorded app
  recorded=$(yq '.vmagent.configReloaderImage' "$REPO_ROOT/packages/system/monitoring-agents/values.yaml")
  app=$(yq '.appVersion' "$REPO_ROOT/packages/system/victoria-metrics-operator/charts/victoria-metrics-operator/Chart.yaml")
  [ "$(strip_digest "$recorded")" = "victoriametrics/operator:config-reloader-$app" ] || {
    echo "values.yaml configReloaderImage $recorded, operator is $app; run make update in victoria-metrics-operator" >&2
    return 1
  }
}

@test "every recorded default is pinned by digest" {
  local ref
  for ref in \
    "$(yq '.managerImage' "$REPO_ROOT/packages/system/capi-providers-core/values.yaml")" \
    "$(yq '.vmagent.image' "$REPO_ROOT/packages/system/monitoring-agents/values.yaml")" \
    "$(yq '.vmagent.configReloaderImage' "$REPO_ROOT/packages/system/monitoring-agents/values.yaml")"; do
    [[ "$ref" == *@sha256:* ]] || { echo "$ref carries no digest" >&2; return 1; }
  done
}
