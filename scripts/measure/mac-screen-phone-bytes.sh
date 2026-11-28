#!/usr/bin/env bash
# What a phone looking at a native dev build costs on the wire (RFD 0088 slice 3b), in one process on a quiet
# Mac: CmuxVNCWebRTC's PhoneViewBytesTests streams a synthetic screen that, like ScreenCaptureKit, delivers a
# picture only when it changed, through ScreenStreamHost (hardware H.264) to a viewer, for an idle screen,
# typing, a native app animating 20% of the time, and a full-screen scroll at the phone's 1280 rung and at
# full size. Run alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/mac-screen-phone-bytes.sh --ref SHA \
#     [--arg=before=SHA] --timeout 2400
# before=SHA runs this checkout's test file at that commit first (in a worktree; the commit needs the viewer's
# transportBytesReceived), to show a change's before and after on one Mac. Output: MAC-SCREEN-PHONE-BYTES lines
# (workload, size, source changes, frames, video and wire kbit/s, Mbit/s while changing, GB an hour, codec).
# Exit: this ref's result.
set -euo pipefail
before=""
for arg in "$@"; do
  case "$arg" in
    before=*) before="${arg#before=}" ;;
    *) echo "mac-screen-phone-bytes.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ -z "$before" || "$before" =~ ^[0-9a-f]{40}$ ]] || { echo "mac-screen-phone-bytes.sh: before= is a 40-character SHA" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
test_file="Packages/Shared/CmuxVNCWebRTC/Tests/CmuxVNCWebRTCTests/PhoneViewBytesTests.swift"
echo "MAC-SCREEN-PHONE-BYTES-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" macos=$(sw_vers -productVersion) rev=$(git rev-parse HEAD) load=\"$(sysctl -n vm.loadavg)\""

run_at() {
  local label="$1" checkout="$2"
  local log="$root/.build/mac-screen-phone-bytes-$label.log" status=0
  mkdir -p "$root/.build"
  echo "MAC-SCREEN-PHONE-BYTES-RUN $label rev=$(git -C "$checkout" rev-parse HEAD)"
  CMUX_VNC_PHONE_BYTES=1 swift test --package-path "$checkout/Packages/Shared/CmuxVNCWebRTC" \
    --filter PhoneViewBytesTests >"$log" 2>&1 || status=$?
  grep -E "MAC-SCREEN-PHONE-BYTES|✘|passed after|failed after|error:" "$log" || true
  # No result line (a build failure, or a commit the test does not build at): a failure.
  if ! grep -q "MAC-SCREEN-PHONE-BYTES workload=" "$log"; then
    tail -n 60 "$log"
    [[ "$status" -ne 0 ]] || status=3
  fi
  return "$status"
}

if [[ -n "$before" ]]; then
  work="$root/.build/mac-screen-phone-bytes-before"
  git worktree remove --force "$work" 2>/dev/null || true
  git fetch --quiet --recurse-submodules=no origin "$before" 2>/dev/null || git fetch --quiet --recurse-submodules=no https://github.com/manaflow-ai/cmux.git "$before" || true
  set +e
  if git worktree add --detach "$work" "$before" >/dev/null; then
    cp "$root/$test_file" "$work/$test_file"
    run_at before "$work"
    echo "MAC-SCREEN-PHONE-BYTES-RESULT before exit=$?"
    git worktree remove --force "$work"
  else
    echo "MAC-SCREEN-PHONE-BYTES-RESULT before exit=2 (could not check out $before)"
  fi
  set -e
fi
set +e
run_at after "$root"
status=$?
set -e
echo "MAC-SCREEN-PHONE-BYTES-RESULT after exit=$status"
exit "$status"
