#!/usr/bin/env bash
# Install the per-user LaunchAgent that drains the iPhone install queue
# (scripts/iphone-install-queue.sh) the moment the phone reappears.
#
#   scripts/install-iphone-queue-agent.sh [install] [--checkout <dir>]
#   scripts/install-iphone-queue-agent.sh uninstall
#   scripts/install-iphone-queue-agent.sh status
#
# Triggers (in order of latency):
#   1. launchd IOKit matching (com.apple.iokit.matching) on Apple USB device
#      attach (idVendor 0x05AC): plugging the iPhone in starts a drain within
#      seconds, no polling involved.
#   2. WatchPaths on the queue's pending/ dir: an enqueue immediately attempts
#      a drain (covers "phone was reachable all along" races).
#   3. StartInterval backstop for the phone REAPPEARING ON THE NETWORK (WiFi
#      debugging), which emits no IOKit USB event. The drain is a fast no-op
#      when the queue is empty, and while non-empty each drain run itself polls
#      (--wait/--interval), so reconnects land within ~10s.
#
# The agent runs stable copies of the queue, process, credential, attach, and
# mobile-launch tools from the queue dir. A queued feature worktree supplies
# source/debug-CLI context only, never the auth policy implementation.
#
# --checkout bakes CMUX_IPHONE_QUEUE_CHECKOUT into the agent as fallback source
# context when an enqueuing worktree is pruned. Defaults to this repo root.
set -euo pipefail

LABEL="dev.cmux.iphone-install-queue"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
QUEUE_DIR="${CMUX_IPHONE_QUEUE_DIR:-$HOME/Library/Application Support/cmux-dev/iphone-install-queue}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUI_DOMAIN="gui/$(id -u)"

usage() { sed -n '2,27p' "$0"; }

cmd_status() {
  if launchctl print "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "LaunchAgent $LABEL is loaded ($PLIST)"
    launchctl print "$GUI_DOMAIN/$LABEL" 2>/dev/null | grep -E 'state|last exit code|program ' || true
  else
    echo "LaunchAgent $LABEL is NOT loaded"
    return 1
  fi
}

cmd_uninstall() {
  launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "uninstalled $LABEL"
}

cmd_install() {
  local checkout="$REPO_ROOT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --checkout) checkout="${2:-}"; shift 2 ;;
      *) echo "install: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  [[ -x "$checkout/scripts/cmux-debug-cli.sh" ]] \
    || { echo "error: --checkout $checkout has no scripts/cmux-debug-cli.sh" >&2; exit 1; }
  for required in \
      "$SCRIPT_DIR/iphone-install-queue.sh" \
      "$SCRIPT_DIR/ios-device-process.sh" \
      "$SCRIPT_DIR/mobile-dev-launch.sh" \
      "$SCRIPT_DIR/lib/dev-secrets.sh" \
      "$SCRIPT_DIR/lib/mobile-attach.sh"; do
    [[ -f "$required" ]] || { echo "error: missing queue control-plane file: $required" >&2; exit 1; }
  done

  mkdir -p "$QUEUE_DIR/bin/lib" "$QUEUE_DIR/logs" "$QUEUE_DIR/pending" \
    "$HOME/Library/LaunchAgents"
  install -m 0755 "$SCRIPT_DIR/iphone-install-queue.sh" "$QUEUE_DIR/bin/iphone-install-queue.sh"
  install -m 0755 "$SCRIPT_DIR/ios-device-process.sh" "$QUEUE_DIR/bin/ios-device-process.sh"
  install -m 0755 "$SCRIPT_DIR/mobile-dev-launch.sh" "$QUEUE_DIR/bin/mobile-dev-launch.sh"
  install -m 0644 "$SCRIPT_DIR/lib/dev-secrets.sh" "$QUEUE_DIR/bin/lib/dev-secrets.sh"
  install -m 0644 "$SCRIPT_DIR/lib/mobile-attach.sh" "$QUEUE_DIR/bin/lib/mobile-attach.sh"

  # idVendor 1452 = 0x05AC (Apple). Matching any Apple USB device is fine: the
  # drain exits immediately when the queue is empty or the device is not the
  # configured iPhone.
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$QUEUE_DIR/bin/iphone-install-queue.sh</string>
    <string>drain</string>
    <string>--wait</string>
    <string>600</string>
    <string>--interval</string>
    <string>10</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$HOME/.local/bin</string>
    <key>CMUX_IPHONE_QUEUE_DIR</key>
    <string>$QUEUE_DIR</string>
    <key>CMUX_IPHONE_QUEUE_CHECKOUT</key>
    <string>$checkout</string>
  </dict>
  <key>LaunchEvents</key>
  <dict>
    <key>com.apple.iokit.matching</key>
    <dict>
      <key>dev.cmux.iphone.usb-attach</key>
      <dict>
        <key>IOProviderClass</key><string>IOUSBHostDevice</string>
        <key>idVendor</key><integer>1452</integer>
        <key>IOMatchLaunchStream</key><true/>
      </dict>
    </dict>
  </dict>
  <key>WatchPaths</key>
  <array>
    <string>$QUEUE_DIR/pending</string>
  </array>
  <key>StartInterval</key><integer>30</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$QUEUE_DIR/logs/agent.log</string>
  <key>StandardErrorPath</key><string>$QUEUE_DIR/logs/agent.log</string>
</dict>
</plist>
PLIST

  launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$GUI_DOMAIN" "$PLIST"
  launchctl enable "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
  echo "installed $LABEL"
  echo "  plist:    $PLIST"
  echo "  script:   $QUEUE_DIR/bin/iphone-install-queue.sh"
  echo "  checkout: $checkout"
  cmd_status || true
}

verb="${1:-install}"
case "$verb" in
  install) shift || true; cmd_install "$@" ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *)
    # Bare flags mean install (e.g. `install-iphone-queue-agent.sh --checkout X`).
    case "$verb" in
      --*) cmd_install "$@" ;;
      *) echo "unknown verb: $verb" >&2; usage >&2; exit 2 ;;
    esac
    ;;
esac
