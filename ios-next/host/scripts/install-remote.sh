#!/usr/bin/env bash
# Installs cmux-next-host on a remote Mac over SSH without sudo.
#
#   scripts/install-remote.sh <ssh-alias> [--api https://<backend>]
#
# - Uses ~/.local/bin/node when it is v22+, otherwise installs the latest
#   Node 22 into ~/.local.
# - rsyncs this directory to ~/cmux-next-host (no node_modules, no state).
# - Runs npm ci and the esbuild bundle there.
# - Writes a LaunchAgent plist (com.cmux.next-host) into ~/cmux-next-host but
#   does NOT load it, and does not start the host.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <ssh-alias> [--api https://<backend>]" >&2
  exit 2
fi
ALIAS="$1"
shift
API=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api) API="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="cmux-next-host"

echo "==> Checking Node on $ALIAS"
ssh "$ALIAS" 'bash -s' <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
need_install=1
if [[ -x "$HOME/.local/bin/node" ]]; then
  major="$("$HOME/.local/bin/node" -p 'process.versions.node.split(".")[0]')"
  if [[ "$major" -ge 22 ]]; then need_install=0; fi
fi
if [[ "$need_install" -eq 1 ]]; then
  arch="$(uname -m)"; [[ "$arch" == "x86_64" ]] && arch="x64"
  base="https://nodejs.org/dist/latest-v22.x"
  file="$(curl -fsSL "$base/SHASUMS256.txt" | awk -v a="darwin-$arch.tar.gz" '$2 ~ a {print $2; exit}')"
  sum="$(curl -fsSL "$base/SHASUMS256.txt" | awk -v f="$file" '$2 == f {print $1}')"
  echo "installing $file into ~/.local"
  tmp="$(mktemp -d)"
  curl -fsSL "$base/$file" -o "$tmp/$file"
  echo "$sum  $tmp/$file" | shasum -a 256 -c -
  mkdir -p "$HOME/.local"
  tar -xzf "$tmp/$file" -C "$HOME/.local" --strip-components=1
  rm -rf "$tmp"
fi
echo "node $("$HOME/.local/bin/node" --version) at $HOME/.local/bin/node"
REMOTE

echo "==> Syncing $HOST_DIR to $ALIAS:~/$REMOTE_DIR"
rsync -az --delete \
  --exclude node_modules --exclude dist --exclude '.DS_Store' \
  "$HOST_DIR/" "$ALIAS:$REMOTE_DIR/"

echo "==> npm ci and build on $ALIAS"
ssh "$ALIAS" "bash -s" <<REMOTE
set -euo pipefail
export PATH="\$HOME/.local/bin:\$PATH"
cd "\$HOME/$REMOTE_DIR"
npm ci --no-audit --no-fund
npm run build
chmod +x bin/cmux-next-host.mjs
mkdir -p "\$HOME/.cmux-next-host"
cat > com.cmux.next-host.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.cmux.next-host</string>
  <key>ProgramArguments</key>
  <array>
    <string>\$HOME/.local/bin/node</string>
    <string>\$HOME/$REMOTE_DIR/bin/cmux-next-host.mjs</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>\$HOME</string>
  </dict>
  <key>WorkingDirectory</key><string>\$HOME</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>\$HOME/.cmux-next-host/host.log</string>
  <key>StandardErrorPath</key><string>\$HOME/.cmux-next-host/host.log</string>
</dict>
</plist>
PLIST
./bin/cmux-next-host.mjs status || true
REMOTE

API_ARG="${API:+ --api $API}"
cat <<EOF2

Installed on $ALIAS in ~/$REMOTE_DIR. Nothing was started.

1. Pair the host (prints a code to approve in the app):
   ssh -t $ALIAS '~/.local/bin/node ~/$REMOTE_DIR/bin/cmux-next-host.mjs login${API_ARG:- --api https://<backend>}'

2a. Run in the background with nohup:
   ssh $ALIAS 'cd ~ && nohup ~/.local/bin/node ~/$REMOTE_DIR/bin/cmux-next-host.mjs run >> ~/.cmux-next-host/host.log 2>&1 &'

2b. Or as a user LaunchAgent (restarts on crash and at login):
   ssh $ALIAS 'cp ~/$REMOTE_DIR/com.cmux.next-host.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.cmux.next-host.plist'
   Stop: ssh $ALIAS 'launchctl bootout gui/\$(id -u)/com.cmux.next-host'

Logs: ssh $ALIAS 'tail -f ~/.cmux-next-host/host.log'
Add --relay-only to run to force TURN, --cdp http://127.0.0.1:9222 to use an existing browser.
Agents need the claude or codex CLI logged in on $ALIAS ('claude auth status', 'codex login status').
EOF2
