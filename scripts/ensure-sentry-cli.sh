#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${RUNNER_TEMP:-/tmp}/sentry-cli-bin"
SENTRY_CLI_VERSION="3.3.0"
# Pinned per platform (GitHub release digests of sentry-cli 3.3.0): the macOS
# release runners and the Linux job that uploads the cmux-tui client's dSYMs.
case "$(uname -s)-$(uname -m)" in
  Darwin-*)
    SENTRY_CLI_ASSET="sentry-cli-Darwin-universal"
    SENTRY_CLI_SHA256="dcede3b42632886a32753ad9d763f785d46afd5fa4580b5c979aad2d465d1cf5" ;;
  Linux-x86_64)
    SENTRY_CLI_ASSET="sentry-cli-Linux-x86_64"
    SENTRY_CLI_SHA256="5563b71cc28cd8b1e2cd1037f8e377083992ec112c9bf1ff0efd26dfe3b1e67e" ;;
  Linux-aarch64)
    SENTRY_CLI_ASSET="sentry-cli-Linux-aarch64"
    SENTRY_CLI_SHA256="66ac0b802e82fcef7610dc29559f18efc1eef67bf9610a19705a844ed0697dd4" ;;
  *)
    echo "no pinned sentry-cli for $(uname -s)-$(uname -m)" >&2
    exit 1 ;;
esac
mkdir -p "$INSTALL_DIR"
DOWNLOAD_PATH="${RUNNER_TEMP:-/tmp}/${SENTRY_CLI_ASSET}-${SENTRY_CLI_VERSION}"

echo "Installing sentry-cli $SENTRY_CLI_VERSION into $INSTALL_DIR" >&2
# This download runs on a release runner after a 40-minute build, and a DNS blip
# there killed release run 34851108495 (curl: (6) Could not resolve host: github.com).
# --retry alone only covers transient HTTP codes; --retry-all-errors also retries
# resolution and connection failures, with a bounded delay between attempts.
curl -fsSL --connect-timeout 20 --max-time 120 \
  --retry 5 --retry-delay 5 --retry-all-errors --retry-connrefused \
  "https://github.com/getsentry/sentry-cli/releases/download/${SENTRY_CLI_VERSION}/${SENTRY_CLI_ASSET}" \
  --output "$DOWNLOAD_PATH"
if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(shasum -a 256 "$DOWNLOAD_PATH" | awk '{ print $1 }')"
else
  ACTUAL_SHA256="$(sha256sum "$DOWNLOAD_PATH" | awk '{ print $1 }')"
fi
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
