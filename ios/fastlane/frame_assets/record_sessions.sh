#!/usr/bin/env bash
# Record REAL agent-session screens for the App Store terminal screenshots.
#
# Runs each agent CLI (claude, codex, opencode, pi) for real in a tmux pane sized
# to the iOS terminal grid, captures the rendered screen (with ANSI colors) via
# `tmux capture-pane -e -p`, strips update/banner noise, and regenerates the
# base64-embedded fixtures in
#   Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TerminalPreviewTranscripts.swift
#
# Requires: tmux, and the agent CLIs installed + authenticated locally. The
# screenshot CI does NOT run this (it replays the committed fixtures), so no
# agent credentials are needed on the build runner. Re-run this when you want to
# refresh the captured sessions.
#
# Usage: ios/fastlane/frame_assets/record_sessions.sh [cols] [rows]
set -euo pipefail

COLS="${1:-56}"
ROWS="${2:-40}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)/sessions"
mkdir -p "$OUT"
SANDBOX="$(mktemp -d)/app"
mkdir -p "$SANDBOX"
cat > "$SANDBOX/main.swift" <<'SWIFT'
import UIKit
final class ContentView: UIView {}
SWIFT
printf '# Demo app\n' > "$SANDBOX/README.md"
( cd "$SANDBOX" && git init -q 2>/dev/null || true )

PROMPT='in one short sentence, what does main.swift do? do not edit anything'

record() {
  local agent="$1"; local launch="$2"
  echo "recording ${agent}…"
  tmux kill-session -t cmuxrec 2>/dev/null || true
  tmux new-session -d -s cmuxrec -x "$COLS" -y "$ROWS"
  tmux send-keys -t cmuxrec "cd '$SANDBOX' && clear && $launch" Enter
  for _ in $(seq 1 20); do
    sleep 6
    local txt; txt="$(tmux capture-pane -t cmuxrec -p 2>/dev/null || true)"
    if [[ "$txt" =~ ContentView|UIKit|UIView|displays|renders ]]; then
      break
    fi
    if [[ "$txt" =~ trust|Yes,|continue|theme|login ]]; then
      tmux send-keys -t cmuxrec Enter
    fi
  done
  sleep 3
  tmux capture-pane -t cmuxrec -e -p > "$OUT/$agent.ans"
  perl -0pi -e 's/(?:[ \t]*\r?\n)+\z/\n/' "$OUT/$agent.ans"
  tmux kill-session -t cmuxrec 2>/dev/null || true
}

record claude   "claude '$PROMPT'"
record codex    "codex '$PROMPT'"
record opencode "opencode '$PROMPT'"
record pi       "pi '$PROMPT'"

mkdir -p "$HERE/streamed"
cp "$OUT"/*.ans "$HERE/streamed/"
python3 "$HERE/embed_sessions.py" "$OUT"
echo "done. Review the diff in TerminalPreviewTranscripts.swift."
