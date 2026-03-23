#!/bin/bash
# Hook: Immediately sync /rename to cmux workspace name
# Triggered on: UserPromptSubmit
# Lightweight — minimal Python for JSON parsing only. Just tail + grep.
set -e

INPUT=$(cat)

[ -z "$CMUX_WORKSPACE_ID" ] && exit 0
command -v cmux &>/dev/null || exit 0

# Extract transcript path
TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || true)
[ -z "$TRANSCRIPT" ] && exit 0
[ -f "$TRANSCRIPT" ] || exit 0

# Fast: grep last custom-title from transcript tail
TITLE=$(tail -500 "$TRANSCRIPT" | grep '"custom-title"' | tail -1 | python3 -c "
import sys,json
try:
    print(json.loads(sys.stdin.readline()).get('customTitle',''))
except: pass
" 2>/dev/null)

[ -z "$TITLE" ] && exit 0

# Only rename if workspace name differs (avoid unnecessary calls)
CURRENT=$(cmux list-workspaces 2>/dev/null | grep '\[selected\]' | sed 's/.*  //;s/  \[selected\]//')
if [ "$CURRENT" != "$TITLE" ]; then
  cmux rename-workspace "$TITLE" 2>/dev/null || true
fi
