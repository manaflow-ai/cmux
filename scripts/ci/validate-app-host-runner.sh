#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: app-host runner identity: $*" >&2
  exit 1
}

[ "${CI:-}" = "true" ] \
  || fail "CI is not active"
[ "${GITHUB_ACTIONS:-}" = "true" ] \
  || fail "GitHub Actions is not active"
[ "${GITHUB_REPOSITORY:-}" = "manaflow-ai/cmux" ] \
  || fail "unexpected repository"
[ "${GITHUB_JOB:-}" = "app-host-unit-tests" ] \
  || fail "unexpected job"
[ "${CMUX_CI_APP_HOST_ISOLATION_REQUIRED:-}" = "1" ] \
  || fail "app-host isolation is not required"
[ "${RUNNER_OS:-}" = "macOS" ] \
  || fail "unexpected platform"

case "${RUNNER_NAME:-}" in
  warp-*) ;;
  *) fail "resolved runner is not WarpBuild Cloud" ;;
esac
case "$RUNNER_NAME" in
  *[!A-Za-z0-9_-]*) fail "resolved runner name is malformed" ;;
esac
[ -n "${WARPBUILD_RUNNER_VERIFICATION_TOKEN:-}" ] \
  || fail "WarpBuild provider identity is unavailable"

# WarpBuild Cloud allocates a fresh VM for every job and destroys it when the
# workflow completes. That process/filesystem boundary makes strict v3 receipt
# parsing and exact-current-job scope deletion safe without PID migration or
# cross-job reclamation. https://www.warpbuild.com/docs/ci/cloud-runners
printf 'Verified ephemeral app-host runner: %s\n' "$RUNNER_NAME"
