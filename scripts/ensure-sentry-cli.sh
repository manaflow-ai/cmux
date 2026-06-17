#!/usr/bin/env bash
set -euo pipefail

if command -v sentry-cli >/dev/null 2>&1; then
  command -v sentry-cli
  exit 0
fi

INSTALL_DIR="${RUNNER_TEMP:-/tmp}/sentry-cli-bin"
SENTRY_CLI_VERSION="${SENTRY_CLI_VERSION:-3.3.0}"
mkdir -p "$INSTALL_DIR"
INSTALLER_PATH="${RUNNER_TEMP:-/tmp}/sentry-cli-install.sh"

echo "Installing sentry-cli $SENTRY_CLI_VERSION into $INSTALL_DIR" >&2
curl -fsSL --connect-timeout 20 --max-time 120 https://sentry.io/get-cli/ --output "$INSTALLER_PATH"
(
  unset SENTRY_AUTH_TOKEN
  INSTALL_DIR="$INSTALL_DIR" SENTRY_CLI_VERSION="$SENTRY_CLI_VERSION" sh "$INSTALLER_PATH"
) >&2

SENTRY_CLI="$INSTALL_DIR/sentry-cli"
if [[ ! -x "$SENTRY_CLI" ]]; then
  echo "sentry-cli installer did not create executable at $SENTRY_CLI" >&2
  exit 1
fi

"$SENTRY_CLI" --version >&2
printf '%s\n' "$SENTRY_CLI"
