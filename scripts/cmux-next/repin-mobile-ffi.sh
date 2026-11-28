#!/usr/bin/env bash
# Points Packages/Shared/CmuxMobileFFI at a published cmux-mobile-ffi release.
#
#   scripts/cmux-next/repin-mobile-ffi.sh SOURCE_SHA CHECKSUM
#
# Downloads the release's SHA256SUMS and CmuxMobileFFI.swift (the uniffi
# bindings generated from the same build as the xcframework) anonymously,
# refuses unless SHA256SUMS carries CHECKSUM for the zip and the bindings'
# digest, then writes the pin file (scripts/cmux-next/mobile_ffi_pin.py write)
# and the bindings beside it. The bindings must match the library (uniffi checks
# its contract version and API checksums at load), so the two always move in one
# commit. cmux-mobile-ffi.yml's repin job runs it (publish-mobile-ffi-repin.sh);
# scripts/cmux-next/check-mobile-ffi-pin.sh reads what it wrote.
set -euo pipefail

sha="${1:-}"
checksum="${2:-}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: SOURCE_SHA must be a 40-character commit, got '$sha'" >&2; exit 2; }
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || { echo "error: CHECKSUM must be 64 hex characters, got '$checksum'" >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$root/Packages/Shared/CmuxMobileFFI"
base="${CMUX_MOBILE_FFI_RELEASE_BASE:-https://github.com/manaflow-ai/cmux/releases/download}/cmux-mobile-ffi-$sha"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
get() { curl -fsSL --connect-timeout 15 --max-time 120 --retry 5 --retry-all-errors --retry-delay 3 -o "$1" "$2"; }
get "$work/SHA256SUMS" "$base/SHA256SUMS"
get "$work/CmuxMobileFFI.swift" "$base/CmuxMobileFFI.swift"
grep -qxF "$checksum  CmuxMobileFFIFFI.xcframework.zip" "$work/SHA256SUMS" \
  || { echo "error: release cmux-mobile-ffi-$sha does not carry checksum $checksum" >&2; exit 1; }
(cd "$work" && grep -E '  CmuxMobileFFI\.swift$' SHA256SUMS | shasum -a 256 -c -) >/dev/null \
  || { echo "error: release cmux-mobile-ffi-$sha: CmuxMobileFFI.swift does not match its SHA256SUMS" >&2; exit 1; }

mkdir -p "$package/Sources/CmuxMobileFFI"
cp "$work/CmuxMobileFFI.swift" "$package/Sources/CmuxMobileFFI/CmuxMobileFFI.swift"
python3 -I "$root/scripts/cmux-next/mobile_ffi_pin.py" write "$sha" "$checksum" "$package/mobile-ffi-pin.json"
echo "pinned CmuxMobileFFIFFI to cmux-mobile-ffi-$sha ($checksum)"
