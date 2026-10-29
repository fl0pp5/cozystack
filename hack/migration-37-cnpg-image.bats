#!/usr/bin/env bats
# Platform migration 37 --> 38 pins the PostgreSQL image of the system
# CloudNativePG clusters. The hook passes the image the platform's image
# override table gives that pin as CNPG_SYSTEM_IMAGE, and, when its tag no
# longer shows the major version, that version as CNPG_SYSTEM_IMAGE_MAJOR,
# which the migration writes into the postgres.cozystack.io/major annotation
# the charts read (cozy-lib.cnpg.image): without it a renamed cluster would
# look like another major version and stay on its image for good.
#
# Run with: bats hack/migration-37-cnpg-image.bats

load test_helper

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
MIGRATION="$REPO_ROOT/packages/core/platform/images/migrations/migrations/37"
FAKEBIN="$REPO_ROOT/hack/testdata/migration-37-cnpg"

# FAKE_CLUSTERS and the CNPG_SYSTEM_IMAGE* the hook would pass are taken from
# the environment, so a test exports what it sets.
run_migration() {
  PATH="$FAKEBIN:$PATH" FAKE_CMDLOG="$BATS_TEST_TMPDIR/cmdlog" FAKE_CLUSTERS="$FAKE_CLUSTERS" \
    bash "$MIGRATION" >"$BATS_TEST_TMPDIR/out" 2>&1
}

# Every cluster carries an imageName: the migration reads its fields with
# IFS=$'\t', which joins the empty field of a cluster without one to the next,
# so that branch never runs; the chart sets the image on its next render.
CLUSTERS='cozy-keycloak\tkeycloak-db\tghcr.io/cloudnative-pg/postgresql:17.5\tkeycloak\ncozy-monitoring\tgrafana-db\tghcr.io/cloudnative-pg/postgresql:17.2\tmonitoring\ncozy-seaweedfs\tseaweedfs-db\tghcr.io/cloudnative-pg/postgresql:16.4\tseaweedfs-db\n'

@test "pins the upstream image without a table" {
  FAKE_CLUSTERS="$CLUSTERS"
  run_migration
  grep -qF 'PATCH cozy-keycloak keycloak-db {"spec":{"imageName":"ghcr.io/cloudnative-pg/postgresql:17.7-standard-trixie"}}' "$BATS_TEST_TMPDIR/cmdlog"
  grep -qF 'PATCH cozy-monitoring grafana-db {"spec":{"imageName":"ghcr.io/cloudnative-pg/postgresql:17.7-standard-trixie"}}' "$BATS_TEST_TMPDIR/cmdlog"
  grep -qF 'PATCH cozy-seaweedfs seaweedfs-db {"spec":{"imageName":"ghcr.io/cloudnative-pg/postgresql:16.4-standard-trixie"}}' "$BATS_TEST_TMPDIR/cmdlog"
}

@test "pins the image the hook passes, with the major version its tag hides" {
  export CNPG_SYSTEM_IMAGE=registry.example.org/os/postgresql:os1 CNPG_SYSTEM_IMAGE_MAJOR=17
  FAKE_CLUSTERS="$CLUSTERS"
  run_migration
  grep -qF 'PATCH cozy-keycloak keycloak-db {"metadata":{"annotations":{"postgres.cozystack.io/major":"17"}},"spec":{"imageName":"registry.example.org/os/postgresql:os1"}}' "$BATS_TEST_TMPDIR/cmdlog"
  grep -qF 'PATCH cozy-monitoring grafana-db {"metadata":{"annotations":{"postgres.cozystack.io/major":"17"}},"spec":{"imageName":"registry.example.org/os/postgresql:os1"}}' "$BATS_TEST_TMPDIR/cmdlog"
  # A cluster on another major version keeps its own image and gets no
  # annotation of the pin's version.
  grep -qF 'PATCH cozy-seaweedfs seaweedfs-db {"spec":{"imageName":"ghcr.io/cloudnative-pg/postgresql:16.4-standard-trixie"}}' "$BATS_TEST_TMPDIR/cmdlog"
}

@test "writes no annotation when the tag still shows the major version" {
  export CNPG_SYSTEM_IMAGE=registry.example.org/os/postgresql:17.7-standard-trixie
  FAKE_CLUSTERS="$CLUSTERS"
  run_migration
  grep -qF 'PATCH cozy-keycloak keycloak-db {"spec":{"imageName":"registry.example.org/os/postgresql:17.7-standard-trixie"}}' "$BATS_TEST_TMPDIR/cmdlog"
  if grep -qF 'postgres.cozystack.io/major' "$BATS_TEST_TMPDIR/cmdlog"; then
    echo "FAIL: annotation written for a tag that shows the version" >&2
    false
  fi
}
