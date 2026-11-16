# shellcheck shell=bash
# SimSlim for the fleet's iOS simulators (scripts/ci/simslim/README.md).
#
# A stock iOS 26.5 simulator runs ~280 processes and ~4.5 GB phys_footprint; slimmed with
# fleet.json it runs ~80 and ~1.1 GB (aws-m4pro-8, 2026-11-15). Sourced by the scripts that
# create simulators. Every simulator a run creates is slimmed before its first boot and gated
# after it; nothing here touches a simulator the run did not create. On the host, simslim
# writes only that simulator's overrides file (/private/var/tmp/com.apple.CoreSimulator.SimDevice.UDID).
#
#   cmux_simslim_init WORK_DIR OUT_DIR     once, before any simulator: fetch the pinned simslim
#   cmux_simslim_prepare UDID [SET]        after `simctl create`, before the first boot
#   cmux_simslim_gate UDID [SET]           once booted: doctor + verify; non-zero fails the run
#   cmux_simslim_boot_and_gate UDID [SET]  slim: boot now and gate; stock: nothing (xcodebuild boots)
#   cmux_simslim_check_clones LOG          warn when an xcodebuild run cloned its simulator
#   cmux_simslim_measure UDID LABEL [SET]  booted: phys_footprint into OUT_DIR/simslim/LABEL.json
#
# Per run (env):
#   CMUX_SIM_FULL=1          stock simulators: no slimming at all (Spotlight, Photos, iCloud,
#                            Siri, widgets...). measure still runs, read-only.
#   CMUX_SIM_KEEP=LIST       keep more on top of fleet.json: category IDs (`simslim profiles`,
#                            e.g. photos,search,icloud) and launchd labels (com.apple.assetsd),
#                            comma-separated.
#   CMUX_SIMSLIM_BIN=PATH    use this simslim instead of downloading the pinned release (a rig
#                            on a host that has it); its version must still be the pinned one.
#
# Failure policy: slimming is a memory optimization, so a missing tool (download failure)
# falls back to stock with a warning in SUMMARY. A slimmed simulator that fails its gate
# (a required feature disabled, or drift from the profile) fails the run: that simulator
# is not the one the tests asked for.

cmux_simslim_version=0.14.0
cmux_simslim_sha256=a3db0de6f428f9f8fd5dff256b122f98791c138521dc1330d99643719d8fe9ff
# What every slimmed fleet simulator must still do (`simslim doctor --list`).
cmux_simslim_requires=push,storekit,universal-links

cmux_simslim_bin=""
cmux_simslim_profile=""
cmux_simslim_out=""
cmux_simslim_mode=stock   # slim | stock | unavailable

_cmux_simslim_note() {
  if declare -F note >/dev/null; then note "$*"; else printf '%s\n' "$*"; fi
}

# _cmux_simslim run [--set SET] ARGS...: simslim with the run's device set, if any.
_cmux_simslim() {
  local set_args=()
  if [[ "${1:-}" == --set ]]; then
    [[ -n "$2" ]] && set_args=(--set "$2")
    shift 2
  fi
  "$cmux_simslim_bin" ${set_args[@]+"${set_args[@]}"} "$@"
}

cmux_simslim_init() {
  local work=$1 out=$2 here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cmux_simslim_out="$out/simslim"
  mkdir -p "$cmux_simslim_out" "$work/simslim"
  if [[ -n "${CMUX_SIMSLIM_BIN:-}" ]]; then
    cmux_simslim_bin="$CMUX_SIMSLIM_BIN"
  else
    local tgz="$work/simslim/simslim.tgz" got
    if curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 -o "$tgz" \
      "https://github.com/MobAI-App/simslim/releases/download/v$cmux_simslim_version/simslim-v$cmux_simslim_version-macos-arm64.tar.gz"; then
      got="$(shasum -a 256 "$tgz" | awk '{ print $1 }')"
      if [[ "$got" == "$cmux_simslim_sha256" ]] && tar -xzf "$tgz" -C "$work/simslim" simslim; then
        cmux_simslim_bin="$work/simslim/simslim"
      else
        echo "warning: simslim $cmux_simslim_version: sha256 $got, expected $cmux_simslim_sha256" >&2
      fi
    fi
  fi
  local why=""
  if [[ -z "$cmux_simslim_bin" ]]; then
    why="download or checksum failed"
  elif [[ ! -x "$cmux_simslim_bin" ]]; then
    why="no executable at $cmux_simslim_bin"
  elif [[ "$("$cmux_simslim_bin" --version 2>/dev/null)" != "simslim $cmux_simslim_version" ]]; then
    why="$cmux_simslim_bin is not simslim $cmux_simslim_version"
  fi
  if [[ -n "$why" ]]; then
    cmux_simslim_bin=""
    if [[ "${CMUX_SIM_FULL:-0}" == 1 ]]; then
      _cmux_simslim_note "- simulators: stock (CMUX_SIM_FULL=1); simslim $cmux_simslim_version unavailable ($why), no memory receipt"
    else
      _cmux_simslim_note "- simulators: WARNING stock, simslim $cmux_simslim_version unavailable ($why)"
    fi
    cmux_simslim_mode=unavailable
    return 0
  fi
  if [[ "${CMUX_SIM_FULL:-0}" == 1 ]]; then
    cmux_simslim_mode=stock
    _cmux_simslim_note "- simulators: stock (CMUX_SIM_FULL=1), simslim $cmux_simslim_version measures only"
    return 0
  fi
  cmux_simslim_profile="$work/simslim/profile.json"
  python3 -I "$here/profile.py" "$here/fleet.json" "${CMUX_SIM_KEEP:-}" >"$cmux_simslim_profile" ||
    { echo "error: CMUX_SIM_KEEP='${CMUX_SIM_KEEP:-}' is not a list of simslim categories or com.apple labels" >&2; return 2; }
  cp "$cmux_simslim_profile" "$cmux_simslim_out/profile.json"
  cmux_simslim_mode=slim
  _cmux_simslim_note "- simulators: slim (simslim $cmux_simslim_version, scripts/ci/simslim/fleet.json${CMUX_SIM_KEEP:+, keep $CMUX_SIM_KEEP}); gate: $cmux_simslim_requires"
}

