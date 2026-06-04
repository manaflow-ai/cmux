#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LINUX_DIR="$REPO_ROOT/linux"
TARGET_DIR="$LINUX_DIR/target/debug"
OUT_DIR="${1:-$REPO_ROOT/screenshots}"
DISPLAY_NUM="${DISPLAY_NUM:-106}"
DISPLAY=":$DISPLAY_NUM"
WINDOW_SIZE="${WINDOW_SIZE:-1400x900}"
SCREENSHOT_KIT_DIR="${SCREENSHOT_KIT_DIR:-$HOME/bin/screenshot-kit}"
RUNTIME_DIR="${CAPTURE_RUNTIME_DIR:-$REPO_ROOT/tmp/capture-runtime-$DISPLAY_NUM}"
SOCKET_PATH="$RUNTIME_DIR/cmux.sock"
APP_LOG="$REPO_ROOT/tmp/linux_port_capture.log"
APP_PID=""
REQUEST_ID=1
RECORDING_PID=""
SOCKET_OURS=0
DEMO_ROOT_DIR="${DEMO_ROOT_DIR:-$REPO_ROOT}"
DEMO_REVIEW_DIR="${DEMO_REVIEW_DIR:-$REPO_ROOT/linux}"
DEMO_DOCS_DIR="${DEMO_DOCS_DIR:-$REPO_ROOT/docs}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

cleanup() {
  stop_app

  if [ -x "$SCREENSHOT_KIT_DIR/display-setup.sh" ]; then
    "$SCREENSHOT_KIT_DIR/display-setup.sh" "$DISPLAY_NUM" "1920x1080x24" stop >/dev/null 2>&1 || true
  fi
}

wait_for_socket() {
  for _ in $(seq 1 80); do
    if [ -S "$SOCKET_PATH" ]; then
      return 0
    fi
    sleep 0.25
  done

  echo "Error: cmux socket did not appear at $SOCKET_PATH" >&2
  exit 1
}

socket_is_live() {
  local probe=""

  probe="$(
    printf '{"id":0,"method":"system.ping","params":{}}\n' |
      nc -w 1 -N -U "$SOCKET_PATH" 2>/dev/null || true
  )"

  echo "$probe" | jq -e '.ok == true' >/dev/null 2>&1
}

ensure_socket_available() {
  mkdir -p "$RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR"

  if [ ! -e "$SOCKET_PATH" ]; then
    return 0
  fi
  if [ ! -S "$SOCKET_PATH" ]; then
    echo "Error: $SOCKET_PATH exists but is not a socket — refusing to overwrite" >&2
    exit 1
  fi

  if socket_is_live; then
    echo "Error: another cmux instance is already responding on $SOCKET_PATH" >&2
    echo "Use a different CAPTURE_RUNTIME_DIR or stop the other instance first." >&2
    exit 1
  fi

  if [ -S "$SOCKET_PATH" ]; then
    rm -f "$SOCKET_PATH"
  fi
}

wait_for_window() {
  local window_id=""

  for _ in $(seq 1 80); do
    window_id="$(DISPLAY="$DISPLAY" xdotool search --onlyvisible --name cmux 2>/dev/null | tail -n1 || true)"
    if [ -n "$window_id" ]; then
      echo "$window_id"
      return 0
    fi
    sleep 0.25
  done

  echo "Error: cmux window did not appear on $DISPLAY" >&2
  exit 1
}

wait_for_no_window() {
  for _ in $(seq 1 40); do
    if ! DISPLAY="$DISPLAY" xdotool search --onlyvisible --name cmux >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
}

cmux_cli() {
  XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    LD_LIBRARY_PATH="$TARGET_DIR" \
    "$TARGET_DIR/cmux" "$@"
}

socket_call() {
  local method="$1"
  local params="${2:-{}}"
  local response=""

  response="$(
    printf '{"id":%s,"method":"%s","params":%s}\n' \
      "$REQUEST_ID" "$method" "$params" |
      nc -w 5 -N -U "$SOCKET_PATH"
  )"
  REQUEST_ID=$((REQUEST_ID + 1))

  echo "$response"
}

