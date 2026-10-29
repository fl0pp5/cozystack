#!/usr/bin/env bats
# cert-manager runs ACME HTTP-01 solver pods from an image its controller takes
# as an argument, so the post-renderer never sees it. The platform chart passes
# the vendored chart the parts of that image the override table changes
# (cozy-lib.imageOverrideValues onto acmesolver.image in
# templates/bundles/system.yaml, and in the kubernetes chart for the cert-manager
# of a tenant cluster), and the chart joins them with its defaults.
# The result must be the reference kustomize would have made of the default,
# and both callers must name the image the chart actually renders, or no
# entry ever matches it.

load test_helper

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
CERT_MANAGER="$REPO_ROOT/packages/system/cert-manager"
DIGEST=sha256:f80b60d4523dcdecb225c3113bcbd0eedc45b4d2b46f87c0ccf4f14d09a4a35f

solver_image() {
  helm template cm "$CERT_MANAGER" "$@" 2>/dev/null | grep -o -- '--acme-http01-solver-image=[^"'"'"' ]*' | cut -d= -f2-
}

@test "the platform and the kubernetes chart name the solver image the chart renders" {
  local file name
  for file in packages/core/platform/templates/bundles/system.yaml packages/apps/kubernetes/templates/helmreleases/cert-manager.yaml; do
    name=$(sed -n 's/.*cozy-lib.imageOverrideValues" (list "\([^"]*\)".*/\1/p' "$REPO_ROOT/$file")
    [ -n "$name" ] || { echo "$file passes no solver image" >&2; return 1; }
    [ "$(solver_image)" = "$name:$(yq '.appVersion' "$CERT_MANAGER/charts/cert-manager/Chart.yaml")" ] || {
      echo "$file names $name, chart renders $(solver_image)" >&2
      return 1
    }
  done
}

@test "the solver image built from the passed parts is what kustomize makes of the default" {
  local chart="$BATS_TEST_TMPDIR/entries" default table out want got key value
  local -a args
  default=$(solver_image)
  mkdir -p "$chart/templates" "$chart/charts"
  printf 'apiVersion: v2\nname: entries\nversion: 0.0.0\n' > "$chart/Chart.yaml"
  ln -s "$REPO_ROOT/packages/library/cozy-lib" "$chart/charts/cozy-lib"
  cat > "$chart/templates/out.yaml" <<'TPL'
want: {{ include "cozy-lib.imageWith" (list .Values.default .Values.table) | quote }}
values: {{ include "cozy-lib.imageOverrideValues" (list (regexReplaceAll ":[^:/]*$" .Values.default "") .Values.table) | fromYaml | toJson }}
TPL
  for table in \
    '[{"name":"quay.io/jetstack/cert-manager-acmesolver","newName":"registry.example.org/os/acmesolver"}]' \
    '[{"name":"quay.io/jetstack/cert-manager-acmesolver","newTag":"v1.20.2-os1"}]' \
    "[{\"name\":\"quay.io/jetstack/cert-manager-acmesolver\",\"digest\":\"$DIGEST\"}]" \
    "[{\"name\":\"quay.io/jetstack/cert-manager-acmesolver\",\"newName\":\"registry.example.org/os/acmesolver\",\"newTag\":\"v1.20.2-os1\",\"digest\":\"$DIGEST\"}]"; do
    out=$(helm template e "$chart" --set-string "default=$default" --set-json "table=$table" 2>/dev/null)
    want=$(printf '%s\n' "$out" | yq '.want')
    args=()
    for key in repository tag digest; do
      value=$(printf '%s\n' "$out" | yq ".values.$key // \"\"")
      [ -z "$value" ] || args+=(--set-string "cert-manager.acmesolver.image.$key=$value")
    done
    got=$(solver_image "${args[@]}")
    [ "$got" = "$want" ] || { echo "table $table: chart renders $got, kustomize $want" >&2; return 1; }
  done
}