cmux_simslim_prepare() {
  local udid=$1 set=${2:-}
  [[ "$cmux_simslim_mode" == slim ]] || return 0
  # Writes the profile's disable overrides into the shut-down simulator's launchd store and
  # returns it to Shutdown, so its first real boot starts none of those daemons.
  if ! _cmux_simslim --set "$set" on "$udid" --preserve-boot-state --profile "$cmux_simslim_profile" \
      >>"$cmux_simslim_out/on-$udid.log" 2>&1; then
    tail -20 "$cmux_simslim_out/on-$udid.log" >&2 || true
    echo "error: simslim on $udid failed; see simslim/on-$udid.log" >&2
    return 1
  fi
}

cmux_simslim_gate() {
  local udid=$1 set=${2:-}
  [[ "$cmux_simslim_mode" == slim ]] || return 0
  if ! _cmux_simslim --set "$set" doctor "$udid" --requires "$cmux_simslim_requires" \
      >"$cmux_simslim_out/doctor-$udid.txt" 2>&1; then
    cat "$cmux_simslim_out/doctor-$udid.txt" >&2
    local broken
    broken="$(grep -c BROKEN "$cmux_simslim_out/doctor-$udid.txt" || true)"
    if [[ "$broken" -gt 0 ]]; then
      _cmux_simslim_note "- simslim gate FAILED on $udid: $broken required feature(s) broken (simslim/doctor-$udid.txt)"
    else
      _cmux_simslim_note "- simslim gate FAILED on $udid: doctor could not check it (simslim/doctor-$udid.txt)"
    fi
    return 1
  fi
  if ! _cmux_simslim --set "$set" verify "$udid" --profile "$cmux_simslim_profile" \
      >"$cmux_simslim_out/verify-$udid.txt" 2>&1; then
    cat "$cmux_simslim_out/verify-$udid.txt" >&2
    _cmux_simslim_note "- simslim gate FAILED on $udid: drift from the profile (simslim/verify-$udid.txt)"
    return 1
  fi
  _cmux_simslim_note "- simslim gate: $udid ok ($cmux_simslim_requires; matches the profile)"
}

cmux_simslim_measure() {
  local udid=$1 label=$2 set=${3:-} json
  [[ -n "$cmux_simslim_bin" ]] || return 0
  json="$(_cmux_simslim --set "$set" measure "$udid" --json 2>/dev/null)" || return 0
  printf '%s\n' "$json" >"$cmux_simslim_out/$label.json"
  _cmux_simslim_note "- simulator memory ($label, $cmux_simslim_mode): $(python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
print("%d processes, %.2f GB phys_footprint" % (d["processes"], d["bytes"] / 1e9))
' "$json")"
}

cmux_simslim_boot_and_gate() {
  local udid=$1 set=${2:-} set_args=()
  [[ "$cmux_simslim_mode" == slim ]] || return 0
  [[ -n "$set" ]] && set_args=(--set "$set")
  xcrun simctl ${set_args[@]+"${set_args[@]}"} boot "$udid"
  xcrun simctl ${set_args[@]+"${set_args[@]}"} bootstatus "$udid" -b >/dev/null
  cmux_simslim_gate "$udid" "$set"
}

# Parallel testing clones its simulator per worker, and a clone starts stock (overrides do not
# survive `simctl clone`), so a run that cloned did not test on the slim simulator it gated.
# The step's schemes do not parallelize today; this says so if one starts to.
cmux_simslim_check_clones() {
  local log=$1
  [[ "$cmux_simslim_mode" == slim && -f "$log" ]] || return 0
  if grep -q -E "Clone [0-9]+ of " "$log"; then
    _cmux_simslim_note "- WARNING: $(basename "$log") ran on parallel-testing clones, which start stock and ungated"
  fi
  return 0
}
