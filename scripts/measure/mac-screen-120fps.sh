#!/usr/bin/env bash
# Mac Screen at 120 fps, in one process on a quiet Mac: CmuxVNCWebRTC's
# HighFrameRateStreamTests streams a synthetic 3456x2234 display scrolling at
# 120 fps through ScreenStreamHost (hardware H.264) to a viewer that reports a
# 120 Hz display, for Auto and Smooth Motion, and fails when fewer than 110
# frames a second are decoded. Run alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/mac-screen-120fps.sh --ref SHA \
#     [--arg=before=SHA] --timeout 2400
# before=SHA runs the same test at that commit first (in a worktree), to show
# a change's before and after on one Mac. Output: MAC-SCREEN-120FPS lines
# (agreed rate, source, received and decoded fps, dropped frames, size,
# bitrate, decoder, and the host's last encoder lines). Exit: this ref's result.
set -euo pipefail
before=""
for arg in "$@"; do
  case "$arg" in
    before=*) before="${arg#before=}" ;;
    *) echo "mac-screen-120fps.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ -z "$before" || "$before" =~ ^[0-9a-f]{40}$ ]] || { echo "mac-screen-120fps.sh: before= is a 40-character SHA" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
echo "MAC-SCREEN-120FPS-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" macos=$(sw_vers -productVersion) rev=$(git rev-parse HEAD) load=\"$(sysctl -n vm.loadavg)\""

run_at() {
  local label="$1" checkout="$2"
  local log="$root/.build/mac-screen-120fps-$label.log" status=0
  mkdir -p "$root/.build"
  echo "MAC-SCREEN-120FPS-RUN $label rev=$(git -C "$checkout" rev-parse HEAD)"
  CMUX_VNC_120FPS=1 swift test --package-path "$checkout/Packages/Shared/CmuxVNCWebRTC" \
    --filter HighFrameRateStreamTests >"$log" 2>&1 || status=$?
  grep -E "MAC-SCREEN-120FPS|host: (frame rate|capturing|video:)|✘|passed after|failed after|error:" "$log" || true
  # No result line (a build failure, or a commit without the test, whose filter matches nothing): a failure.
  if ! grep -q "MAC-SCREEN-120FPS quality=" "$log"; then
    tail -n 60 "$log"
    [[ "$status" -ne 0 ]] || status=3
  fi
  return "$status"
}

if [[ -n "$before" ]]; then
  work="$root/.build/mac-screen-120fps-before"
  git worktree remove --force "$work" 2>/dev/null || true
  git fetch --quiet origin "$before" 2>/dev/null || true
  set +e
  if git worktree add --detach "$work" "$before" >/dev/null; then
    run_at before "$work"
    echo "MAC-SCREEN-120FPS-RESULT before exit=$?"
    git worktree remove --force "$work"
  else
    echo "MAC-SCREEN-120FPS-RESULT before exit=2 (could not check out $before)"
  fi
  set -e
fi
set +e
run_at after "$root"
status=$?
set -e
echo "MAC-SCREEN-120FPS-RESULT after exit=$status"
exit "$status"
