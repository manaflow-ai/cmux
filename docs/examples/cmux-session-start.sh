#!/bin/bash
# Hook: Reset cmux workspace name on new Claude Code session
# Triggered on: SessionStart
# Clears any previous /rename workspace override so cmux's native
# auto-title (via OSC 2) can take effect for the new session.
set -e

INPUT=$(cat)

[ -z "$CMUX_WORKSPACE_ID" ] && exit 0
command -v cmux &>/dev/null || exit 0

# Extract session cwd for a reasonable default workspace name
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || true)

if [ -n "$CWD" ]; then
  # Use basename of cwd as temporary workspace name
  # cmux's native auto-title will override this once Claude generates a session title
  BASENAME=$(basename "$CWD")
  cmux rename-workspace "$BASENAME" 2>/dev/null || true
fi
