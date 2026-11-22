#!/usr/bin/env bash
# A stale PCM retry must remove every derived build state that can name the
# deleted PCM (module caches, intermediates, products, stat caches: a retry
# that kept Build/Products failed again on the same missing Darwin PCM, e.g.
# cmux-next.yml run 37308680992), keeping only the package checkouts; and
# retries that report a missing serialized module scan count as stale.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEANUP="$ROOT_DIR/scripts/cmux-next/clear-stale-scheme-build-state.sh"
DETECT="$ROOT_DIR/scripts/cmux-next/stale-pcm-retry-needed.sh"
tmp="$(mktemp -d /tmp/cmux-stale-pcm.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/ModuleCache.noindex" \
  "$tmp/Build/Intermediates.noindex/ExplicitPrecompiledModules" \
  "$tmp/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules" \
  "$tmp/Build/Intermediates.noindex/XCBuildData" \
  "$tmp/Build/Intermediates.noindex/OtherStaleState" \
  "$tmp/Build/Products" "$tmp/SDKStatCaches.noindex" "$tmp/SourcePackages"
touch "$tmp/ModuleCache.noindex/old.pcm" \
  "$tmp/Build/Intermediates.noindex/ExplicitPrecompiledModules/old.pcm" \
  "$tmp/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/old.pcm" \
  "$tmp/Build/Intermediates.noindex/XCBuildData/build.db" \
  "$tmp/Build/Intermediates.noindex/OtherStaleState/old.dat" \
  "$tmp/Build/Products/old.swiftmodule" "$tmp/SDKStatCaches.noindex/old.sdkstatcache" \
  "$tmp/SourcePackages/keep"

"$CLEANUP" "$tmp"

for removed in \
  "$tmp/ModuleCache.noindex" \
  "$tmp/Build" \
  "$tmp/SDKStatCaches.noindex"; do
  test ! -e "$removed" || { echo "FAIL: stale build state remains: $removed" >&2; exit 1; }
done
for kept in "$tmp/SourcePackages/keep"; do
  test -e "$kept" || { echo "FAIL: cleanup removed reusable state: $kept" >&2; exit 1; }
done
echo "PASS: stale PCM cleanup removes all derived build state but the package checkouts"

log="$tmp/reload.log"
printf "error: Failed to query serialized dependencies at '%s/Build/Intermediates.noindex/ExplicitPrecompiledModules/_Builtin_intrinsics.scan'\n" "$tmp" >"$log"
"$DETECT" "$log"
printf "Sources/App.swift:1: error: cannot find 'x' in scope\n" >"$log"
if "$DETECT" "$log"; then
  echo "FAIL: ordinary compile failure requested stale retry" >&2
  exit 1
fi
echo "PASS: missing serialized module scans request the stale retry"
