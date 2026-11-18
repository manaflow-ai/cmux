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

# Per-commit caches (cmux-measure-at-<sha12>, app-at-commit.sh) grow by one full DerivedData per commit a warm
# checkout ever built, so measure_app_at_commit caps them when it returns, built or failed:
#   measure_derived_data_in_use DIR   marks DIR used now (its mtime) and in use by this run (DIR/.measure-in-use.$$,
#                                     the measure script's own pid, alive until that script exits).
#   measure_prune_derived_data [KEEP] keeps the KEEP (CMUX_MEASURE_DERIVED_DATA_KEEP, default 3: an A/B builds two
#                                     commits) most recently used caches and every cache a live process marked, removes
#                                     the rest, and prints DERIVED-DATA-PRUNE kept=K removed=R freed_gb=X on stderr.
# Only real directories named cmux-measure-at-<12 lowercase hex> directly under this checkout's .build/DerivedData
# are ever removed. Marking and pruning hold one lock per checkout, so a run cannot mark a cache another run is
# removing. tests/derived-data-prune.test.py is the detector.

_measure_pid_alive() { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }

_measure_derived_data_lock() {  # _measure_derived_data_lock DD: mkdir is atomic; a dead or 10-minute-old holder's lock is taken over
  local lock="$1/.cmux-measure-at.lock" holder i
  for ((i = 0; i < 600; i++)); do
    if mkdir "$lock" 2>/dev/null; then
      echo "$$" >"$lock/pid"
      return 0
    fi
    holder="$(cat "$lock/pid" 2>/dev/null)"
    if { [[ "$holder" =~ ^[0-9]+$ ]] && ! _measure_pid_alive "$holder"; } \
      || [[ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
      rm -rf -- "$lock"
      continue
    fi
    sleep 0.1
  done
  return 1
}

_measure_derived_data_unlock() { rm -rf -- "$1/.cmux-measure-at.lock"; }

measure_derived_data_in_use() {
  local dir="$1" dd locked=false
  dd="$(dirname "$dir")"
  mkdir -p "$dir" || return 1
  _measure_derived_data_lock "$dd" && locked=true
  touch "$dir" && : >"$dir/.measure-in-use.$$"
  local rc=$?
  $locked && _measure_derived_data_unlock "$dd"
  return "$rc"
}

measure_prune_derived_data() {
  local keep="${1:-${CMUX_MEASURE_DERIVED_DATA_KEEP:-3}}" dd dir name marker pid busy kb kept=0 removed=0 freed_kb=0
  dd="$(measure_arm_derived_data head)" || return 0
  dd="$(dirname "$dd")"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=3
  if [[ ! -d "$dd" ]]; then
    echo "DERIVED-DATA-PRUNE kept=0 removed=0 freed_gb=0.00" >&2
    return 0
  fi
  if ! _measure_derived_data_lock "$dd"; then
    echo "DERIVED-DATA-PRUNE skipped: another run holds $dd/.cmux-measure-at.lock" >&2
    return 0
  fi
  # Newest first by mtime (ls -t, the same on macOS and Linux).
  while IFS= read -r name; do
    dir="$dd/$name"
    [[ "$name" =~ ^cmux-measure-at-[0-9a-f]{12}$ && -d "$dir" && ! -L "$dir" ]] || continue
    busy=false
    for marker in "$dir"/.measure-in-use.*; do
      [[ -e "$marker" ]] || continue
      pid="${marker##*.}"
      if [[ "$pid" =~ ^[0-9]+$ ]] && _measure_pid_alive "$pid"; then busy=true; fi
    done
    if $busy || (( kept < keep )); then
      kept=$((kept + 1))
      continue
    fi
    kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"
    if rm -rf -- "$dir"; then
      removed=$((removed + 1))
      freed_kb=$((freed_kb + ${kb:-0}))
    fi
  done < <(cd "$dd" && ls -1dt cmux-measure-at-* 2>/dev/null)
  _measure_derived_data_unlock "$dd"
  echo "DERIVED-DATA-PRUNE kept=$kept removed=$removed freed_gb=$(awk -v k="$freed_kb" 'BEGIN { printf "%.2f", k / 1048576 }')" >&2
}
