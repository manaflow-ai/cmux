#!/usr/bin/env bash
# Remove Xcode state that can retain absolute references to stale explicit PCMs.
# Keep only SourcePackages (downloaded sources); every build output can name a PCM.
set -euo pipefail

derived_data="${1:?usage: clear-stale-scheme-build-state.sh DERIVED_DATA}"
case "$derived_data" in
  /tmp/*|/private/tmp/*|*/Library/Caches/cmux-next-ci/*) ;;
  *) echo "refusing unexpected DerivedData path: $derived_data" >&2; exit 2 ;;
esac

# Everything derived goes except the package checkouts: a retry that kept
# Build/Products failed again on the same missing PCM. SourcePackages only
# holds downloaded sources, which name no build output.
shopt -s dotglob nullglob
for entry in "$derived_data"/*; do
  [[ "$(basename "$entry")" == SourcePackages ]] && continue
  rm -rf -- "$entry"
done
