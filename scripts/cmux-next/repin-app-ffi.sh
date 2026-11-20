#!/usr/bin/env bash
# Points the CCmuxAppFFI binary target at a published app FFI release.
#
#   scripts/cmux-next/repin-app-ffi.sh SOURCE_SHA CHECKSUM [app-ffi-pin.json [Package.swift]]
#
# Rewrites the pin file's release URL (tag cmux-app-ffi-SOURCE_SHA) and SwiftPM
# checksum through scripts/ci/app_ffi_pin.py, in its one format, and the one
# checksum comment line of Package.swift's loader block (SwiftPM caches the
# manifest by its text, so a re-pin must change it): only when both are already
# canonical, else it refuses. Nothing else in Package.swift is written.
# app-ffi-release.yml's repin job runs it after a publish;
# scripts/cmux-next/check-app-ffi-pin.sh reads the same two fields.
set -euo pipefail

sha="${1:-}"
checksum="${2:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pin_file="${3:-$root/Packages/macOS/CmuxNext/app-ffi-pin.json}"
manifest="${4:-$(dirname "$pin_file")/Package.swift}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: SOURCE_SHA must be a 40-character commit, got '$sha'" >&2; exit 2; }
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || { echo "error: CHECKSUM must be 64 hex characters, got '$checksum'" >&2; exit 2; }

python3 "$root/scripts/ci/app_ffi_pin.py" rewrite "$sha" "$checksum" "$pin_file" "$manifest"
echo "pinned CCmuxAppFFI to cmux-app-ffi-$sha ($checksum)"
