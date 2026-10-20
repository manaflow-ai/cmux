#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREPARE_SCRIPT="$ROOT_DIR/scripts/ci/prepare-app-host-home.sh"
ISOLATION_SCRIPT="$ROOT_DIR/scripts/ci/app-host-isolation.sh"

if [ ! -x "$PREPARE_SCRIPT" ]; then
  echo "FAIL: app-host identity must have one executable preparation owner"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
APP_HOST_HOME=""
APP_HOST_RECEIPT_DIR=""
APP_HOST_CONFIRMATION_FILE=""
cleanup() {
  if [ -n "$APP_HOST_HOME" ]; then
    rm -rf -- "$APP_HOST_HOME"
  fi
  if [ -n "$APP_HOST_RECEIPT_DIR" ]; then
    rm -rf -- "$APP_HOST_RECEIPT_DIR"
  fi
  if [ -n "$APP_HOST_CONFIRMATION_FILE" ]; then
    rm -f -- "$APP_HOST_CONFIRMATION_FILE"
  fi
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

export RUNNER_TEMP="$TMP_DIR/runner-temp"
export GITHUB_ENV="$TMP_DIR/github-env"
export GITHUB_REPOSITORY_ID="1234567"
export GITHUB_RUN_ID="900000$$"
export GITHUB_RUN_ATTEMPT="7"
export CMUX_APP_HOST_SHARD="3"
export CARGO_HOME="$TMP_DIR/shared-cargo"
export RUSTUP_HOME="$TMP_DIR/shared-rustup"
expected_cargo_home="$CARGO_HOME"
expected_rustup_home="$RUSTUP_HOME"
mkdir -p "$RUNNER_TEMP"
: > "$GITHUB_ENV"

bash "$PREPARE_SCRIPT"
set -a
# shellcheck disable=SC1090
source "$GITHUB_ENV"
set +a
[ "$CARGO_HOME" = "$expected_cargo_home" ] \
  || { echo "FAIL: preparation overwrote configured CARGO_HOME"; exit 1; }
[ "$RUSTUP_HOME" = "$expected_rustup_home" ] \
  || { echo "FAIL: preparation overwrote configured RUSTUP_HOME"; exit 1; }
APP_HOST_HOME="$CMUX_APP_HOST_HOME"
APP_HOST_RECEIPT_DIR="$CMUX_APP_HOST_RECEIPT_DIR"
APP_HOST_CONFIRMATION_FILE="$CMUX_APP_HOST_CONFIRMATION_FILE"

# shellcheck source=scripts/ci/app-host-isolation.sh
source "$ISOLATION_SCRIPT"
cmux_resolve_app_host_identity
cmux_validate_published_app_host_identity
cmux_validate_app_host_cleanup_confirmation

original_repository_id="$GITHUB_REPOSITORY_ID"
original_repository_key="$CMUX_RESOLVED_APP_HOST_KEY"
original_repository_home="$CMUX_RESOLVED_APP_HOST_HOME"
original_repository_receipts="$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR"
original_repository_confirmation_file="$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE"
original_repository_confirmation="$CMUX_RESOLVED_APP_HOST_CLEANUP_CONFIRMATION"
GITHUB_REPOSITORY_ID=7654321
export GITHUB_REPOSITORY_ID
cmux_resolve_app_host_identity
[ "$CMUX_RESOLVED_APP_HOST_KEY" != "$original_repository_key" ] || {
  echo "FAIL: app-host identity must distinguish repositories on one runner"
  exit 1
}
for repository_scoped_pair in \
  "$CMUX_RESOLVED_APP_HOST_HOME|$original_repository_home" \
  "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR|$original_repository_receipts" \
  "$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE|$original_repository_confirmation_file" \
  "$CMUX_RESOLVED_APP_HOST_CLEANUP_CONFIRMATION|$original_repository_confirmation"
do
  [ "${repository_scoped_pair%%|*}" != "${repository_scoped_pair#*|}" ] || {
    echo "FAIL: repository identity did not scope every cleanup authority"
    exit 1
  }
done
GITHUB_REPOSITORY_ID="$original_repository_id"
export GITHUB_REPOSITORY_ID
cmux_resolve_app_host_identity
[ "$CMUX_RESOLVED_APP_HOST_KEY" = "$original_repository_key" ] \
  || { echo "FAIL: restoring repository identity changed its key"; exit 1; }
cmux_validate_published_app_host_identity
cmux_validate_app_host_cleanup_confirmation

printf 'preserve home\n' > "$CMUX_APP_HOST_HOME/reprepare-marker"
printf 'preserve receipts\n' > "$CMUX_APP_HOST_RECEIPT_DIR/reprepare-marker"
confirmation_before="$(cat "$CMUX_APP_HOST_CONFIRMATION_FILE")"
: > "$TMP_DIR/reprepare-github-env"
set +e
GITHUB_ENV="$TMP_DIR/reprepare-github-env" \
  bash "$PREPARE_SCRIPT" >"$TMP_DIR/reprepare.log" 2>&1
reprepare_status=$?
set -e
if [ "$reprepare_status" -ne 1 ] \
  || ! grep -Fq \
    "FAIL: app-host isolation scope already exists; verified cleanup is required" \
    "$TMP_DIR/reprepare.log" \
  || ! grep -Fxq 'preserve home' "$CMUX_APP_HOST_HOME/reprepare-marker" \
  || ! grep -Fxq 'preserve receipts' "$CMUX_APP_HOST_RECEIPT_DIR/reprepare-marker" \
  || [ "$(cat "$CMUX_APP_HOST_CONFIRMATION_FILE")" != "$confirmation_before" ]; then
  cat "$TMP_DIR/reprepare.log"
  echo "FAIL: preparation must preserve an existing app-host authority scope"
  exit 1
fi

if [ "$CMUX_RESOLVED_APP_HOST_HOME" != "$(cd /tmp && pwd -P)/cmux-ah-$CMUX_APP_HOST_KEY" ]; then
  echo "FAIL: app-host home must be derived from the run identity"
  exit 1
fi
SYSTEM_TEMP_ROOT="$(cd /tmp && pwd -P)"
if [ "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" != "$SYSTEM_TEMP_ROOT/cmux-ah-$CMUX_APP_HOST_KEY-receipts" ]; then
  echo "FAIL: process receipts must survive GitHub's RUNNER_TEMP cleanup"
  exit 1
fi
if [ "$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE" != "$SYSTEM_TEMP_ROOT/cmux-ah-$CMUX_APP_HOST_KEY.confirm" ]; then
  echo "FAIL: cleanup confirmation must share the durable sticky-owner boundary"
  exit 1
fi
case "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" in
  "$RUNNER_TEMP"/*)
    echo "FAIL: process receipts must not be children of ephemeral RUNNER_TEMP"
    exit 1
    ;;
esac
rm -rf -- "$RUNNER_TEMP"
if [ ! -d "$CMUX_APP_HOST_RECEIPT_DIR" ] || [ ! -f "$CMUX_APP_HOST_CONFIRMATION_FILE" ]; then
  echo "FAIL: job-temporary cleanup removed cross-job process authority"
  exit 1
fi
mkdir -p "$RUNNER_TEMP"

REAL_HOME="$CMUX_APP_HOST_HOME"
REAL_XDG="$CMUX_APP_HOST_XDG_CONFIG_HOME"
CMUX_APP_HOST_HOME="$HOME"
CMUX_APP_HOST_XDG_CONFIG_HOME="$HOME/.config"
if cmux_validate_published_app_host_identity >"$TMP_DIR/wrong-home.log" 2>&1; then
  echo "FAIL: a self-consistent console-user home must not satisfy CI isolation"
  exit 1
fi
CMUX_APP_HOST_HOME="$REAL_HOME"
CMUX_APP_HOST_XDG_CONFIG_HOME="$REAL_XDG"

REAL_CONFIRMATION="$CMUX_APP_HOST_CLEANUP_CONFIRMATION"
case "$REAL_CONFIRMATION" in
  *0) CMUX_APP_HOST_CLEANUP_CONFIRMATION="${REAL_CONFIRMATION%?}1" ;;
  *) CMUX_APP_HOST_CLEANUP_CONFIRMATION="${REAL_CONFIRMATION%?}0" ;;
esac
[ "$CMUX_APP_HOST_CLEANUP_CONFIRMATION" != "$REAL_CONFIRMATION" ] || {
  echo "FAIL: wrong-token fixture did not change the confirmation"
  exit 1
}
if cmux_validate_app_host_cleanup_confirmation >"$TMP_DIR/wrong-token.log" 2>&1; then
  echo "FAIL: cleanup must reject a confirmation token not bound to this target"
  exit 1
fi
CMUX_APP_HOST_CLEANUP_CONFIRMATION="$REAL_CONFIRMATION"

rm -f -- "$CMUX_APP_HOST_CONFIRMATION_FILE"
if cmux_validate_app_host_cleanup_confirmation >"$TMP_DIR/missing-confirmation.log" 2>&1; then
  echo "FAIL: cleanup must reject a missing external confirmation record"
  exit 1
fi

echo "PASS: app-host identity owns launch, receipts, and cleanup confirmation"
