#!/bin/bash
# Installs the nightly Daybreak audit as a LaunchAgent (04:23 daily). Copies nightly.sh and
# prompt.md to ~/Library/Application Support/cmux-daybreak so launchd never runs a file that
# a later fetch or checkout changed. Rerun after editing them. --uninstall removes the agent.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEST="$HOME/Library/Application Support/cmux-daybreak"
PLIST="$HOME/Library/LaunchAgents/ai.manaflow.cmux-daybreak-nightly.plist"
if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"; echo "uninstalled (reports and state kept in $DEST)"; exit 0
fi
mkdir -p "$DEST" "$HOME/Library/Logs/cmux-daybreak"; chmod 700 "$DEST"
install -m 0700 "$SRC/nightly.sh" "$DEST/nightly.sh"
install -m 0600 "$SRC/prompt.md" "$DEST/prompt.md"
sed "s|__HOME__|$HOME|g" "$SRC/ai.manaflow.cmux-daybreak-nightly.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $PLIST (daily 04:23); run now: launchctl kickstart gui/$(id -u)/ai.manaflow.cmux-daybreak-nightly"
