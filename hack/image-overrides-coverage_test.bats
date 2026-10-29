#!/usr/bin/env bats
# Every image the charts of hack/image-list.sh render has to follow the image
# override table, by whichever route reaches it: a reference the table cannot
# rename is one an air-gapped cluster pulls from upstream anyway. The guard
# renders each chart, renames every image it finds, renders again with the
# table handed over as the platform hands it, and fails on any image left
# under its old name outside a container, which the post-renderer rewrites.
# hack/image-overrides-coverage.allowlist holds the known exceptions, each
# with its reason; an entry that matches nothing fails too.

load test_helper

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"

@test "every image the listed charts render follows the image override table" {
  command -v python3 >/dev/null || skip "python3 is not installed"
  "$REPO_ROOT/hack/image-list.sh" --coverage
}
