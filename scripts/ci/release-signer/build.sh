#!/usr/bin/env bash
# Builds the release signer: the apple-codesign 0.29.0 crate with our patch.
#
#   scripts/ci/release-signer/build.sh <dest-dir>
#
# Source: the crate from crates.io, checked against its pinned sha256, with
# apple-codesign-0.29.0.patch (beside this script; byte for byte the patch
# main's DEV signer uses) applied, built with the crate's own
# Cargo.lock (--locked). The binary goes to <dest-dir>/rcodesign; its sha256 is
# printed on stdout as sha256=<hex> (for $GITHUB_OUTPUT), everything else goes
# to stderr. Not used by any workflow yet.

set -euo pipefail

CRATE_VERSION=0.29.0
CRATE_SHA256=f24e9ebdb70a2aee3ca1cea217009fb50776955f0d7678c31d22e48c1524667f
# The patch is pinned too: a changed patch changes the signer.
PATCH_SHA256=7b20e1346db84a21a9fd1d55743a9fd9b950cd324b03906daa5163e33db96417
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$SCRIPT_DIR/apple-codesign-$CRATE_VERSION.patch"

[[ $# -eq 1 ]] || { echo "usage: $0 <dest-dir>" >&2; exit 2; }
[[ -f "$PATCH" ]] || { echo "error: $PATCH is missing" >&2; exit 1; }
command -v cargo >/dev/null || { echo "error: cargo not found" >&2; exit 1; }
# shellcheck source=signer-env.sh
source "$SCRIPT_DIR/signer-env.sh"
mkdir -p "$1"
dest="$(cd "$1" && pwd)"

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
[[ "$(sha256_of "$PATCH")" == "$PATCH_SHA256" ]] ||
  { echo "error: $PATCH does not match its pinned sha256" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --connect-timeout 10 --max-time 120 --retry 5 --retry-delay 2 --retry-all-errors \
  --output "$work/crate.tar.gz" "https://static.crates.io/crates/apple-codesign/$CRATE_VERSION/download"
[[ "$(sha256_of "$work/crate.tar.gz")" == "$CRATE_SHA256" ]] ||
  { echo "error: apple-codesign-$CRATE_VERSION.crate does not match its pinned sha256" >&2; exit 1; }
tar -xzf "$work/crate.tar.gz" -C "$work"
src="$work/apple-codesign-$CRATE_VERSION"
patch --batch --forward --silent -p1 -d "$src" < "$PATCH" >&2

CARGO_TARGET_DIR="$work/target" cargo build --release --locked --bin rcodesign \
  --manifest-path "$src/Cargo.toml" >&2
install -m 755 "$work/target/release/rcodesign" "$dest/rcodesign"
run_signer "$dest/rcodesign" --version >&2
echo "sha256=$(sha256_of "$dest/rcodesign")"
