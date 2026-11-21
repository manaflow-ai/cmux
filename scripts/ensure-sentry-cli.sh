#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${RUNNER_TEMP:-/tmp}/sentry-cli-bin"
SENTRY_CLI_VERSION="3.3.0"
SENTRY_CLI_ASSET="sentry-cli-Darwin-universal"
SENTRY_CLI_SHA256="dcede3b42632886a32753ad9d763f785d46afd5fa4580b5c979aad2d465d1cf5"
mkdir -p "$INSTALL_DIR"
DOWNLOAD_PATH="${RUNNER_TEMP:-/tmp}/${SENTRY_CLI_ASSET}-${SENTRY_CLI_VERSION}"

echo "Installing sentry-cli $SENTRY_CLI_VERSION into $INSTALL_DIR" >&2
SENTRY_CLI_URL="https://github.com/getsentry/sentry-cli/releases/download/${SENTRY_CLI_VERSION}/${SENTRY_CLI_ASSET}"
# The release asset mirror first (scripts/ci/release_asset_mirror.py): it waits
# out a busy upstream instead of failing. CMUX_RELEASE_MIRROR=off, a missing
# python3, or a failure leaves the direct download below as it always was.
RELEASE_ASSET_MIRROR="$(dirname "$0")/ci/release_asset_mirror.py"
if [[ "${CMUX_RELEASE_MIRROR:-}" != off && -f "$RELEASE_ASSET_MIRROR" ]] && command -v python3 >/dev/null 2>&1 &&
  python3 -I "$RELEASE_ASSET_MIRROR" fetch "$SENTRY_CLI_URL" --sha256 "$SENTRY_CLI_SHA256" --out "$DOWNLOAD_PATH"; then
  :
else
  # This download runs on a release runner after a 40-minute build, and a DNS blip
  # there killed release run 34851108495 (curl: (6) Could not resolve host: github.com).
  # --retry alone only covers transient HTTP codes; --retry-all-errors also retries
  # resolution and connection failures, with a bounded delay between attempts.
  curl -fsSL --connect-timeout 20 --max-time 120 \
    --retry 5 --retry-delay 5 --retry-all-errors --retry-connrefused \
    "$SENTRY_CLI_URL" \
    --output "$DOWNLOAD_PATH"
fi
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
