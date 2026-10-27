#!/usr/bin/env bash
# Build the rcodesign that signs the cmux NEXT DEV tip DMG the way codesign does.
#
#   scripts/ci/build-rcodesign-dmg.sh <dest-dir>
#
# Stock rcodesign 0.29.0 (the newest release; main is the same) signs a DMG
# with a 0x20100 Code Directory, no team identifier and an empty requirement
# set, while codesign writes a 0x20200 Code Directory with the certificate's
# team and the explicit designated requirement (for Developer ID:
# identifier "..." and anchor apple generic and the Developer ID OIDs and
# leaf[subject.OU] = TEAM). scripts/ci/rcodesign-0.29.0-dmg.patch makes
# rcodesign's DMG signer do what its Mach-O signer already does: take the
# team from the settings (set from an Apple-issued signing certificate) and
# derive the designated requirement from the certificate. With it, the Code
# Directory and requirement set of a DMG it signs are byte for byte the ones
# codesign writes; only the CMS signature (signing time, signature bytes)
# differs. Upstream: https://github.com/indygreg/apple-platform-rs/issues/370.
#
# The source is the apple-codesign 0.29.0 crate from crates.io, checked
# against the sha256 the crates.io index publishes, built with its own
# Cargo.lock (--locked). The binary goes to <dest-dir>/rcodesign; its sha256
# is printed on stdout as sha256=<hex> (for $GITHUB_OUTPUT), everything else
# goes to stderr.
set -euo pipefail

CRATE_VERSION=0.29.0
CRATE_SHA256=f24e9ebdb70a2aee3ca1cea217009fb50776955f0d7678c31d22e48c1524667f
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$SCRIPT_DIR/rcodesign-$CRATE_VERSION-dmg.patch"

[[ $# -eq 1 ]] || { echo "usage: $0 <dest-dir>" >&2; exit 2; }
[[ -f "$PATCH" ]] || { echo "error: $PATCH is missing" >&2; exit 1; }
command -v cargo >/dev/null || { echo "error: cargo not found" >&2; exit 1; }
mkdir -p "$1"
dest="$(cd "$1" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --connect-timeout 10 --max-time 120 --retry 5 --retry-delay 2 --retry-all-errors \
  --output "$work/crate.tar.gz" "https://static.crates.io/crates/apple-codesign/$CRATE_VERSION/download"
if command -v sha256sum >/dev/null; then
  printf '%s  %s\n' "$CRATE_SHA256" "$work/crate.tar.gz" | sha256sum --check --strict --quiet >&2
else
  printf '%s  %s\n' "$CRATE_SHA256" "$work/crate.tar.gz" | shasum -a 256 --check --strict --quiet >&2
fi || { echo "error: apple-codesign-$CRATE_VERSION.crate does not match its pinned sha256" >&2; exit 1; }
tar -xzf "$work/crate.tar.gz" -C "$work"
src="$work/apple-codesign-$CRATE_VERSION"
patch --batch --forward --silent -p1 -d "$src" < "$PATCH" >&2

CARGO_TARGET_DIR="$work/target" cargo build --release --locked --bin rcodesign \
  --manifest-path "$src/Cargo.toml" >&2
install -m 755 "$work/target/release/rcodesign" "$dest/rcodesign"
"$dest/rcodesign" --version >&2
if command -v sha256sum >/dev/null; then
  digest="$(sha256sum "$dest/rcodesign" | cut -d' ' -f1)"
else
  digest="$(shasum -a 256 "$dest/rcodesign" | cut -d' ' -f1)"
fi
echo "sha256=$digest"
