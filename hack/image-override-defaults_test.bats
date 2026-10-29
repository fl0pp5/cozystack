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

# The migration hook passes migrations 37, 50 and 54 the image the table gives
# each default they write, and passes nothing when the table leaves it alone.
# It can only tell if it starts from the same reference the migration falls
# back to.
@test "the migration hook starts from the images migrations 37, 50 and 54 write" {
  local hook="$REPO_ROOT/packages/core/platform/templates/migration-hook.yaml"
  local mig="$REPO_ROOT/packages/core/platform/images/migrations/migrations"
  local pair var n ref
  for pair in CNPG_SYSTEM_IMAGE:37 ETCD_OPERATOR_IMAGE:50 REDIS_PIN_IMAGE:54; do
    var=${pair%%:*}; n=${pair#*:}
    ref=$(sed -n "s/.*\${$var:-\\([^}]*\\)}.*/\\1/p" "$mig/$n" | head -1)
    [ -n "$ref" ] || { echo "migration $n has no \${$var:-<default>}" >&2; return 1; }
    grep -qF "(list \"$ref\"" "$hook" || grep -qF "dict \"$ref\"" "$hook" || {
      echo "migration $n falls back to $ref, which the hook does not start from" >&2
      return 1
    }
    grep -qF "name: $var" "$hook" || { echo "the hook never passes $var" >&2; return 1; }
  done
}
