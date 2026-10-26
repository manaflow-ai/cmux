#!/usr/bin/env bash
# Install the pinned rcodesign (apple-codesign) release binary on a Linux runner.
#
#   scripts/ci/install-rcodesign.sh <dest-dir> >> "$GITHUB_ENV"
#
# Downloads the stock apple-codesign 0.29.0 x86_64-unknown-linux-musl release
# tarball from GitHub, checks it against the sha256 pinned below, installs
# <dest-dir>/rcodesign and prints RCODESIGN=<path> on stdout. Everything else
# goes to stderr, so stdout can be appended to $GITHUB_ENV as is.
#
# The pin is the value published with the release (the tarball's .sha256 asset
# and the release's SHA256SUMS), so a replaced asset fails the check instead of
# signing with unknown code. Bumping the version means replacing both values.
#
# The variable it prints is RCODESIGN, not RCODESIGN_*: rcodesign reads
# RCODESIGN_* environment variables as its own configuration.
set -euo pipefail

RCODESIGN_VERSION=0.29.0
RCODESIGN_SHA256=dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <dest-dir>" >&2
  exit 2
fi
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "install-rcodesign: the pinned build is for x86_64 Linux, not $(uname -s) $(uname -m)" >&2
  exit 2
fi

mkdir -p "$1"
dest="$(cd "$1" && pwd)"
name="apple-codesign-$RCODESIGN_VERSION-x86_64-unknown-linux-musl"
url="https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/$RCODESIGN_VERSION/$name.tar.gz"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --connect-timeout 10 --max-time 120 --retry 5 --retry-delay 2 --retry-all-errors \
  --output "$tmp/rcodesign.tar.gz" "$url"
printf '%s  %s\n' "$RCODESIGN_SHA256" "$tmp/rcodesign.tar.gz" | sha256sum --check --strict --quiet >&2 || {
  echo "install-rcodesign: $name.tar.gz does not match its pinned sha256" >&2
  exit 1
}
tar -xzf "$tmp/rcodesign.tar.gz" -C "$tmp" "$name/rcodesign"
install -m 755 "$tmp/$name/rcodesign" "$dest/rcodesign"
"$dest/rcodesign" --version >&2
echo "RCODESIGN=$dest/rcodesign"
