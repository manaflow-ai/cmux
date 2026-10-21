#!/bin/bash
# Claude Code PreToolUse(Bash) hook: refuses merging a feat-cmux-next PR that changes Swift before its
# head's Release compile passed (merge_compile_guard.py --claude-hook). Every command that merges no
# pull request exits here without starting Python.
input=$(</dev/stdin)
case $input in
  *"pr merge"*|*"/merge"*) printf '%s' "$input" | exec python3 -I "${BASH_SOURCE[0]%/*}/merge_compile_guard.py" --claude-hook ;;
esac
exit 0
