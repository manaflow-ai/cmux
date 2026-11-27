# shellcheck shell=bash
# Reduce Motion for scripts/ci/cmux-next-ios-sim.sh reducemotion=1 (sourced; no top-level work).
# Tested with a fake xcrun by scripts/ci/tests/test_ios_sim_release_build.py.

# sim_reduce_motion UDID [SET]: Reduce Motion on in a booted simulator (its own com.apple.Accessibility
# domain, never the host's), then read back inside it; prints the value read, fails unless it is 1.
sim_reduce_motion() {
  local udid=$1 set=${2:-} value
  local c=(xcrun simctl)
  [[ -z "$set" ]] || c+=(--set "$set")
  "${c[@]}" spawn "$udid" defaults write com.apple.Accessibility ReduceMotionEnabled -bool true || return 1
  "${c[@]}" spawn "$udid" notifyutil -p com.apple.accessibility.reduce.motion.status >/dev/null 2>&1 || true
  value="$("${c[@]}" spawn "$udid" defaults read com.apple.Accessibility ReduceMotionEnabled 2>&1)" || true
  printf '%s\n' "$value"
  [[ "$value" == 1 ]]
}

# reduce_motion_app_verdict LOG: what the app's DEBUG launch line (CmuxMobileApp.init) in LOG says
# UIKit reported: prints true, false or "not logged"; succeeds only for true.
reduce_motion_app_verdict() {
  local seen
  seen="$(printf '%s\n' "$1" | grep -o 'isReduceMotionEnabled=[a-z]*' | tail -n 1 || true)"
  seen="${seen#isReduceMotionEnabled=}"
  printf '%s\n' "${seen:-not logged}"
  [[ "$seen" == true ]]
}
