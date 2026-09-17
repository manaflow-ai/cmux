#!/bin/bash
# Capture the App Store screenshot set from a REAL paired simulator: live Mac
# connection, real agent sessions, real workspace list, real diffs. Complements
# the fixture-based CI capture (SnapshotUITests) when listing content should be
# genuine agent output rather than recorded fixtures.
#
# Prerequisites:
#   - a tagged Mac cmux running with real agent sessions in named workspaces
#   - the same-tag iOS app installed, SIGNED IN, and PAIRED on the target sim
#     (scripts/mobile-dev-launch.sh --tag <tag> --simulator-id <udid>); this
#     driver never relaunches the signed-in app: a bare `simctl launch` wipes
#     the dev session, so between shots it only NAVIGATES
#   - axe + idb installed; the sim booted with a 9:41 status-bar override
#
# Usage: appstore-shots-real.sh --udid <sim-udid> [--class iphone|ipad]
#        [--bundle-id dev.cmux.ios.shots] [--out <dir>] [--prompt <text>]
#        [--reply-text <text>] [--skip-lockshot]
#
# Writes fastlane-style names (<Device Name>-<Shot>.png) into
# fastlane/appstore-shots-work/captures/en-US/ so `appstore-shots.sh post`
# consumes them unchanged. The optional system-fixture shot runs last because
# its launch ends the signed-in foreground session.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(dirname "$HERE")/fastlane/appstore-shots-work"
UDID="" CLASS="iphone" BUNDLE_ID="dev.cmux.ios.shots" OUT="" SKIP_LOCK=0
PROMPT_TEXT="Add Apple Pay to the checkout flow and cover it with tests"
REPLY_TEXT="Looks great, merge it and start the deploy"
while [ $# -gt 0 ]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --skip-lockshot) SKIP_LOCK=1; shift ;;
    --prompt) PROMPT_TEXT="$2"; shift 2 ;;
    --reply-text) REPLY_TEXT="$2"; shift 2 ;;
    *) echo "unknown flag $1" >&2; exit 1 ;;
  esac
done
[ -n "$UDID" ] || { echo "--udid required" >&2; exit 1; }
[ "$CLASS" = iphone ] || [ "$CLASS" = ipad ] || {
  echo "--class must be iphone or ipad" >&2
  exit 1
}
[ -n "$OUT" ] || OUT="$WORK/captures/en-US"
mkdir -p "$OUT"
PREFIX="$([ "$CLASS" = ipad ] && echo 'iPad Real' || echo 'iPhone Real')"
# A rerun must not leave a stale real capture for a shot that failed midway.
# Fixture captures remain untouched, so `--capture-source real` is always
# explicit and all-or-nothing.
find "$OUT" -maxdepth 1 -type f -name "$PREFIX-*.png" -delete

shot() { xcrun simctl io "$UDID" screenshot "$OUT/$PREFIX-$1.png" >/dev/null 2>&1; echo "captured $1"; }

ax_find() { # ax_find <label> <exact|prefix|contains>  -> "x y" of center
  axe describe-ui --udid "$UDID" 2>/dev/null | python3 -c "
import json, sys
label = sys.argv[1]; mode = sys.argv[2]
def walk(n):
    yield n
    for c in n.get('children') or []:
        yield from walk(c)
best = None
for root in json.load(sys.stdin):
    for n in walk(root):
        lab = (n.get('AXLabel') or '').strip()
        if not lab: continue
        ok = (mode == 'exact' and lab == label) or \
             (mode == 'prefix' and lab.startswith(label)) or \
             (mode == 'contains' and label in lab)
        if ok:
            f = n['frame']
            best = (f['x'] + f['width']/2, f['y'] + f['height']/2)
            break
    if best: break
if not best: sys.exit(1)
print(f'{best[0]:.0f} {best[1]:.0f}')
" "$1" "${2:-exact}"
}

tap_label() { # tap_label <label> [mode]
  local xy
  xy="$(ax_find "$1" "${2:-exact}")" || { echo "tap_label: '$1' not found" >&2; return 1; }
  axe tap -x "${xy%% *}" -y "${xy##* }" --udid "$UDID" >/dev/null
}

