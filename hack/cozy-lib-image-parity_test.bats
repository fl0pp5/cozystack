#!/usr/bin/env bats
# The image override table is applied by three implementations: the kustomize
# post-renderer in helm-controller, pkg/imageoverrides.Apply for code outside a
# HelmRelease, and the cozy-lib helpers for references a container spec does
# not hold. A reference can pass through a helper and then the post-renderer,
# so a helper that disagrees with kustomize renders one image under two names.
# pkg/imageoverrides/testdata/parity.yaml carries the results the Go test has
# checked against krusty; this test holds the helpers to the same file.

load test_helper

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
PARITY="$REPO_ROOT/pkg/imageoverrides/testdata/parity.yaml"

@test "cozy-lib.imageWith agrees with kustomize on the shared fixture" {
  local chart="$BATS_TEST_TMPDIR/parity"
  mkdir -p "$chart/templates" "$chart/charts"
  printf 'apiVersion: v2\nname: parity\nversion: 0.0.0\n' > "$chart/Chart.yaml"
  ln -s "$REPO_ROOT/packages/library/cozy-lib" "$chart/charts/cozy-lib"
  cat > "$chart/templates/parity.yaml" <<'TPL'
apiVersion: v1
kind: ConfigMap
metadata:
  name: parity
data:
  results: |
    {{- range .Values.cases }}
    {{ .name }}	{{ include "cozy-lib.imageWith" (list .ref .table) }}
    {{- end }}
TPL
  helm template parity "$chart" -f "$PARITY" 2>/dev/null | yq '.data.results' | sed '/^$/d' > "$BATS_TEST_TMPDIR/got"
  yq '.cases[] | .name + "	" + .want' "$PARITY" > "$BATS_TEST_TMPDIR/want"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/want")" -gt 400 ]
  diff "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/got"
}
