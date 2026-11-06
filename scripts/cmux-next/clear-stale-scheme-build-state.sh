#!/usr/bin/env bash
# Remove Xcode state that can retain absolute references to stale explicit PCMs.
# Keep only SourcePackages (downloaded sources); every build output can name a PCM.
set -euo pipefail

derived_data="${1:?usage: clear-stale-scheme-build-state.sh DERIVED_DATA}"
refuse() { echo "refusing ${1:-unexpected} DerivedData path: $derived_data" >&2; exit 2; }
[[ "$derived_data" == /* ]] || refuse "a relative"
case "/$derived_data/" in */../*|*/./*) refuse "a . or .. segment in a" ;; esac
# This gates an rm -rf: judge the path where it resolves, so a link under an accepted root (or
# named like one) cannot aim the clear elsewhere. A missing path resolves through its parent.
resolve() {
  if [[ -d "$1" ]]; then (cd -P -- "$1" && pwd -P)
  elif [[ -d "$(dirname -- "$1")" ]]; then
    local parent; parent="$(cd -P -- "$(dirname -- "$1")" && pwd -P)"
    printf '%s/%s\n' "${parent%/}" "$(basename -- "$1")"
  else printf '%s\n' "$1"
  fi
}
derived_data="$(resolve "$derived_data")"
# Runners outside the glaeda pools build in $RUNNER_TEMP: release-derived-data-path.sh
# gives $RUNNER_TEMP/cmux-next-<lane>, and the scheme compile job uses
# $RUNNER_TEMP/cmux-scheme-compile. Hosted macOS keeps RUNNER_TEMP under
# /Users/runner/_work/_temp, not /tmp; refusing it failed every Release compile there.
# RUNNER_TEMP counts only as an absolute directory that resolves at least three levels down
# (runners use /Users/runner/_work/_temp): /, /var (/private/var) or a home directory would
# accept a whole tree.
runner_temp=""
if [[ "${RUNNER_TEMP:-}" == /* && -d "$RUNNER_TEMP" ]]; then
  runner_temp="$(resolve "$RUNNER_TEMP")"
  [[ "$runner_temp" == /?*/?*/?* ]] || runner_temp=""
fi
# The fleet compile cache's canonical Release root (release-compile-fleet-cas.sh exports it):
# only its DerivedData, and only for a root that resolves at least three levels down.
cas_root=""
if [[ "${CMUX_NEXT_RELEASE_CAS_ROOT:-}" == /* && -d "$CMUX_NEXT_RELEASE_CAS_ROOT" ]]; then
  cas_root="$(resolve "$CMUX_NEXT_RELEASE_CAS_ROOT")"
  [[ "$cas_root" == /?*/?*/?* ]] || cas_root=""
fi
if [[ -n "$runner_temp" && ( "$derived_data" == "$runner_temp"/cmux-next-* || "$derived_data" == "$runner_temp"/cmux-scheme-compile ) ]]; then
  :
elif [[ -n "$cas_root" && "$derived_data" == "$cas_root/DerivedData" ]]; then
  :
else
  case "$derived_data" in
    /tmp/?*|/private/tmp/?*|*/Library/Caches/cmux-next-ci/?*) ;;
    *) refuse ;;
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
