#!/bin/bash
# Builds IshKernel.xcframework from vendor/ish (manaflow-ai/ish fork).
#
# Slices: iphoneos arm64 (always), iphonesimulator arm64 (unless
# CMUX_ISH_DEVICE_ONLY=1). Static libs come from iSH's own Xcode targets
# (libish, libish_emu, libfakefs) plus deps/libarchive.xcodeproj; the cmux
# C shim (Packages/iOS/CmuxLocalLinux/ShimSource) and iSH's tools/fakefs.c
# (fakefs_import) are compiled against the iSH headers and merged into one
# IshKernel.a per slice so the Swift package sees a single clean module.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISH="$ROOT/vendor/ish"
SHIM="$ROOT/Packages/iOS/CmuxLocalLinux/ShimSource"
OUT="$ROOT/build/ish-kernel"
CONFIG=Release

[ -f "$ISH/meson.build" ] || { echo "vendor/ish missing; run: git submodule update --init --recursive vendor/ish" >&2; exit 1; }
[ -f "$ISH/deps/libarchive/libarchive/archive.h" ] || { echo "vendor/ish/deps/libarchive missing; run: git -C vendor/ish submodule update --init deps/libarchive" >&2; exit 1; }

SLICES=(iphoneos)
if [ "${CMUX_ISH_DEVICE_ONLY:-0}" != "1" ]; then
  SLICES+=(iphonesimulator)
fi

rm -rf "$OUT"
mkdir -p "$OUT"

for sdk in "${SLICES[@]}"; do
  SYM="$OUT/sym-$sdk"
  for t in libish_emu libfakefs libish; do
    echo "== $t ($sdk)"
    xcodebuild -project "$ISH/iSH.xcodeproj" -target "$t" \
      -sdk "$sdk" -configuration "$CONFIG" CODE_SIGNING_ALLOWED=NO \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
      SYMROOT="$SYM" OBJROOT="$SYM/obj" build | tail -1
  done
  echo "== libarchive ($sdk)"
  xcodebuild -project "$ISH/deps/libarchive.xcodeproj" -target libarchive \
    -sdk "$sdk" -configuration "$CONFIG" CODE_SIGNING_ALLOWED=NO \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    SYMROOT="$SYM" OBJROOT="$SYM/obj" build | tail -1

  SDKPATH="$(xcrun --sdk "$sdk" --show-sdk-path)"
  case "$sdk" in
    iphoneos) TRIPLE="arm64-apple-ios18.0" ;;
    iphonesimulator) TRIPLE="arm64-apple-ios18.0-simulator" ;;
  esac

  mkdir -p "$OUT/$sdk"
  for src in "$SHIM"/*.c "$ISH/tools/fakefs.c"; do
    echo "== shim $(basename "$src") ($sdk)"
    xcrun --sdk "$sdk" clang -c "$src" \
      -target "$TRIPLE" -isysroot "$SDKPATH" -O2 \
      -I"$ISH" -I"$SHIM" -I"$ISH/deps/libarchive/libarchive" \
      -o "$OUT/$sdk/$(basename "${src%.c}").o"
  done

  LIBS=("$SYM/$CONFIG-$sdk"/*.a)
  libtool -static -o "$OUT/$sdk/IshKernel.a" "${LIBS[@]}" "$OUT/$sdk"/*.o 2> >(grep -v "same member name" >&2 || true)
done

HDRS="$OUT/include"
mkdir -p "$HDRS"
cp "$SHIM"/cmux_ish.h "$HDRS/"
cat > "$HDRS/module.modulemap" <<'MODMAP'
module IshKernel {
    header "cmux_ish.h"
    export *
}
MODMAP

FRAMEWORK_ARGS=()
for sdk in "${SLICES[@]}"; do
  FRAMEWORK_ARGS+=(-library "$OUT/$sdk/IshKernel.a" -headers "$HDRS")
done

rm -rf "$ROOT/IshKernel.xcframework"
xcodebuild -create-xcframework "${FRAMEWORK_ARGS[@]}" -output "$ROOT/IshKernel.xcframework"
echo "Built $ROOT/IshKernel.xcframework (slices: ${SLICES[*]})"
