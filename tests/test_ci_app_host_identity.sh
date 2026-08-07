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
cleanup() {
  if [ -n "$APP_HOST_HOME" ]; then
    rm -rf -- "$APP_HOST_HOME"
  fi
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

export RUNNER_TEMP="$TMP_DIR/runner-temp"
export GITHUB_ENV="$TMP_DIR/github-env"
export GITHUB_RUN_ID="900000$$"
export GITHUB_RUN_ATTEMPT="7"
export CMUX_APP_HOST_SHARD="3"
mkdir -p "$RUNNER_TEMP"
: > "$GITHUB_ENV"

bash "$PREPARE_SCRIPT"
set -a
# shellcheck disable=SC1090
source "$GITHUB_ENV"
set +a
APP_HOST_HOME="$CMUX_APP_HOST_HOME"

# shellcheck source=scripts/ci/app-host-isolation.sh
source "$ISOLATION_SCRIPT"
cmux_resolve_app_host_identity
cmux_validate_published_app_host_identity
cmux_validate_app_host_cleanup_confirmation

if [ "$CMUX_RESOLVED_APP_HOST_HOME" != "$(cd /tmp && pwd -P)/cmux-ah-$CMUX_APP_HOST_KEY" ]; then
  echo "FAIL: app-host home must be derived from the run identity"
  exit 1
fi
RESOLVED_RUNNER_TEMP="$(cd "$RUNNER_TEMP" && pwd -P)"
if [ "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" != "$RESOLVED_RUNNER_TEMP/cmux-app-host-$CMUX_APP_HOST_KEY-receipts" ]; then
  echo "FAIL: process receipts must live outside the deletable app-host home"
  exit 1
fi

REAL_HOME="$CMUX_APP_HOST_HOME"
REAL_XDG="$CMUX_APP_HOST_XDG_CONFIG_HOME"
CMUX_APP_HOST_HOME="$HOME"
CMUX_APP_HOST_XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME/.config"
if cmux_validate_published_app_host_identity >"$TMP_DIR/wrong-home.log" 2>&1; then
  echo "FAIL: a self-consistent console-user home must not satisfy CI isolation"
  exit 1
fi
CMUX_APP_HOST_HOME="$REAL_HOME"
CMUX_APP_HOST_XDG_CONFIG_HOME="$REAL_XDG"

REAL_CONFIRMATION="$CMUX_APP_HOST_CLEANUP_CONFIRMATION"
CMUX_APP_HOST_CLEANUP_CONFIRMATION="${REAL_CONFIRMATION%?}0"
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