# The workspace detail changes education is useful during normal use, but it
# is transient chrome rather than listing content. Dismiss it from each real
# detail capture and fail if it survives, so a stale hint cannot leak into an
# App Store screenshot.
changes_hint_dismiss_xy() {
  axe describe-ui --udid "$UDID" 2>/dev/null | python3 -c '
import json, sys
tree = json.load(sys.stdin)
def walk(n):
    yield n
    for c in n.get("children") or []:
        yield from walk(c)
for root in tree:
    for n in walk(root):
        identifier = n.get("AXUniqueId") or n.get("AXIdentifier")
        if identifier != "MobileChangesHint":
            continue
        for child in walk(n):
            if child is n:
                continue
            if (child.get("AXLabel") or "").strip().lower() != "dismiss":
                continue
            f = child.get("frame")
            if f:
                x, y = f["x"], f["y"]
                width, height = f["width"], f["height"]
                print(f"{x + width / 2:.0f} {y + height / 2:.0f}")
                raise SystemExit
        # SwiftUI may flatten the button out of the identifier subtree.
        f = n.get("frame")
        if f:
            x, y = f["x"], f["y"]
            width, height = f["width"], f["height"]
            print(f"{x + width - 36:.0f} {y + height / 2:.0f}")
            raise SystemExit
raise SystemExit(1)
'
}

changes_hint_present() {
  axe describe-ui --udid "$UDID" 2>/dev/null | python3 -c '
import json, sys
tree = json.load(sys.stdin)
def walk(n):
    yield n
    for c in n.get("children") or []:
        yield from walk(c)
for root in tree:
    for n in walk(root):
        identifier = n.get("AXUniqueId") or n.get("AXIdentifier")
        label = (n.get("AXLabel") or "").lower()
        if identifier == "MobileChangesHint" or "review this workspace" in label:
            raise SystemExit(0)
raise SystemExit(1)
'
}

dismiss_changes_hint() {
  local xy
  xy="$(changes_hint_dismiss_xy || true)"
  if [ -n "$xy" ]; then
    axe tap -x "${xy%% *}" -y "${xy##* }" --udid "$UDID" >/dev/null
    sleep 0.5
  fi
  if changes_hint_present; then
    echo "workspace changes education banner remained in a real capture" >&2
    return 1
  fi
}

# Readiness beats fixed sleeps: reconnect and hydration times vary.
wait_label() { # wait_label <label> [timeout-s] [mode]
  local label="$1" timeout="${2:-45}" mode="${3:-prefix}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if ax_find "$label" "$mode" >/dev/null 2>&1; then return 0; fi
    sleep 2; waited=$((waited + 2))
  done
  echo "wait_label: '$label' absent after ${timeout}s" >&2
  return 1
}

prompt_value() {
  axe describe-ui --udid "$UDID" 2>/dev/null | python3 -c '
import json, sys
tree = json.load(sys.stdin)
def walk(n):
    yield n
    for c in n.get("children") or []:
        yield from walk(c)
for root in tree:
    for n in walk(root):
        if n.get("AXUniqueId") == "MobileTaskComposerPrompt":
            print(n.get("AXValue") or "")
            raise SystemExit
'
}

reply_value() {
  axe describe-ui --udid "$UDID" 2>/dev/null | python3 -c '
import json, sys
tree = json.load(sys.stdin)
def walk(n):
    yield n
    for c in n.get("children") or []:
        yield from walk(c)
for root in tree:
    for n in walk(root):
        value = n.get("AXValue")
        if value:
            print(value)
'
}

clear_focused_text() {
  # SpringBoard's inline field does not consistently honor Cmd+A. Repeated
  # backspaces are slower but deterministic for this short, newly focused
  # reply field and prevent a fallback from appending to a partial injection.
  for _ in $(seq 1 80); do
    axe key 42 --udid "$UDID" >/dev/null 2>&1 || true
  done
}

# Use the simulator pasteboard for the prompt. HID text injection can lose or
# reorder characters in SwiftUI TextEditor, which is unacceptable in a store
# screenshot. The simulator's Cmd+A/Cmd+V path is stable across phone and iPad
# and avoids lossy per-character HID injection.
set_prompt() {
  printf '%s' "$PROMPT_TEXT" | xcrun simctl pbcopy "$UDID"
  axe tap --id MobileTaskComposerPrompt --udid "$UDID" >/dev/null
  axe key-combo --modifiers 227 --key 4 --udid "$UDID" >/dev/null
  axe key-combo --modifiers 227 --key 25 --udid "$UDID" >/dev/null
  local actual
  sleep 0.8
  actual="$(prompt_value)"
  if [ "$actual" != "$PROMPT_TEXT" ]; then
    echo "prompt text mismatch after paste (got $(printf '%q' "$actual"), want $(printf '%q' "$PROMPT_TEXT"))" >&2
    return 1
  fi
}

