#!/usr/bin/env bash
# release-env.sh [--print]
#
# The PGO setup that every cmux-next Release build shares (plans/cmux-next/chrome-parity/p08-startup.md, section F,
# task 052): check-release-compile.sh sources it, and the Nightly's Release build gets it through
# scripts/ci/run-with-helper-prebuild.py, which runs it with --print.
#
# The switch and task 110's companions come from Resources/build/cmux-next.pgo.conf (`use=0|1`,
# `companions=thinlto,cmo`). CMUX_NEXT_PGO_USE and CMUX_PGO_COMPANIONS in the environment override the file for
# one build; CMUX_PGO_CONF names another file. With the switch on, pgo/fetch-profdata.sh fetches the pinned
# profile by sha256 and its path becomes CMUX_PGO_PROFDATA, the variable Package.swift reads; the companions go
# along only with the profile, as Chrome ships PGO only on ThinLTO builds (docs/pgo.md). An ambient
# CMUX_PGO_PROFDATA or CMUX_PGO_COMPANIONS never reaches the build.
#
# Sourced: `cmux_pgo_release_env` exports CMUX_PGO_PROFDATA and CMUX_PGO_COMPANIONS (or unsets them) and sets
# CMUX_PGO_BUILD_SETTINGS (xcodebuild settings: LLVM_LTO=YES_THIN for thinlto) and CMUX_PGO_LABEL (for the log).
# --print: one line per result, `export NAME=VALUE` or `setting NAME=VALUE`, on stdout.
# Status goes to stderr. Exit 0 also when PGO is on but no profile matches the pin (the build is the plain
# Release); exit 2 for a bad switch or companion value.

cmux_pgo_conf_value() { # KEY FILE: the last `KEY=value` line of FILE, comments skipped
  [[ -f "$2" ]] || return 0
  awk -v key="$1" '
    /^[[:space:]]*(#|$)/ { next }
    { split($0, kv, "="); if (kv[1] == key) { value = substr($0, length(key) + 2) } }
    END { gsub(/[[:space:]]/, "", value); printf "%s", value }
  ' "$2"
}

cmux_pgo_warn() {
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    echo "::warning::pgo: $*" >&2
  else
    echo "pgo: $*" >&2
  fi
}

cmux_pgo_release_env() {
  local pgo_dir conf use companions companion profdata
  local -a companion_list
  pgo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  conf="${CMUX_PGO_CONF:-$pgo_dir/../../../Resources/build/cmux-next.pgo.conf}"
  use="${CMUX_NEXT_PGO_USE-$(cmux_pgo_conf_value use "$conf")}"
  companions="${CMUX_PGO_COMPANIONS-$(cmux_pgo_conf_value companions "$conf")}"
  unset CMUX_PGO_PROFDATA CMUX_PGO_COMPANIONS
  CMUX_PGO_BUILD_SETTINGS=()
  CMUX_PGO_LABEL=''

  IFS=, read -r -a companion_list <<<"$companions"
  for companion in "${companion_list[@]+"${companion_list[@]}"}"; do
    case "$companion" in
      thinlto|cmo) ;;
      *) echo "pgo: companions take thinlto and cmo, got '$companion'" >&2; return 2 ;;
    esac
  done
  case "$use" in
    1) ;;
    0|'') echo "pgo: off (use=${use:-unset}); compiling the plain Release" >&2; return 0 ;;
    *) echo "pgo: the switch takes 0 or 1, got '$use'" >&2; return 2 ;;
  esac

  if ! profdata="$("$pgo_dir/fetch-profdata.sh")"; then
    cmux_pgo_warn "PGO is on but no profile matches the pin; compiling the plain Release"
    return 0
  fi
  export CMUX_PGO_PROFDATA="$profdata"
  CMUX_PGO_LABEL=", PGO $profdata"
  if [[ -n "$companions" ]]; then
    export CMUX_PGO_COMPANIONS="$companions"
    CMUX_PGO_LABEL+=" with $companions"
    # ThinLTO needs the link too; the Swift flag comes from Package.swift (lto-ab.sh's thinlto variant).
    if [[ ",$companions," == *,thinlto,* ]]; then
      CMUX_PGO_BUILD_SETTINGS+=(LLVM_LTO=YES_THIN)
    fi
  fi
  echo "pgo: on$CMUX_PGO_LABEL" >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  case "${1:-}" in
    --print) ;;
    *) echo "usage: release-env.sh --print (or source it and call cmux_pgo_release_env)" >&2; exit 2 ;;
  esac
  cmux_pgo_release_env
  for name in CMUX_PGO_PROFDATA CMUX_PGO_COMPANIONS; do
    if [[ -n "${!name:-}" ]]; then
      printf 'export %s=%s\n' "$name" "${!name}"
    fi
  done
  for setting in "${CMUX_PGO_BUILD_SETTINGS[@]+"${CMUX_PGO_BUILD_SETTINGS[@]}"}"; do
    printf 'setting %s\n' "$setting"
  done
fi
