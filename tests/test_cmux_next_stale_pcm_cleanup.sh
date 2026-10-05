#!/usr/bin/env bash
# A stale PCM retry must remove the build graph that names the deleted PCM,
# including retries that report a missing serialized module scan.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEANUP="$ROOT_DIR/scripts/cmux-next/clear-stale-scheme-build-state.sh"
DETECT="$ROOT_DIR/scripts/cmux-next/stale-pcm-retry-needed.sh"
tmp="$(TMPDIR=/tmp mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/ModuleCache.noindex" \
  "$tmp/Build/Intermediates.noindex/ExplicitPrecompiledModules" \
  "$tmp/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules" \
  "$tmp/Build/Intermediates.noindex/XCBuildData" \
  "$tmp/Build/Intermediates.noindex/OtherStaleState" \
  "$tmp/Build/Products" "$tmp/SourcePackages"
touch "$tmp/ModuleCache.noindex/old.pcm" \
  "$tmp/Build/Intermediates.noindex/ExplicitPrecompiledModules/old.pcm" \
  "$tmp/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/old.pcm" \
  "$tmp/Build/Intermediates.noindex/XCBuildData/build.db" \
  "$tmp/Build/Intermediates.noindex/OtherStaleState/old.dat" \
  "$tmp/Build/Products/keep" "$tmp/SourcePackages/keep"

"$CLEANUP" "$tmp"

for removed in \
  "$tmp/ModuleCache.noindex" \
  "$tmp/Build/Intermediates.noindex"; do
  test ! -e "$removed" || { echo "FAIL: stale build state remains: $removed" >&2; exit 1; }
done
for kept in "$tmp/Build/Products/keep" "$tmp/SourcePackages/keep"; do
  test -e "$kept" || { echo "FAIL: cleanup removed reusable state: $kept" >&2; exit 1; }
done
echo "PASS: stale PCM cleanup removes module caches and XCBuildData only"

log="$tmp/reload.log"
printf "error: Failed to query serialized dependencies at '%s/Build/Intermediates.noindex/ExplicitPrecompiledModules/_Builtin_intrinsics.scan'\n" "$tmp" >"$log"
"$DETECT" "$log"
printf "Sources/App.swift:1: error: cannot find 'x' in scope\n" >"$log"
if "$DETECT" "$log"; then
  echo "FAIL: ordinary compile failure requested stale retry" >&2
  exit 1
fi
echo "PASS: missing serialized module scans request the stale retry"
