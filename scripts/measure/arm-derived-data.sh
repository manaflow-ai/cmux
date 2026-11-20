#!/usr/bin/env bash
# Sourced by a measure script that builds two commits one after the other in one checkout (base, then head): each
# arm gets its own DerivedData, so a generated FFI header that changed between the commits cannot meet a precompiled
# Swift module the other arm built ("file '.../cmux_layout_reducer_ffi.h' has been modified since the module file
# '.../SwiftExplicitPrecompiledModules/CCmuxLayoutReducerFFI-*.pcm' was built", exit 65: the head arm of the
# CMUX-571 memory A/B, 2026-11-17, after about 7 h in the queue).
#
#   CMUX_DERIVED_DATA="$(measure_arm_derived_data ARM)" ./scripts/reload.sh --tag TAG ...
# prints the checkout's .build/DerivedData/cmux-measure for the head arm (or no arm), which a fleet worker keeps
# warm between steps and which stays the build the checkout itself would make, and
# .build/DerivedData/cmux-measure-ARM for any other arm (base, at-<sha12>, ...). A script must source this file
# before it checks out its first arm: a base commit that predates the file has none to source.
# tests/arm-derived-data.test.py is the detector: it fails for a measure script that checks out an arm and runs
# reload.sh without one of these.

measure_arm_derived_data() {
  local arm="${1:-head}" root
  root="$(git rev-parse --show-toplevel)" || return 1
  root="$(cd "$root" && pwd -P)"
  case "$arm" in
    head) printf '%s\n' "$root/.build/DerivedData/cmux-measure" ;;
    *) printf '%s\n' "$root/.build/DerivedData/cmux-measure-$arm" ;;
  esac
}
