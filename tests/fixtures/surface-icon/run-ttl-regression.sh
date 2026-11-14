#!/bin/bash
# Compile the production wire parser directly when SwiftPM is unavailable.
set -eu
repo=$(cd "$(dirname "$0")/../../.." && pwd)
root="$repo/Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket"
binary=$(mktemp "${TMPDIR:-/tmp}/cmux-surface-icon-ttl.XXXXXX")
trap 'rm -f "$binary"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$root/Wire/JSONValue.swift" \
  "$root/Coordinator/Surface/ControlSurfaceIconFrame.swift" \
  "$root/Coordinator/Surface/ControlSurfaceIconAsset.swift" \
  "$root/Coordinator/Surface/ControlSurfaceIconInputs.swift" \
  "$root/Coordinator/Surface/ControlSurfaceIconParser.swift" \
  "$repo/tests/fixtures/surface-icon/TTLRegression.swift" -o "$binary"
"$binary"
