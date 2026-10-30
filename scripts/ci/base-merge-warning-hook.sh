#!/bin/bash
# Claude Code PreToolUse(Bash) hook: warns before `gh api .../pulls/N/update-branch` cancels the PR's
# running CI (base_merge_warning.py --claude-hook). Never blocks. Every other command exits here
# without starting Python.
input=$(</dev/stdin)
case $input in
  *update-branch*) printf '%s' "$input" | exec python3 -I "${BASH_SOURCE[0]%/*}/base_merge_warning.py" --claude-hook ;;
esac
exit 0
