#!/bin/bash
# Builds the iroh FFI staticlib and the Swift harness.
#
#   ./build.sh macos      # aarch64-apple-darwin staticlib + macOS Swift harness
#   ./build.sh ios-sim    # aarch64-apple-ios-sim staticlib + iOS-simulator Swift harness
#
# Artifacts land in ./out/ (gitignored). No binaries are committed.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p out

target_kind="${1:-macos}"

case "$target_kind" in
macos)
    rust_target="aarch64-apple-darwin"
    sdk="macosx"
    swift_target="arm64-apple-macos14.0"
    frameworks=(-framework SystemConfiguration -framework CoreWLAN -framework Security)
    ;;
ios-sim)
    rust_target="aarch64-apple-ios-sim"
    sdk="iphonesimulator"
    swift_target="arm64-apple-ios17.0-simulator"
    # netdev (iroh's interface enumeration) uses Network.framework nw_path_monitor on iOS.
    frameworks=(-framework SystemConfiguration -framework Security -framework Network)
    ;;
*)
    echo "usage: $0 [macos|ios-sim]" >&2
    exit 2
    ;;
esac

echo "==> cargo build --release --target $rust_target"
(cd rust && cargo build --release --target "$rust_target")

lib="rust/target/$rust_target/release/libcmux_iroh_ffi.a"
ls -lh "$lib"

out="out/swift-harness-$target_kind"
echo "==> swiftc -> $out"
xcrun -sdk "$sdk" swiftc \
    -target "$swift_target" \
    -O \
    -import-objc-header include/cmux_iroh_ffi.h \
    swift/main.swift \
    "$lib" \
    "${frameworks[@]}" \
    -o "$out"

ls -lh "$out"
echo "==> done: $out"
