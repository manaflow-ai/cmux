#!/usr/bin/env bash
# Remove Xcode state that can retain absolute references to stale explicit PCMs.
# Keep only SourcePackages (downloaded sources); every build output can name a PCM.
set -euo pipefail

derived_data="${1:?usage: clear-stale-scheme-build-state.sh DERIVED_DATA}"
# release-derived-data-path.sh gives runners outside the glaeda pools
# $RUNNER_TEMP/cmux-next-<lane>, which is not under /tmp on hosted macOS runners
# (/Users/runner/_work/_temp). Refusing it failed every Release compile there.
if [[ -n "${RUNNER_TEMP:-}" && "$derived_data" == "$RUNNER_TEMP"/cmux-next-* ]]; then
  :
else
  case "$derived_data" in
    /tmp/*|/private/tmp/*|*/Library/Caches/cmux-next-ci/*) ;;
    *) echo "refusing unexpected DerivedData path: $derived_data" >&2; exit 2 ;;
  esac
fi

# Everything derived goes except the package checkouts: a retry that kept
# Build/Products failed again on the same missing PCM. SourcePackages only
# holds downloaded sources, which name no build output.
shopt -s dotglob nullglob
for entry in "$derived_data"/*; do
  # The binary-module guard's header digest (scripts/ci/swiftpm-binary-module-guard.sh)
  # stays valid: this removes stale modules, not a change of headers.
  case "$(basename "$entry")" in SourcePackages|.cmux-binary-module-inputs) continue ;; esac
  rm -rf -- "$entry"
done
