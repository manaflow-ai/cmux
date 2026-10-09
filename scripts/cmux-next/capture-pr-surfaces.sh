#!/usr/bin/env bash
set -euo pipefail

# Capture the fixed cmux-next before/after set on one leased capture mini.
# This script is deliberately host-oriented: the workflow supplies the two
# exact CI archives, while capture-host and cua-ssh remain the authorities for
# admission and GUI access.

usage() {
  cat >&2 <<'EOF'
usage: capture-pr-surfaces.sh --host HOST --head-archive ZIP --base-archive ZIP
                              --out DIR [--capture-host PATH] [--cua PATH]
                              [--tag TAG] [--target APP]
EOF
  exit 2
}
die() { echo "capture-pr-surfaces: $*" >&2; exit 1; }

HOST=${CMUX_CAPTURE_HOST:-}
HEAD_ARCHIVE=${CMUX_CAPTURE_HEAD_ARCHIVE:-}
BASE_ARCHIVE=${CMUX_CAPTURE_BASE_ARCHIVE:-}
OUT=${CMUX_CAPTURE_OUT:-}
TAG=${CMUX_CAPTURE_TAG:-}
TARGET=${CMUX_CAPTURE_TARGET:-}
CAPTURE_HOST=${CMUX_CAPTURE_HOST_TOOL:-capture-host}
CUA=${CMUX_CUA_SSH:-cua-ssh}
while (($#)); do
  case "$1" in
    --host) HOST=${2:?}; shift 2 ;;
    --head-archive) HEAD_ARCHIVE=${2:?}; shift 2 ;;
    --base-archive) BASE_ARCHIVE=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --capture-host) CAPTURE_HOST=${2:?}; shift 2 ;;
    --cua) CUA=${2:?}; shift 2 ;;
    --tag) TAG=${2:?}; shift 2 ;;
    --target) TARGET=${2:?}; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ -n "$HOST" && -n "$HEAD_ARCHIVE" && -n "$BASE_ARCHIVE" && -n "$OUT" ]] || usage
[[ -f "$HEAD_ARCHIVE" && -f "$BASE_ARCHIVE" ]] || die "both exact CI archives are required"
command -v ssh >/dev/null || die "ssh is required"
command -v scp >/dev/null || die "scp is required"
if [[ "$CAPTURE_HOST" != */* ]]; then CAPTURE_HOST="$(command -v "$CAPTURE_HOST" || true)"; fi
if [[ "$CUA" != */* ]]; then CUA="$(command -v "$CUA" || true)"; fi
[[ -x "$CAPTURE_HOST" ]] || die "capture-host is not executable: $CAPTURE_HOST"
[[ -x "$CUA" ]] || die "cua-ssh is not executable: $CUA"
[[ -n "$TAG" ]] || TAG="pr-capture-$$"
[[ -n "$TARGET" ]] || TARGET="cmux DEV $TAG"

RUN_ROOT="${HOME}/cmux-next-capture-${GITHUB_RUN_ID:-$$}"
REMOTE_BASE="$RUN_ROOT/base"
REMOTE_HEAD="$RUN_ROOT/head"
lease=""
owned_app=""
owned_pid=""
cleanup() {
  if [[ -n "$owned_app" && -n "$owned_pid" ]]; then
    command="$(remote "ps -p $owned_pid -o command= 2>/dev/null || true")" || command=""
    if [[ "$command" == *"$owned_app/Contents/MacOS/"* ]]; then
      remote "kill -TERM $owned_pid" >/dev/null 2>&1 || true
      if remote "test -z \"\$(ps -p $owned_pid -o pid= 2>/dev/null)\""; then
        owned_app=""
        owned_pid=""
      else
        echo "capture-pr-surfaces: refusing to release lease while PID $owned_pid is alive" >&2
        lease=""
      fi
    fi
  fi
  if [[ -n "$lease" ]]; then
    # The lease helper owns the remote lock. Releasing it is safe only after
    # quit_owned has verified that the exact app PID is gone.
    "$CAPTURE_HOST" release "$lease" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

lease="$($CAPTURE_HOST acquire)" || die "no capture mini available"
[[ "$lease" == "$HOST" ]] || HOST="$lease"

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "zsh -lc $(printf '%q' "$1")"
}
remote "rm -rf $(printf '%q' "$RUN_ROOT") && mkdir -p $(printf '%q' "$REMOTE_BASE") $(printf '%q' "$REMOTE_HEAD")"
scp -q "$BASE_ARCHIVE" "$HOST:$RUN_ROOT/base.zip"
scp -q "$HEAD_ARCHIVE" "$HOST:$RUN_ROOT/head.zip"
remote "ditto -x -k $(printf '%q' "$RUN_ROOT/base.zip") $(printf '%q' "$REMOTE_BASE") && ditto -x -k $(printf '%q' "$RUN_ROOT/head.zip") $(printf '%q' "$REMOTE_HEAD")"

