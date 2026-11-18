# shellcheck shell=bash
# A simulator screen recording that a fleet step starts in the background and finishes on SIGINT
# (`simctl io recordVideo` writes the file's end only then). Sourced by scripts/ci/cmux-next-ios-sim.sh.
#
#   sim_recorder_start UDID OUT LOG [DEVICE_SET]   starts recording UDID's screen into OUT
#   sim_recorder_stop                              finishes the file and waits for the recorder

SIM_RECORDER_PID=""

sim_recorder_start() {
  local udid=$1 out=$2 log=$3 set=${4:-}
  _sim_recorder_simctl() { xcrun simctl ${set:+--set "$set"} "$@"; }
  _sim_recorder_simctl io "$udid" recordVideo --codec h264 --force "$out" >"$log" 2>&1 &
  SIM_RECORDER_PID=$!
}

sim_recorder_stop() {
  [[ -n "$SIM_RECORDER_PID" ]] || return 0
  kill -INT "$SIM_RECORDER_PID" 2>/dev/null || true
  wait "$SIM_RECORDER_PID" 2>/dev/null || true
  SIM_RECORDER_PID=""
}
