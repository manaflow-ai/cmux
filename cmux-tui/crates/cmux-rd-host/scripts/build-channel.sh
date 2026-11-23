#!/usr/bin/env bash
# Build cmux-rd for the files.cmux.com channel, beside acpmux: one cargo group of
# cmux-tui-build-package.yml's "Build cmux-tui (Linux cross)" on a Linux musl leg
# (input build_cmux_rd), run by scripts/ci/cargo-groups.sh, which sets CARGO_TARGET_DIR.
#
# usage: build-channel.sh LEG_TRIPLE
#
# LEG_TRIPLE is the leg's triple, x86_64-unknown-linux-musl or aarch64-unknown-linux-musl.
# cmux-rd loads Cisco's OpenH264 with dlopen, so it is a glibc binary: it builds for the
# leg's gnu triple, linked by Zig against the glibc floor (a symbol newer than the floor
# does not link), with the release features of cmux-rd-release.yml: OpenH264 downloaded on
# the machine and the device hub link, no bench, no x264 (tests/release_features.rs checks
# FEATURES below; release.py RELEASE_FEATURES names the same). Writes cmux-rd and
# cmux-rd-notices.md (release.py notices, after its license gate) to
# $CARGO_TARGET_DIR/LEG_TRIPLE/release, where cargo-groups.sh gathers a group's files:
# both, or neither when any part fails.
set -euo pipefail

FEATURES=openh264,link
GLIBC_FLOOR=2.31

leg=${1:-}
case "$leg" in
  x86_64-unknown-linux-musl | aarch64-unknown-linux-musl) ;;
  *)
    echo "usage: $0 x86_64-unknown-linux-musl|aarch64-unknown-linux-musl" >&2
    exit 2
    ;;
esac
: "${CARGO_TARGET_DIR:?build-channel.sh: CARGO_TARGET_DIR unset (cargo-groups.sh sets it)}"
target=${leg%-musl}-gnu
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$(dirname "$scripts")/Cargo.toml"
out="$CARGO_TARGET_DIR/$leg/release"
ref="${CMUX_TUI_BUILD_COMMIT:-$(git -C "$scripts" rev-parse HEAD)}"
tmp="$(mktemp -d)"
done=""
cleanup() {
  rm -rf "$tmp"
  [[ -n "$done" ]] || rm -f "$out/cmux-rd" "$out/cmux-rd-notices.md"
}
trap cleanup EXIT
rm -f "$out/cmux-rd" "$out/cmux-rd-notices.md"

rustup target add "$target"
# The release profile keeps `debug = 1` for cmux-rd-release.yml; the channel binary drops the
# DWARF and keeps the symbol table (backtraces still name functions): 32.8 MB to 6.0 MB on
# x86_64, measured on the published tree f65972f9 with `strip --strip-debug` (CMUX-570).
CARGO_PROFILE_RELEASE_STRIP=debuginfo CMUX_BUILD_SHA="$ref" cargo zigbuild --release --locked --manifest-path "$manifest" \
  --no-default-features --features "$FEATURES" --bin cmux-rd --target "$target.$GLIBC_FLOOR"

# The license gate and the notices read one crate list (release.py linked_crates, from
# `cargo metadata`): a crate the gate stops writes no notices, and so no cmux-rd.
python3 "$scripts/release.py" notices --target "$target" --ref "$ref" \
  --out "$tmp/notices.md" --cache "${RUNNER_TEMP:-$tmp}/cmux-rd-notices-cache"

mkdir -p "$out"
install -m 644 "$tmp/notices.md" "$out/cmux-rd-notices.md"
install -m 755 "$CARGO_TARGET_DIR/$target/release/cmux-rd" "$out/cmux-rd"
done=1
echo "build-channel.sh: cmux-rd for $target (glibc $GLIBC_FLOOR, features $FEATURES) in $out"