# Open the real repository picker, assert it exposes a usable directory and
# contains no error state, then return to the composer without changing the
# prompt. This is the guard for the previous `Mac unavailable` screenshot.
validate_picker() {
  tap_label "Task Options" exact
  sleep 1
  local tree actual
  tree="$(axe describe-ui --udid "$UDID" 2>/dev/null)"
  if python3 -c "import re,sys; sys.exit(0 if re.search(r'\"AXLabel\"\\s*:\\s*\".*(error|failed|unavailable|not available).*\"', sys.stdin.read(), re.I) else 1)" <<<"$tree"; then
    echo "repository picker rendered an error state" >&2
    return 1
  fi
  axe tap --id MobileTaskComposerDirectory --udid "$UDID" >/dev/null
  sleep 1
  tree="$(axe describe-ui --udid "$UDID" 2>/dev/null)"
  if python3 -c "import re,sys; sys.exit(0 if re.search(r'\"AXLabel\"\\s*:\\s*\".*(error|failed|unavailable|not available).*\"', sys.stdin.read(), re.I) else 1)" <<<"$tree"; then
    echo "repository picker rendered an error state" >&2
    return 1
  fi
  python3 -c 'import sys; sys.exit(0 if "MobileTaskDirectoryRecent" in sys.stdin.read() else 1)' <<<"$tree" || {
    echo "repository picker has no recent directories" >&2
    return 1
  }
  axe tap --id MobileTaskDirectoryPickerCancel --udid "$UDID" >/dev/null
  axe tap --id MobileTaskComposerOptionsDoneButton --udid "$UDID" >/dev/null
  sleep 1
  actual="$(prompt_value)"
  [ "$actual" = "$PROMPT_TEXT" ] || {
    echo "prompt changed while validating repository picker" >&2
    return 1
  }
}

back_to_list() {
  # iPad keeps the workspace sidebar visible while the detail pane changes;
  # there is no navigation back stack to pop between shots. Tapping the
  # Workspaces tab here would collapse the split view and lose the rows needed
  # by the next capture.
  if [ "$CLASS" = ipad ]; then
    return 0
  fi
  tap_label "Back" exact 2>/dev/null || tap_label "Workspaces" exact 2>/dev/null || true
  wait_label "Checkout flow" 30 || true
  sleep 1
}

echo "== capture-real ($CLASS) on $UDID -> $OUT"

# The app must already be signed in and paired; fail loudly otherwise.
if [ "$CLASS" = ipad ]; then
  # iPad can launch with its sidebar collapsed after a reconnect. The real
  # workspace rows are the readiness signal for this split-view lane.
  tap_label "Show Sidebar" exact 2>/dev/null || true
  sleep 1
fi
wait_label "Checkout flow" 60 || {
  echo "workspace list not ready; run scripts/mobile-dev-launch.sh --tag <tag> --simulator-id $UDID first" >&2
  exit 1
}

# 03: workspace list.
sleep 2
shot 03-Workspaces

# 01/02/07: real agent sessions.
open_session() { # open_session <row-label> <shot-name>
  wait_label "$1" 30 exact
  tap_label "$1"
  sleep 5
  dismiss_changes_hint
  shot "$2"
  back_to_list
}
open_session "Checkout flow" 01-Claude
open_session "API migration" 02-Codex
open_session "Auth API" 07-Opencode

# 06: per-file diff via the Auth API session's changes chip, then a file row.
tap_label "Auth API"
sleep 4
dismiss_changes_hint
tap_label "Changes:" prefix
sleep 3
XY="$(axe describe-ui --udid "$UDID" 2>/dev/null | python3 -c "
import json, sys
def walk(n):
    yield n
    for c in n.get('children') or []:
        yield from walk(c)
best = None
for root in json.load(sys.stdin):
    for n in walk(root):
        lab = (n.get('AXLabel') or '')
        if any(x in lab for x in ('.ts', '.tsx', '.swift', '.html', '.md')):
            f = n['frame']
            best = (f['x'] + f['width']/2, f['y'] + f['height']/2)
            break
    if best: break
if not best: sys.exit(1)
print(f'{best[0]:.0f} {best[1]:.0f}')
")" && axe tap -x "${XY%% *}" -y "${XY##* }" --udid "$UDID" >/dev/null
sleep 3
shot 06-DiffFile
# Dismiss the diff/changes stack, then leave the session.
tap_label "Back" exact 2>/dev/null || true; sleep 1
tap_label "Close" exact 2>/dev/null || tap_label "Done" exact 2>/dev/null || true; sleep 1
back_to_list

# 04: notifications tab, then return.
tap_label "Notifications"
sleep 3
shot 04-Notifications
tap_label "Workspaces"
sleep 2