window_screenshot() {
  local output="$1"
  DISPLAY="$DISPLAY" "$SCREENSHOT_KIT_DIR/screenshot.sh" "$output" --window cmux --delay 1 >/dev/null
}

start_recording() {
  local output="$1"
  local duration="$2"

  DISPLAY="$DISPLAY" "$SCREENSHOT_KIT_DIR/record.sh" "$output" \
    --duration "$duration" \
    --fps 24 \
    --size 1920x1080 >/dev/null &
  RECORDING_PID=$!
}

stop_app() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  APP_PID=""
  if [ "$SOCKET_OURS" -eq 1 ] && [ -S "$SOCKET_PATH" ]; then
    rm -f "$SOCKET_PATH"
  fi
  SOCKET_OURS=0
  wait_for_no_window || true
}

start_app() {
  ensure_socket_available

  LD_LIBRARY_PATH="$TARGET_DIR" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    GDK_BACKEND=x11 \
    DISPLAY="$DISPLAY" \
    "$TARGET_DIR/cmux-app" >"$APP_LOG" 2>&1 &
  APP_PID=$!

  wait_for_socket
  SOCKET_OURS=1
  WINDOW_ID="$(wait_for_window)"
  DISPLAY="$DISPLAY" xdotool windowsize "$WINDOW_ID" "${WINDOW_SIZE%x*}" "${WINDOW_SIZE#*x}" >/dev/null 2>&1 || true
  sleep 1
}

type_line() {
  local window_id="$1"
  local text="$2"

  DISPLAY="$DISPLAY" xdotool type --delay 18 --window "$window_id" "$text"
  DISPLAY="$DISPLAY" xdotool key --window "$window_id" Return
}

display_quoted_path() {
  local path="$1"
  local suffix

  if [ "$path" = "$HOME" ]; then
    printf '"$HOME"'
    return
  elif [[ "$path" == "$HOME/"* ]]; then
    suffix="${path#"$HOME"/}"
    # Escape shell-special characters in the suffix
    suffix="${suffix//\\/\\\\}"
    suffix="${suffix//\$/\\\$}"
    suffix="${suffix//\`/\\\`}"
    suffix="${suffix//\"/\\\"}"
    printf '"$HOME/%s"' "$suffix"
  else
    local display_path="$path"
    display_path="${display_path//\\/\\\\}"
    display_path="${display_path//\$/\\\$}"
    display_path="${display_path//\`/\\\`}"
    display_path="${display_path//\"/\\\"}"
    printf '"%s"' "$display_path"
  fi
}

