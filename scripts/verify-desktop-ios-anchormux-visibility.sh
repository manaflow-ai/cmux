#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-desktop-ios-anchormux-visibility.sh <tag>

Builds the tagged desktop and iOS apps, configures the simulator to mirror the
desktop Anchormux workspaces, captures a screenshot of the inbox-style item
list, then relaunches with auto-open enabled and captures a terminal screenshot.
EOF
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="anchormux"
  fi
  echo "$cleaned"
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TAG="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANITIZED_TAG="$(sanitize_path "$TAG")"
LIST_SCREENSHOT="/tmp/cmux-live-anchormux-${SANITIZED_TAG}-list.png"
TERMINAL_SCREENSHOT="/tmp/cmux-live-anchormux-${SANITIZED_TAG}-terminal.png"

SETUP_LOG="$(mktemp -t "cmux-live-anchormux-${SANITIZED_TAG}-setup")"
"$ROOT/scripts/open-desktop-ios-anchormux-live.sh" "$TAG" | tee "$SETUP_LOG"

CONFIG_PATH="$(awk -F'=' '/^config_path=/ {print $2; exit}' "$SETUP_LOG")"
SIM_ID="$(awk -F'=' '/^simulator_id=/ {print $2; exit}' "$SETUP_LOG")"
DESKTOP_SURFACE_ID="$(awk -F'=' '/^desktop_surface=/ {print $2; exit}' "$SETUP_LOG")"
APP_SOCKET="$(awk -F'=' '/^desktop_automation_socket=/ {print $2; exit}' "$SETUP_LOG")"

if [[ -z "$CONFIG_PATH" || -z "$SIM_ID" || -z "$DESKTOP_SURFACE_ID" || -z "$APP_SOCKET" ]]; then
  echo "error: failed to parse setup output" >&2
  exit 1
fi

APP_SOCKET="$APP_SOCKET" python3 - "$ROOT" <<'PY'
import os
import sys
import time

root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "tests_v2"))
from cmux import cmux  # type: ignore

client = cmux(os.environ["APP_SOCKET"])
client.connect()
try:
    alpha = client.current_workspace()
    client.rename_workspace("Desktop Alpha", alpha)
    beta = client.new_workspace()
    client.rename_workspace("Desktop Beta", beta)
    beta_surfaces = client.list_surfaces(beta)
    if not beta_surfaces:
        raise SystemExit(f"workspace {beta} never exposed a beta surface")
    beta_focused = [surface_id for _, surface_id, is_focused in beta_surfaces if is_focused]
    beta_surface = beta_focused[0] if beta_focused else beta_surfaces[0][1]
    client.send_surface(
        beta_surface,
        "printf '\\\\033[38;5;197mPINK\\\\033[0m "
        "\\\\033[38;5;46mGREEN\\\\033[0m "
        "\\\\033[38;5;226mYELLOW\\\\033[0m "
        "\\\\033[38;5;81mCYAN\\\\033[0m\\\\n'\\r",
    )
    client.select_workspace(alpha)
    print(f"alpha={alpha}")
    print(f"beta={beta}")
finally:
    client.close()
PY

python3 - "$CONFIG_PATH" <<'PY'
import json
import sys
import time

path = sys.argv[1]
deadline = time.time() + 10.0
last = None
while time.time() < deadline:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        titles = [item.get("title", "") for item in payload.get("workspace_items", [])]
        if "Desktop Alpha" in titles and "Desktop Beta" in titles:
            raise SystemExit(0)
        last = titles
    except OSError as exc:
        last = str(exc)
    time.sleep(0.1)
raise SystemExit(f"workspace sync never published both desktop items: {last}")
PY

sleep 1
xcrun simctl io "$SIM_ID" screenshot --type=png "$LIST_SCREENSHOT" >/dev/null

python3 - "$CONFIG_PATH" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

for item in payload.get("workspace_items", []):
    if item.get("title") == "Desktop Beta":
        payload["auto_open_session_id"] = item.get("session_id")
        break

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY

xcrun simctl terminate "$SIM_ID" dev.cmux.app.dev >/dev/null 2>&1 || true
xcrun simctl launch "$SIM_ID" dev.cmux.app.dev >/dev/null
sleep 6
xcrun simctl io "$SIM_ID" screenshot --type=png "$TERMINAL_SCREENSHOT" >/dev/null

printf 'list_screenshot=%s\n' "$LIST_SCREENSHOT"
printf 'terminal_screenshot=%s\n' "$TERMINAL_SCREENSHOT"
printf 'PASS: captured Anchormux item-list and terminal screenshots\n'
