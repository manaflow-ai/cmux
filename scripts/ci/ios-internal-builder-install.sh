#!/usr/bin/env bash
# Install or update the cmux-next INTERNAL iOS TestFlight builder on one Mac mini.
# Design: plans/cmux-next/ios-testflight-builder-DESIGN.md.
#
#   scripts/ci/ios-internal-builder-install.sh cmux9s-mac-mini
#
# Run from a checkout on a machine with `gh` (repo admin) and SSH to the host.
# Idempotent: re-running updates the scripts and LaunchAgents and keeps an
# already-registered runner. It never touches other runners or caches.
set -euo pipefail

host="${1:?usage: ios-internal-builder-install.sh HOST}"
repo="manaflow-ai/cmux"
name="${host}-ios-internal"
labels="glaeda-runner-${name},glaeda-ios-internal-next"
here="$(cd "$(dirname "$0")" && pwd)"

version="$(gh api repos/actions/runner/releases/latest --jq .tag_name)"
version="${version#v}"
token="$(gh api -X POST "repos/${repo}/actions/runners/registration-token" --jq .token)"

ssh "$host" 'mkdir -p ~/ios-internal-builder ~/Library/LaunchAgents ~/Library/Logs'
scp -q "$here/ios_internal_builder.py" "$host:ios-internal-builder/ios_internal_builder.py"

# The token is passed on stdin so it never shows in a process list or log.
{ printf '%s\n' "$token"; sed -n '/^# ---- remote ----$/,$p' "$0"; } | ssh "$host" \
  NAME="$name" LABELS="$labels" VERSION="$version" REPO="$repo" \
  "bash -c 'read -r TOKEN; export TOKEN; exec bash -s'"
echo "Point the iOS archive at it:"
echo "  gh variable set CI_IOS_INTERNAL_RUNNER -R $repo --body glaeda-runner-${name}"
exit 0

# ---- remote ----
set -euo pipefail
dir="$HOME/actions-runner-ios-internal"
mkdir -p "$dir"
cd "$dir"
if [ ! -x bin/Runner.Listener ]; then
  curl -fsSL -o runner.tgz "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-osx-arm64-${VERSION}.tar.gz"
  tar xzf runner.tgz && rm runner.tgz
fi
cat > job-started.sh <<EOF
#!/bin/bash
# Fails closed: only ios-internal-nightly.yml archive, dispatched on rc/cnx-ios-builder, runs here.
exec /usr/bin/python3 "$HOME/ios-internal-builder/ios_internal_builder.py" admit
EOF
chmod +x job-started.sh
cat > .env <<EOF
LANG=C.UTF-8
PATH=/opt/homebrew/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ACTIONS_RUNNER_HOOK_JOB_STARTED=$dir/job-started.sh
CNX_BUILDS_ROOT=$HOME/cnx-ios-builds
EOF
if [ ! -f .runner ]; then
  ./config.sh --unattended --url "https://github.com/${REPO}" --token "$TOKEN" \
    --name "$NAME" --labels "$LABELS" --no-default-labels --work _work --replace
fi

uid="$(id -u)"
domain="gui/$uid"
launchctl print "$domain" >/dev/null 2>&1 || domain="user/$uid"
write_agent() { # label, program args...
  local label="$1"; shift
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  local args=""
  for a in "$@"; do args="$args<string>$a</string>"; done
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array>$args</array>
<key>WorkingDirectory</key><string>$dir</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>$HOME/Library/Logs/$label.log</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/$label.err</string>
</dict></plist>
EOF
  launchctl bootout "$domain/$label" 2>/dev/null || true
  launchctl bootstrap "$domain" "$plist"
}
write_agent ai.manaflow.ios-internal-builder.runner "$dir/run.sh"
write_agent ai.manaflow.ios-internal-builder.watch /usr/bin/python3 "$HOME/ios-internal-builder/ios_internal_builder.py" watch --loop
echo "installed $NAME in $domain"
