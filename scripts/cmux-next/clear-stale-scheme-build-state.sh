#!/usr/bin/env bash
# Remove Xcode state that can retain absolute references to stale explicit PCMs.
# Keep Products and SourcePackages so the retry does not discard reusable outputs.
set -euo pipefail

derived_data="${1:?usage: clear-stale-scheme-build-state.sh DERIVED_DATA}"
case "$derived_data" in
  /tmp/*|/private/tmp/*|*/Library/Caches/cmux-next-ci/*) ;;
  *) echo "refusing unexpected DerivedData path: $derived_data" >&2; exit 2 ;;
esac

rm -rf -- \
  "$derived_data/ModuleCache.noindex" \
  "$derived_data/Build/Intermediates.noindex/ExplicitPrecompiledModules" \
  "$derived_data/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules" \
  "$derived_data/Build/Intermediates.noindex/XCBuildData"
