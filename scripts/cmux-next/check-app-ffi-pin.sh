#!/usr/bin/env bash
# Checks the app FFI pin (CCmuxAppFFI: the remote desktop core and the sidebar
# layout reducer over one Rust runtime) in Packages/macOS/CmuxNext/Package.swift.
#
#   scripts/cmux-next/check-app-ffi-pin.sh [--verify-release]
#
# Fails when the FFI sources at HEAD differ from the pinned source sha (the tag
# is cmux-app-ffi-<source sha>): change the Rust code, let
# .github/workflows/app-ffi-release.yml publish the new release, then pin its
# URL and checksum in one commit. With --verify-release it also downloads the
# release's SOURCE_SHA and SHA256SUMS anonymously and fails unless they name
# the pinned sha and the pinned checksum.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$root/Packages/macOS/CmuxNext/Package.swift"
asset="CCmuxAppFFI.xcframework.zip"
paths=(
  cmux-tui/crates/cmux-app-ffi
  cmux-tui/crates/cmux-layout-reducer
  cmux-tui/crates/cmux-layout-reducer-ffi
  cmux-tui/crates/cmux-rd-core
  cmux-tui/crates/cmux-rd-proto
  cmux-tui/crates/cmux-rd-ffi
  cmux-tui/rust-toolchain.toml
  scripts/cmux-next/build-app-ffi.sh
)

url="$(grep -oE "https://github\.com/[^\"]+/releases/download/cmux-app-ffi-[0-9a-f]{40}/${asset//./\\.}" "$manifest" | head -n 1)"
checksum="$(grep -A3 'name: "CCmuxAppFFI"' "$manifest" | grep -oE 'checksum: "[0-9a-f]{64}"' | grep -oE '[0-9a-f]{64}' | head -n 1)"
if [[ -z "$url" || -z "$checksum" ]]; then
  echo "error: no cmux-app-ffi pin (url with a 40-character sha and a 64-character checksum) in $manifest" >&2
  exit 1
fi
sha="$(grep -oE 'cmux-app-ffi-[0-9a-f]{40}' <<<"$url" | sed 's/cmux-app-ffi-//')"

cd "$root"
if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
  git fetch --quiet --depth=1 origin "$sha" || { echo "error: pinned source sha $sha is not available" >&2; exit 1; }
fi
if ! git diff --quiet "$sha" HEAD -- "${paths[@]}"; then
  echo "error: the app FFI sources changed since the pinned source $sha:" >&2
  git diff --stat "$sha" HEAD -- "${paths[@]}" >&2
  echo "Publish a new release (app-ffi-release.yml runs on the push) and pin its URL and checksum in Package.swift." >&2
  exit 1
fi
echo "app FFI pin: sources match $sha"

if [[ "${1:-}" == "--verify-release" ]]; then
  base="${url%/"$asset"}"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  curl -fsSL --retry 3 -o "$work/SOURCE_SHA" "$base/SOURCE_SHA"
  curl -fsSL --retry 3 -o "$work/SHA256SUMS" "$base/SHA256SUMS"
  [[ "$(tr -d '[:space:]' < "$work/SOURCE_SHA")" == "$sha" ]] \
    || { echo "error: release SOURCE_SHA $(cat "$work/SOURCE_SHA") is not the pinned sha $sha" >&2; exit 1; }
  grep -qxF "$checksum  $asset" "$work/SHA256SUMS" \
    || { echo "error: release SHA256SUMS does not carry the pinned checksum $checksum" >&2; exit 1; }
  echo "app FFI pin: release built from $sha with checksum $checksum"
fi
