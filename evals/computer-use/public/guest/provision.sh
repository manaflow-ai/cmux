#!/bin/bash
# provision.sh: runs once inside the golden VM (SIP already off), as the
# auto-login user `admin`, from ~/cub-assets (copied in by tart/golden.sh).
# Installs Codex (CLI, Computer Use app, bundled plugins) and the cmux build,
# pre-grants TCC, and quiets the desktop so every attempt starts the same way.
set -euo pipefail
A=$HOME/cub-assets
PW=${GUEST_PASS:-admin}
sudo_() { echo "$PW" | sudo -S -p '' "$@"; }

# --- Codex -----------------------------------------------------------------
mkdir -p ~/.codex/packages/standalone ~/.codex/plugins ~/.codex/computer-use ~/.local/bin
rm -rf ~/.codex/packages/standalone/current
cp -R "$A/codex-standalone" ~/.codex/packages/standalone/current
ln -sf ~/.codex/packages/standalone/current/bin/codex ~/.local/bin/codex
rm -rf ~/.codex/plugins/cache "$HOME/.codex/computer-use/Codex Computer Use.app"
cp -R "$A/codex-plugins" ~/.codex/plugins/cache
cp -R "$A/Codex Computer Use.app" ~/.codex/computer-use/
cp "$A/codex-config.toml" ~/.codex/config.toml
[[ -f $A/codex-auth.json ]] && cp "$A/codex-auth.json" ~/.codex/auth.json && chmod 600 ~/.codex/auth.json
xattr -dr com.apple.quarantine ~/.codex 2>/dev/null || true

# --- cmux ------------------------------------------------------------------
if [[ -d $A/cmux.app ]]; then
  app_name=$(cat "$A/cmux-app-name")
  sudo_ rm -rf "/Applications/$app_name"
  sudo_ cp -R "$A/cmux.app" "/Applications/$app_name"
  sudo_ xattr -dr com.apple.quarantine "/Applications/$app_name" 2>/dev/null || true
fi

# cmux settings for the benchmark: no person is at the VM, so no takeover
# pause, and the deny list is emptied so cmux may use every app the tasks
# name (Terminal and System Settings are on its default list; Codex Computer
# Use has no such list). The cmux Remote helper's grants are below (TCC).
mkdir -p ~/.config/cmux
cat > ~/.config/cmux/cmux-next.json <<'JSON'
{
  "computerUse": {
    "mode": "fullAccess",
    "deniedApps": [],
    "pauseOnTakeover": false,
    "showCursor": true
  }
}
JSON
# Start the app once so its daemon stages cmux Remote, then quit it; the
# staged helper's bundle id gets the grants below.
if [[ -f $A/cmux-app-name ]]; then
  open -g -a "/Applications/$(cat "$A/cmux-app-name")" || true
fi

# --- VS Code and Obsidian (MacAgentBench vscode/obsidian tasks) ---------------
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
/opt/homebrew/bin/brew install --cask --quiet visual-studio-code obsidian || true
# No "downloaded from the Internet" prompt on first launch (it blocks open -g).
sudo_ xattr -dr com.apple.quarantine "/Applications/Visual Studio Code.app" "/Applications/Obsidian.app" 2>/dev/null || true

# --- TCC ---------------------------------------------------------------------
SYS=/Library/Application\ Support/com.apple.TCC/TCC.db
USR=$HOME/Library/Application\ Support/com.apple.TCC/TCC.db
now=$(date +%s)
grant() {  # grant DB SERVICE CLIENT CLIENT_TYPE [INDIRECT]
  local db=$1 svc=$2 client=$3 ctype=$4 ind=${5:-UNUSED} itype=0
  [[ $ind != UNUSED ]] && itype=0
  sudo_ sqlite3 "$db" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier_type,indirect_object_identifier,flags,last_modified) VALUES ('$svc','$client',$ctype,2,4,1,$itype,'$ind',0,$now);"
}
# Bundle ids of every computer-use host: Codex's service, client and lock
# guardian; cmux (the app and its cmux Remote helper, read from the bundle).
cu_ids=(com.openai.sky.CUAService com.openai.sky.CUAService.cli com.openai.sky.CUAService.guardian)
if [[ -f $A/cmux-bundle-ids ]]; then
  while read -r id; do [[ -n $id ]] && cu_ids+=("$id"); done < "$A/cmux-bundle-ids"
fi
for id in "${cu_ids[@]}"; do
  for svc in kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent kTCCServiceListenEvent; do
    grant "$SYS" "$svc" "$id" 0
  done
done
# cmux Remote asks for Local Network access on first start and does not report
# ready until it is answered: pre-allow it for the helper and the app.
for id in com.cmuxterm.remote.dev $(cat "$A/cmux-bundle-ids" 2>/dev/null); do
  grant "$USR" kTCCServiceLocalNetwork "$id" 0
done

# The benchmark's setup and checkers run over SSH and drive apps with
# AppleScript and read their data: Apple Events to every app, and full disk access.
ssh_clients=(/usr/libexec/sshd-keygen-wrapper /usr/sbin/sshd /bin/bash /bin/zsh /usr/bin/osascript)
for c in "${ssh_clients[@]}"; do
  grant "$SYS" kTCCServiceSystemPolicyAllFiles "$c" 1
  grant "$SYS" kTCCServiceAccessibility "$c" 1
done
targets=(com.apple.iCal com.apple.Notes com.apple.reminders com.apple.systemevents com.apple.finder
  com.apple.Safari com.apple.systempreferences com.apple.clock com.apple.TextEdit com.apple.Terminal
  com.apple.AddressBook com.apple.Music com.apple.Preview com.microsoft.VSCode md.obsidian
  com.apple.ScriptEditor2 com.apple.Photos com.apple.mail com.apple.Maps)
for c in "${ssh_clients[@]}"; do
  for t in "${targets[@]}"; do grant "$USR" kTCCServiceAppleEvents "$c" 1 "$t"; done
  for svc in kTCCServiceCalendar kTCCServiceReminders kTCCServiceAddressBook; do grant "$USR" "$svc" "$c" 1; done
done

# --- a quiet, identical desktop ------------------------------------------------
sudo_ pmset -a sleep 0 displaysleep 0 disksleep 0
defaults -currentHost write com.apple.screensaver idleTime 0
sudo_ defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0
defaults write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
defaults write com.apple.dock autohide -bool false
# First launch of each benchmark app once (bounded), so their first-run state
# is the same for every arm; then quit every app, so each attempt starts on an
# empty desktop.
for app in Calendar Notes Reminders Safari Clock TextEdit "Visual Studio Code" Obsidian; do
  ( open -g -a "$app" 2>/dev/null & p=$!; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 $p 2>/dev/null || break; /bin/sleep 1; done; kill $p 2>/dev/null ) || true
done
/bin/sleep 5
keep='^(Finder|Dock|SystemUIServer|WindowManager|ControlCenter|NotificationCenter|loginwindow)$'
for name in $(lsappinfo list | sed -n 's/.*"\(.*\)" ASN.*/\1/p' | sort -u); do
  [[ $name =~ $keep ]] && continue
  pkill -x "$name" 2>/dev/null || true
done
# Dismiss pending notification banners and the "What's new" welcome.
defaults write com.apple.ncprefs dnd_prefs -data 0 2>/dev/null || true
killall NotificationCenter 2>/dev/null || true
echo provisioned
