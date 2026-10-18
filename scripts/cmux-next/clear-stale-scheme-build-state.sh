#!/usr/bin/env bash
# Remove Xcode state that can retain absolute references to stale explicit PCMs.
# Keep only SourcePackages (downloaded sources); every build output can name a PCM.
set -euo pipefail

derived_data="${1:?usage: clear-stale-scheme-build-state.sh DERIVED_DATA}"
refuse() { echo "refusing unexpected DerivedData path: $derived_data${1:+ ($1)}" >&2; exit 2; }
[[ "$derived_data" == /* ]] || refuse "not absolute"
case "/$derived_data/" in */../*|*/./*) refuse "a . or .. segment" ;; esac
# Judge an existing path where it points: a link must not aim the rm elsewhere.
[[ ! -d "$derived_data" ]] || derived_data="$(cd -P -- "$derived_data" && pwd -P)"
# RUNNER_TEMP is the hosted and Blacksmith lanes' DerivedData root
# (cmux-next.yml, release-derived-data-path.sh); Blacksmith keeps it between jobs.
runner_temp=""
if [[ "${RUNNER_TEMP:-}" == /?* && -d "$RUNNER_TEMP" ]]; then
  runner_temp="$(cd -P -- "$RUNNER_TEMP" && pwd -P)"
  [[ "$runner_temp" != / ]] || runner_temp=""
fi
case "$derived_data" in
  /tmp/?*|/private/tmp/?*|*/Library/Caches/cmux-next-ci/?*) ;;
  *) [[ -n "$runner_temp" && "$derived_data" == "$runner_temp"/?* ]] || refuse ;;
esac

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
