#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_PLIST="$REPO_ROOT/Resources/LaunchAgents/com.cmuxterm.app.terminal-backend.plist"
IDENTITY_TOOL="$REPO_ROOT/scripts/terminal-backend-identity.py"
APP_BUNDLE=""
LAUNCH_AGENTS_DIR=""
BUNDLE_ID=""
VERSIONED_PROGRAM_PLACEHOLDER="__CMUX_VERSIONED_BACKEND_PROGRAM__"

usage() {
  echo "Usage: ./scripts/configure-terminal-backend-launch-agent.sh (--app-bundle <path> | --launch-agents-dir <path>) --bundle-id <identifier>"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      APP_BUNDLE="$2"
      shift 2
      ;;
    --launch-agents-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      LAUNCH_AGENTS_DIR="$2"
      shift 2
      ;;
    --bundle-id)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      BUNDLE_ID="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$APP_BUNDLE" && -n "$LAUNCH_AGENTS_DIR" ]]; then
  echo "error: --app-bundle and --launch-agents-dir are mutually exclusive" >&2
  exit 2
fi
if [[ -n "$APP_BUNDLE" ]]; then
  [[ -d "$APP_BUNDLE" ]] || { echo "error: app bundle not found: $APP_BUNDLE" >&2; exit 1; }
  LAUNCH_AGENTS_DIR="$APP_BUNDLE/Contents/Library/LaunchAgents"
fi
[[ -n "$LAUNCH_AGENTS_DIR" ]] || { echo "error: one launch-agent destination is required" >&2; exit 2; }
[[ -n "$BUNDLE_ID" ]] || { echo "error: --bundle-id is required" >&2; exit 2; }
[[ -f "$SOURCE_PLIST" ]] || { echo "error: launch-agent template not found: $SOURCE_PLIST" >&2; exit 1; }
[[ -x "$IDENTITY_TOOL" ]] || { echo "error: terminal backend identity tool not found: $IDENTITY_TOOL" >&2; exit 1; }

IFS=$'\t' read -r NORMALIZED_BUNDLE_ID IDENTITY_TOKEN SERVICE_LABEL PLIST_NAME SESSION_NAME SOCKET_FILE_NAME STATE_NAMESPACE \
  <<< "$("$IDENTITY_TOOL" --bundle-id "$BUNDLE_ID" --format tsv)"
[[ -n "$NORMALIZED_BUNDLE_ID" && -n "$IDENTITY_TOKEN" && -n "$SESSION_NAME" ]] || {
  echo "error: failed to derive terminal backend identity for $BUNDLE_ID" >&2
  exit 2
}

mkdir -p "$LAUNCH_AGENTS_DIR"
DESTINATION="$LAUNCH_AGENTS_DIR/$PLIST_NAME"

# A channel-retagged app can inherit the source app's launch-agent plist.
# Keep exactly the descriptor matching the final bundle identifier.
for stale_plist in "$LAUNCH_AGENTS_DIR"/*.terminal-backend.plist; do
  [[ -e "$stale_plist" ]] || continue
  [[ "$stale_plist" == "$DESTINATION" ]] || rm -f "$stale_plist"
done

/usr/bin/install -m 0644 "$SOURCE_PLIST" "$DESTINATION"
/usr/libexec/PlistBuddy -c "Set :Label $SERVICE_LABEL" "$DESTINATION"
/usr/libexec/PlistBuddy -c "Delete :BundleProgram" "$DESTINATION" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Set :Program $VERSIONED_PROGRAM_PLACEHOLDER" "$DESTINATION" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :Program string $VERSIONED_PROGRAM_PLACEHOLDER" "$DESTINATION"
/usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$DESTINATION" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$DESTINATION"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $VERSIONED_PROGRAM_PLACEHOLDER" "$DESTINATION"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string --headless" "$DESTINATION"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --app-service-layout" "$DESTINATION"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string --session" "$DESTINATION"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string $SESSION_NAME" "$DESTINATION"
/usr/bin/plutil -lint "$DESTINATION" >/dev/null

echo "Configured terminal backend launch agent: $DESTINATION"
echo "  label: $SERVICE_LABEL"
echo "  session: $SESSION_NAME"
