#!/usr/bin/env bash
# Present a toast inside a RUNNING cmux iOS DEBUG build on a simulator, with
# no touch input (drives ToastDebugTrigger via defaults + a darwin
# notification). DEBUG builds only; physical devices are not supported
# (simctl spawn is simulator-only).
#
# Usage:
#   ios/scripts/toast-debug.sh --udid <udid> --bundle-id <id> \
#     [--style info|success|warning|failure] [--title <t>] --message <m> \
#     [--icon <sf-symbol>] [--bottom] [--persistent] [--action <label>] \
#     [--key <coalescing-key>]
#   ios/scripts/toast-debug.sh --udid <udid> --bundle-id <id> --dismiss-all
set -euo pipefail

UDID="" BUNDLE_ID="" STYLE="info" TITLE="" MESSAGE="" ICON="" PLACEMENT="top"
PERSISTENT="false" ACTION_LABEL="" KEY="" DISMISS_ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --style) STYLE="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --message) MESSAGE="$2"; shift 2 ;;
    --icon) ICON="$2"; shift 2 ;;
    --bottom) PLACEMENT="bottom"; shift ;;
    --persistent) PERSISTENT="true"; shift ;;
    --action) ACTION_LABEL="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --dismiss-all) DISMISS_ALL=1; shift ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$UDID" || -z "$BUNDLE_ID" ]]; then
  echo "error: --udid and --bundle-id are required" >&2
  exit 1
fi

if [[ "$DISMISS_ALL" -eq 1 ]]; then
  xcrun simctl spawn "$UDID" notifyutil -p dev.cmux.toast.debug.dismiss
  echo "dismissed all toasts on $BUNDLE_ID"
  exit 0
fi

if [[ -z "$MESSAGE" ]]; then
  echo "error: --message is required (or use --dismiss-all)" >&2
  exit 1
fi

SPEC="$(python3 - "$STYLE" "$TITLE" "$MESSAGE" "$ICON" "$PLACEMENT" "$PERSISTENT" "$ACTION_LABEL" "$KEY" <<'EOF'
import json, sys
style, title, message, icon, placement, persistent, action, key = sys.argv[1:9]
spec = {"style": style, "message": message, "placement": placement}
if title: spec["title"] = title
if icon: spec["systemImage"] = icon
if persistent == "true": spec["persistent"] = True
if action: spec["actionLabel"] = action
if key: spec["coalescingKey"] = key
print(json.dumps(spec))
EOF
)"

# -string: without it, defaults parses the JSON braces as a plist dictionary.
xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" cmux.debug.toast -string "$SPEC"
xcrun simctl spawn "$UDID" notifyutil -p dev.cmux.toast.debug.present
echo "presented: $SPEC"
