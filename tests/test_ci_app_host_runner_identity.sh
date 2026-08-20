#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$ROOT_DIR/scripts/ci/validate-app-host-runner.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_validator() {
  /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    CI=true \
    GITHUB_ACTIONS=true \
    GITHUB_REPOSITORY=manaflow-ai/cmux \
    GITHUB_JOB=app-host-unit-tests \
    CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
    RUNNER_OS=macOS \
    RUNNER_NAME=warp-6x-arm64-testfixture \
    WARPBUILD_RUNNER_VERIFICATION_TOKEN=testfixture.token \
    "$@" \
    /bin/bash "$VALIDATOR"
}

run_validator > "$TMP_DIR/valid.out" 2> "$TMP_DIR/valid.err" \
  || fail "validator rejected a WarpBuild app-host runner"
grep -Fq "Verified ephemeral app-host runner" "$TMP_DIR/valid.out" \
  || fail "validator did not report the accepted runner identity"

assert_rejected() {
  local name="$1"
  shift
  if run_validator "$@" > "$TMP_DIR/$name.out" 2> "$TMP_DIR/$name.err"; then
    fail "validator accepted $name"
  fi
  grep -Fq "FAIL: app-host runner identity" "$TMP_DIR/$name.err" \
    || fail "validator did not explain the $name rejection"
}

assert_rejected persistent-runner RUNNER_NAME=aws-m4pro-1
assert_rejected missing-provider-token WARPBUILD_RUNNER_VERIFICATION_TOKEN=
assert_rejected wrong-platform RUNNER_OS=Linux
assert_rejected wrong-job GITHUB_JOB=tests
assert_rejected missing-isolation CMUX_CI_APP_HOST_ISOLATION_REQUIRED=0

echo "PASS: app-host isolation requires an ephemeral runner identity"
