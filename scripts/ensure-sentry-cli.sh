#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${RUNNER_TEMP:-/tmp}/sentry-cli-bin"
SENTRY_CLI_VERSION="3.3.0"
SENTRY_CLI_ASSET="sentry-cli-Darwin-universal"
SENTRY_CLI_SHA256="dcede3b42632886a32753ad9d763f785d46afd5fa4580b5c979aad2d465d1cf5"
mkdir -p "$INSTALL_DIR"
DOWNLOAD_PATH="${RUNNER_TEMP:-/tmp}/${SENTRY_CLI_ASSET}-${SENTRY_CLI_VERSION}"

echo "Installing sentry-cli $SENTRY_CLI_VERSION into $INSTALL_DIR" >&2
curl -fsSL --connect-timeout 20 --max-time 120 \
  "https://github.com/getsentry/sentry-cli/releases/download/${SENTRY_CLI_VERSION}/${SENTRY_CLI_ASSET}" \
  --output "$DOWNLOAD_PATH"
ACTUAL_SHA256="$(shasum -a 256 "$DOWNLOAD_PATH" | awk '{ print $1 }')"
if [[ "$ACTUAL_SHA256" != "$SENTRY_CLI_SHA256" ]]; then
  echo "sentry-cli checksum mismatch: expected $SENTRY_CLI_SHA256, got $ACTUAL_SHA256" >&2
  exit 1
fi
install -m 0755 "$DOWNLOAD_PATH" "$INSTALL_DIR/sentry-cli"

SENTRY_CLI="$INSTALL_DIR/sentry-cli"
if [[ ! -x "$SENTRY_CLI" ]]; then
  echo "sentry-cli installer did not create executable at $SENTRY_CLI" >&2
  exit 1
fi

"$SENTRY_CLI" --version >&2
printf '%s\n' "$SENTRY_CLI"
