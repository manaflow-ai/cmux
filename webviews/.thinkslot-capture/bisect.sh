#!/usr/bin/env bash
# Scratch (not committed): which file moves the tray rest gap.
set -uo pipefail
cd "$(dirname "$0")/.."
base="$1"
git cat-file -e "$base^{commit}" 2>/dev/null || git fetch -q --depth=1 origin "$base"
T="test/agent-pane-turn-end-at-latest.test.ts test/agent-pane-composer-rest-gap.test.ts"
C=src/agent-session/acpmux/conversation
run() { echo "=== $1"; bun test $T 2>&1 | grep -E "^\(fail\)|^ *[0-9]+ (pass|fail)$|Received: [0-9]"; git checkout -q HEAD -- src; }
run head
git checkout -q "$base" -- $C/ActivityLine.tsx; run "ActivityLine base"
git checkout -q "$base" -- $C/WorkingFor.tsx; run "WorkingFor base"
git checkout -q "$base" -- $C/conversation.css; run "conversation.css base"
git checkout -q "$base" -- $C/Thinking.tsx src/agent-session/acpmux/rows/ThinkingRow.tsx; run "Thinking+Row base"
git checkout -q "$base" -- $C/turns.ts; run "turns base"
git checkout -q "$base" -- src; run "all src base"