main() {
  trap cleanup EXIT

  require_cmd cargo
  require_cmd jq
  require_cmd nc
  require_cmd xdotool

  if [ ! -x "$SCREENSHOT_KIT_DIR/display-setup.sh" ]; then
    echo "Error: screenshot-kit not found at $SCREENSHOT_KIT_DIR" >&2
    exit 1
  fi

  mkdir -p "$OUT_DIR" "$REPO_ROOT/tmp"
  rm -f "$OUT_DIR"/linux_port_ghostty_*.png "$OUT_DIR"/linux_port_ghostty_*.mp4 "$APP_LOG"
  cargo build --features cmux/link-ghostty --manifest-path "$LINUX_DIR/Cargo.toml" >/dev/null

  "$SCREENSHOT_KIT_DIR/display-setup.sh" "$DISPLAY_NUM" "1920x1080x24" start >/dev/null
  start_app

  local terminal_demo_video="$OUT_DIR/linux_port_ghostty_terminal_demo.mp4"
  local terminal_hero_png="$OUT_DIR/linux_port_ghostty_terminal.png"
  local sidebar_png="$OUT_DIR/linux_port_ghostty_sidebar.png"
  local splits_png="$OUT_DIR/linux_port_ghostty_splits.png"
  local splits_annotated_png="$OUT_DIR/linux_port_ghostty_splits_annotated.png"
  local workspace_video="$OUT_DIR/linux_port_ghostty_workspace_demo.mp4"
  local display_demo_root

  display_demo_root="$(display_quoted_path "$DEMO_ROOT_DIR")"

  start_recording "$terminal_demo_video" 5
  sleep 0.5
  type_line "$WINDOW_ID" "clear"
  type_line "$WINDOW_ID" "cd $display_demo_root"
  type_line "$WINDOW_ID" "printf 'ghostty linked demo\n'"
  type_line "$WINDOW_ID" "git status --short --branch | head -5"
  type_line "$WINDOW_ID" "printf 'workspace: %s\n' cmux"
  wait "$RECORDING_PID"
  window_screenshot "$terminal_hero_png"

  stop_app
  start_app

  local workspace_one workspace_two workspace_three

  workspace_one="$(
    socket_call "workspace.create" \
      "$(jq -nc --arg title "Claude Code" --arg directory "$DEMO_ROOT_DIR" '{title:$title,directory:$directory}')" |
      jq -r '.result.workspace_id'
  )"
  workspace_two="$(
    socket_call "workspace.new" \
      "$(jq -nc --arg title "Codex Review" --arg directory "$DEMO_REVIEW_DIR" '{title:$title,directory:$directory}')" |
      jq -r '.result.workspace_id'
  )"
  workspace_three="$(
    socket_call "workspace.new" \
      "$(jq -nc --arg title "Release Notes" --arg directory "$DEMO_DOCS_DIR" '{title:$title,directory:$directory}')" |
      jq -r '.result.workspace_id'
  )"

  socket_call "workspace.select" '{"index":0}' >/dev/null
  socket_call "workspace.report_git_branch" '{"branch":"linux-port","is_dirty":true}' >/dev/null
  socket_call "workspace.set_status" '{"key":"agent","value":"Claude","icon":"robot"}' >/dev/null
  socket_call "workspace.set_progress" '{"value":0.72,"label":"validation"}' >/dev/null
  socket_call "notification.create" '{"title":"Claude Code","body":"Ready for review","send_desktop":false}' >/dev/null

  socket_call "workspace.select" "$(jq -nc --arg workspace "$workspace_one" '{workspace:$workspace}')" >/dev/null
  socket_call "workspace.report_git_branch" '{"branch":"pr-828","is_dirty":false}' >/dev/null
  socket_call "workspace.set_status" '{"key":"agent","value":"Codex","icon":"terminal"}' >/dev/null
  socket_call "workspace.set_progress" '{"value":0.45,"label":"capture"}' >/dev/null
  socket_call "notification.create" '{"title":"Codex","body":"Need screenshot approval","send_desktop":false}' >/dev/null

  socket_call "workspace.select" "$(jq -nc --arg workspace "$workspace_three" '{workspace:$workspace}')" >/dev/null
  socket_call "workspace.report_git_branch" '{"branch":"docs/pr-assets","is_dirty":false}' >/dev/null
  socket_call "workspace.set_status" '{"key":"agent","value":"Drafting","icon":"note"}' >/dev/null
  socket_call "notification.create" '{"title":"Release","body":"Assets ready to attach","send_desktop":false}' >/dev/null

  socket_call "workspace.select" "$(jq -nc --arg workspace "$workspace_one" '{workspace:$workspace}')" >/dev/null
  sleep 1
  window_screenshot "$sidebar_png"

  start_recording "$workspace_video" 5
  sleep 0.5
  cmux_cli --json pane new --orientation horizontal >/dev/null
  sleep 0.8
  cmux_cli --json pane new --orientation vertical >/dev/null
  sleep 1.2
  socket_call "workspace.select" '{"index":2}' >/dev/null
  sleep 0.8
  socket_call "workspace.select" '{"index":1}' >/dev/null
  sleep 0.8
  wait "$RECORDING_PID"

  window_screenshot "$splits_png"
  "$SCREENSHOT_KIT_DIR/annotate.sh" "$splits_png" "$splits_annotated_png" \
    --color '#5ec8ff' \
    --font-size 26 \
    --text '860,120,"Vertical split"' \
    --line '862,42,862,894' \
    --text '1080,470,"Horizontal split"' \
    --line '862,451,1398,451' >/dev/null

  printf 'Created assets in %s\n' "$OUT_DIR"
  printf '%s\n' "$OUT_DIR"/linux_port_ghostty_*
}

main "$@"
