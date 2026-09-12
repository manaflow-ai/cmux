#!/usr/bin/env bash
set -euo pipefail

# Ghostty's Zig build invokes Apple's `metal` compiler for every macOS and iOS
# slice. Some Blacksmith images ship Xcode without the separately downloadable
# Metal Toolchain, so xcrun finds the tool name but the compiler fails at build
# time. Make the fallback self-healing and keep this a no-op on Linux.
if [[ "$(uname -s)" != "Darwin" ]]; then
  exit 0
fi

if xcrun --sdk macosx metal -v >/dev/null 2>&1; then
  echo "Metal Toolchain is available"
  exit 0
fi

echo "Metal Toolchain is missing; downloading it for the selected Xcode..."
xcodebuild -downloadComponent MetalToolchain

if ! xcrun --sdk macosx metal -v >/dev/null 2>&1; then
  echo "error: Metal Toolchain is still unavailable after download" >&2
  exit 1
fi
echo "Metal Toolchain is ready"