# 08: task composer, prefilled prompt over a real repo picker.
tap_label "New Task"
sleep 3
set_prompt
validate_picker
sleep 1.5
shot 08-Composer
tap_label "Cancel" exact 2>/dev/null || axe swipe --start-x 200 --start-y 300 --end-x 200 --end-y 800 --udid "$UDID" 2>/dev/null || true
sleep 1

# 09: a real system-rendered notification banner is used by the framed iPad
# marketing page. It is deliberately last on iPad because this fixture launch
# replaces the live paired foreground session, just like the lock-shot leg.
if [ "$CLASS" = ipad ]; then
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA=1 \
  SIMCTL_CHILD_CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1 \
  SIMCTL_CHILD_CMUX_UITEST_NOTIFICATION_BANNER=1 \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  sleep 2
  axe tap --label "Allow" --udid "$UDID" >/dev/null 2>&1 || true
  sleep 6
  shot 09-Banner
fi

# 05: lock-screen inline reply (iPhone only). LAST: the fixture launch replaces
# the signed-in foreground session (relaunch through mobile-dev-launch after).
if [ "$CLASS" = "iphone" ] && [ "$SKIP_LOCK" = "0" ]; then
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  # Match the current ASC inline-reply reference. This only changes
  # SpringBoard's system fixture; the live terminal captures stay dark.
  xcrun simctl ui "$UDID" appearance light
  xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi \
    --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
    --batteryState charging --batteryLevel 100
  SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA=1 \
  SIMCTL_CHILD_CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1 \
  SIMCTL_CHILD_CMUX_UITEST_NOTIFICATION_BANNER=reply \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  sleep 2.5
  idb ui button --udid "$UDID" LOCK
  sleep 6
  wait_label "Claude finished" 15 contains || true
  XY="$(ax_find "Claude finished" contains || ax_find "cmux agent" contains || echo "220 680")"
  cx="${XY%% *}"; cy="${XY##* }"
  # Try a real HID long press first. Some simulator runtimes expose the
  # notification's View action only after the notification is swiped left, so
  # use that documented SpringBoard path as a deterministic fallback.
  idb ui tap --udid "$UDID" --duration 1.5 "$cx" "$cy" >/dev/null 2>&1 || true
  sleep 2
  if ! ax_find "View" exact >/dev/null 2>&1 && ! ax_find "Reply" exact >/dev/null 2>&1; then
    axe swipe --start-x 350 --start-y "$cy" --end-x 120 --end-y "$cy" \
      --duration 0.4 --udid "$UDID" >/dev/null
    sleep 1.5
  fi
  if wait_label "View" 8 exact; then
    tap_label "View"
  elif wait_label "Reply" 8 exact; then
    tap_label "Reply"
  else
    echo "lock-screen notification did not expose View or Reply" >&2
    exit 1
  fi
  sleep 1.5
  # The field is newly empty. Prefer IDB, then fall back to axe, and verify the
  # resulting AXValue before saving the screenshot so a dropped character can
  # never reach the listing. Clear between attempts so a partial injection is
  # never accidentally appended to.
  idb ui text --udid "$UDID" "$REPLY_TEXT" >/dev/null 2>&1 || axe type "$REPLY_TEXT" --udid "$UDID"
  sleep 1
  if ! reply_value | grep -Fqx "$REPLY_TEXT"; then
    clear_focused_text
    axe type "$REPLY_TEXT" --udid "$UDID"
    sleep 1
  fi
  if ! reply_value | grep -Fqx "$REPLY_TEXT"; then
    clear_focused_text
    printf '%s' "$REPLY_TEXT" | xcrun simctl pbcopy "$UDID"
    axe key-combo --modifiers 227 --key 4 --udid "$UDID" >/dev/null
    axe key-combo --modifiers 227 --key 25 --udid "$UDID" >/dev/null
    sleep 1
  fi
  reply_value | grep -Fqx "$REPLY_TEXT" || {
    echo "inline reply text mismatch before capture" >&2
    exit 1
  }
  shot 05-LockReply
  # `post` consumes lock shots from the dedicated lockshot directory. Keep the
  # live capture there as well as in the raw capture directory so
  # `--capture-source real` remains a complete, explicit set.
  mkdir -p "$WORK/lockshot"
  cp "$OUT/$PREFIX-05-LockReply.png" "$WORK/lockshot/05-LockReply.png"
  cp "$OUT/$PREFIX-05-LockReply.png" "$WORK/lockshot/05-LockReply-real.png"
  idb ui button --udid "$UDID" LOCK; sleep 1
fi

echo "done: $(ls "$OUT" | grep -c "^$PREFIX-") captures under $OUT"
