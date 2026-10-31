#!/usr/bin/env bash
# Install or update the owned nightly-ops runners on one Mac mini.
#
#   scripts/ci/nightly-ops-install.sh HOST [COUNT]
#
# Nightlies never use Blacksmith (Lawrence, 2026-10-30). The nightly jobs that
# need no Xcode build (decide, pickers, feed reads and writes, publishers,
# notarization polls) run on COUNT repository runners per host (default 4),
# label `cmux-nightly-ops`, no default labels, outside glaeda's directories
# (actions-runner-nightly-ops-N, never actions-runner-glaeda*), so glaeda's
# unit ledger never bills them as compiles. Every job passes
# scripts/ci/nightly_ops_runner.py admit first (nightly workflows on main,
# nightly-next or feat-cmux-next only). Install on at least two hosts: the
# pool must never be one machine.
#
# Run from a checkout on a machine with `gh` (repo admin) and SSH to cmux@HOST.
# Idempotent: re-running updates the hook and LaunchAgents and keeps
# already-registered runners. It never touches other runners or caches.
set -euo pipefail

host="${1:?usage: nightly-ops-install.sh HOST [COUNT]}"
count="${2:-4}"
repo="manaflow-ai/cmux"
label="cmux-nightly-ops"
here="$(cd "$(dirname "$0")" && pwd)"
short="${host%%.*}"

version="$(gh api repos/actions/runner/releases/latest --jq .tag_name)"
version="${version#v}"

ssh "cmux@$host" 'mkdir -p ~/nightly-ops ~/Library/LaunchAgents ~/Library/Logs'
scp -q "$here/nightly_ops_runner.py" "cmux@$host:nightly-ops/nightly_ops_runner.py"
# The reel (publish-nightly-reel) needs ffmpeg and fontconfig; no job installs software.
ssh "cmux@$host" 'export PATH=/opt/homebrew/bin:$PATH; command -v ffmpeg >/dev/null && command -v fc-match >/dev/null || brew install --quiet ffmpeg fontconfig'

for n in $(seq 1 "$count"); do
  token="$(gh api -X POST "repos/${repo}/actions/runners/registration-token" --jq .token)"
  # The token is passed on stdin so it never shows in a process list or log.
  { printf '%s\n' "$token"; sed -n '/^# ---- remote ----$/,$p' "$0"; } | ssh "cmux@$host" \
    NAME="${short}-nightly-ops-${n}" DIR="actions-runner-nightly-ops-${n}" LABELS="$label" \
    VERSION="$version" REPO="$repo" \
    "bash -c 'read -r TOKEN; export TOKEN; exec bash -s'"
done
exit 0

# ---- remote ----
set -euo pipefail
dir="$HOME/$DIR"
mkdir -p "$dir"
cd "$dir"
if [ ! -x bin/Runner.Listener ]; then
  curl -fsSL -o runner.tgz "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-osx-arm64-${VERSION}.tar.gz"
  tar xzf runner.tgz && rm runner.tgz
fi
cat > job-started.sh <<EOF
#!/bin/bash
# Fails closed: only nightly workflows on trusted refs run here.
exec /usr/bin/python3 "$HOME/nightly-ops/nightly_ops_runner.py" admit
EOF
chmod +x job-started.sh
cat > .env <<EOF
LANG=en_US.UTF-8
PATH=/opt/homebrew/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ACTIONS_RUNNER_HOOK_JOB_STARTED=$dir/job-started.sh
EOF
if [ ! -f .runner ]; then
  ./config.sh --unattended --url "https://github.com/${REPO}" --token "$TOKEN" \
    --name "$NAME" --labels "$LABELS" --no-default-labels --work _work --replace
fi
uid="$(id -u)"
domain="gui/$uid"
launchctl print "$domain" >/dev/null 2>&1 || domain="user/$uid"
agent="ai.manaflow.nightly-ops.$NAME"
plist="$HOME/Library/LaunchAgents/$agent.plist"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$agent</string>
<key>ProgramArguments</key><array><string>$dir/run.sh</string></array>
<key>WorkingDirectory</key><string>$dir</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>$HOME/Library/Logs/$agent.log</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/$agent.err</string>
</dict></plist>
EOF
launchctl bootout "$domain/$agent" 2>/dev/null || true
launchctl bootstrap "$domain" "$plist"
echo "installed $NAME ($dir) in $domain"
