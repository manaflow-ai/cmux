#!/usr/bin/env bash
# Regenerates the iPhone app's uniffi Swift bindings,
# cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift, from
# cmux-next-ios/rust/crates/cmux-mobile-link-ffi, on Linux or a Mac. It writes only that file.
#
# The file is committed (SwiftPM reads it from git; the xcframework beside it is built), so
# something has to keep it current. This script is that something, and a person never runs it:
#   - a merge: .gitattributes routes the file through cmux-generated-v1, so a merge finishes,
#     and scripts/cmux-next/generated_merge.py regenerate --merge (catch-up, batch merger, a
#     lane's post-merge hook) runs this script on the merged sources;
#   - the base and the pull request: base-autofix.sh --ios-ffi (autofix-areas.sh key iosffi)
#     runs it and the autofix bot commits the result.
# cmux-next-ios-kit.yml's drift check (build-xcframework.sh on a Mac) still compares the copy
# with a Mac build; this script mirrors its bindgen step exactly (the host library in release,
# then `uniffi-bindgen generate --library`), and uniffi's Swift output does not depend on the
# host it reads the library's metadata on.
#
# Usage: scripts/ios-ffi-bindings.sh [--check]
#   (none)   rewrite the file when it differs; prints "fixed: ..." or "unchanged: ..."
#   --check  exit 1 with a unified diff when the committed file differs; writes nothing
# Environment: JOBS (cargo -j; default: every core).
# Cargo.lock is put back as it was: a stale lock is cargo-locks.py's repair, not this one's.
set -euo pipefail

check=0
case "${1:-}" in
  --check) check=1 ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rust_dir="$root/cmux-next-ios/rust"
rel=cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift
dest="$root/$rel"
jobs="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
case "$(uname -s)" in
  Darwin) lib=libcmux_mobile_link_ffi.dylib ;;
  *) lib=libcmux_mobile_link_ffi.so ;;
esac

command -v cargo >/dev/null 2>&1 || { echo "error: $0 needs cargo (rustup reads cmux-next-ios/rust/rust-toolchain.toml)" >&2; exit 1; }

work="$(mktemp -d)"
cp "$rust_dir/Cargo.lock" "$work/Cargo.lock"
restore_lock() { cmp -s "$work/Cargo.lock" "$rust_dir/Cargo.lock" || cp "$work/Cargo.lock" "$rust_dir/Cargo.lock"; }
trap 'restore_lock; rm -rf "$work"' EXIT

cd "$rust_dir"
# Ask cargo where it builds: CI sets CARGO_TARGET_DIR (or a config file does), so target/ is a guess.
target_dir="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
cargo build --release -j "$jobs" -p cmux-mobile-link-ffi --lib >&2
cargo run --release -j "$jobs" -p cmux-mobile-link-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library "$target_dir/release/$lib" --language swift --out-dir "$work/out" >&2
generated="$work/out/CmuxMobileLinkFFI.swift"
[[ -s "$generated" ]] || { echo "error: uniffi-bindgen wrote no CmuxMobileLinkFFI.swift" >&2; exit 1; }

if cmp -s "$generated" "$dest"; then
  echo "unchanged: $rel"
  exit 0
fi
if (( check )); then
  diff -u --label "a/$rel" --label "b/$rel" "$dest" "$generated" || true
  echo "error: $rel differs from what cmux-mobile-link-ffi generates; the base autofix regenerates it (scripts/ios-ffi-bindings.sh)" >&2
  exit 1
fi
mkdir -p "$(dirname "$dest")"
cp "$generated" "$dest"
echo "fixed: regenerated $rel (scripts/ios-ffi-bindings.sh)"