remote_app() { remote "find $(printf '%q' "$1") -maxdepth 3 -type d -name '*.app' -print -quit"; }
cli() {
  local app=$1; shift; local args="" arg
  for arg in "$@"; do args+=" $(printf '%q' "$arg")"; done
  remote "env -i HOME=\"\$HOME\" USER=\"\$USER\" PATH=/usr/bin:/bin TMPDIR=\"\${TMPDIR:-/tmp}\" CMUX_TAG=$(printf '%q' "$TAG") CMUX_SOCKET_PATH=$(printf '%q' "/tmp/cmux-debug-$TAG.sock") $(printf '%q' "$app/Contents/Resources/bin/cmux")$args"
}
launch_owned() {
  local app=$1 pid
  pid="$(remote "set -e; test -x $(printf '%q' "$app/Contents/Resources/bin/cmux"); exe=\$(find $(printf '%q' "$app/Contents/MacOS") -maxdepth 1 -type f -perm -111 -print -quit); test -n \"\$exe\"; nohup env CMUX_NEXT_SHOWCASE=1 CMUX_TAG=$(printf '%q' "$TAG") CMUX_NEXT_SOCKET_MODE=automation \"\$exe\" --showcase >/tmp/cmux-next-capture-$TAG.log 2>&1 </dev/null & printf '%s' \$!")"
  [[ "$pid" =~ ^[0-9]+$ ]] || die "could not identify the launched app PID"
  remote "test \"\$(ps -p $pid -o command=)\" = *$(printf '%q' "$app/Contents/MacOS/")*" || die "PID $pid is not the launched app"
  # The tagged CLI response is the app-owned readiness signal. It is also the
  # completion point for the first RPC, so no elapsed-time settle is needed.
  cli "$app" list-workspaces >/dev/null || die "launched app PID $pid did not open its control socket"
  printf '%s' "$pid"
}
quit_owned() {
  local app=$1 pid=$2 command
  command="$(remote "ps -p $pid -o command= 2>/dev/null || true")"
  [[ "$command" == *"$app/Contents/MacOS/"* ]] || die "refusing to quit unrelated PID $pid"
  remote "kill -TERM $pid"
  remote "test -z \"\$(ps -p $pid -o pid= 2>/dev/null)\"" || die "owned app PID $pid did not exit"
}
still() {
  local side=$1 name=$2
  local path="$OUT/$side/$name"
  mkdir -p "$path"
  "$CUA" state "$HOST" "$TARGET" --out "$path" --quiet
  [[ -s "$path/screenshot.png" && -s "$path/state.json" ]] || die "incomplete capture: $side/$name"
}
capture_set() {
  local side=$1 root=$2 app pid
  app="$(remote_app "$root")"
  [[ -n "$app" ]] || die "no app in $side archive"
  pid="$(launch_owned "$app")"
  owned_app="$app"
  owned_pid="$pid"
  # New Tab is opened through the public action. The showcase seed supplies a real terminal
  # workspace and deterministic Home content; the agent seed adds the worked
  # turn before the dedicated agent capture.
  cli "$app" action run newTab --focus
  still "$side" 01-new-tab
  cli "$app" rpc debug.showcase.seed '{"focus":true}'
  still "$side" 02-terminal-workspace
  cli "$app" rpc debug.agent_pane '{"action":"seed_rows","fixture":"worked-turn"}'
  still "$side" 03-agent-pane
  cli "$app" action run home.show --focus
  still "$side" 04-home
  cli "$app" action run openSettings --focus
  still "$side" 05-settings
  quit_owned "$app" "$pid"
  owned_app=""
  owned_pid=""
}

mkdir -p "$OUT"
capture_set base "$REMOTE_BASE"
capture_set after "$REMOTE_HEAD"
python3 - "$OUT/manifest.json" "$TAG" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "tag": sys.argv[2],
    "surfaces": ["new-tab", "terminal-workspace", "agent-pane", "home", "settings"],
    "before": "base",
    "after": "after",
    "capture": "cua-ssh",
}, indent=2) + "\n", encoding="utf-8")
PY
echo "capture-pr-surfaces: wrote $OUT"
