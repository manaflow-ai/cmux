#!/usr/bin/env bash
# Claude Code PreToolUse(Bash) guards for cmux, run from the feat-cmux-next tip and never from the
# session's checkout (.claude/settings.json reads this file from origin/feat-cmux-next and runs it).
# A pull request's worktree holds that branch's copy of the guards: a branch made before a guard fix
# kept the old guard, and a pull request could edit the guard that judges its own merge
# (palette-audit, 2026-10-21). So this takes each guard and its hook from origin/feat-cmux-next
# (the settings hook fetched it first for a merge), into a temporary directory:
#   - merge-compile-guard-hook.sh (merge_compile_guard.py): refuses a hand merge of a Swift PR
#     before its Release compile passed;
#   - base-merge-warning-hook.sh (base_merge_warning.py): warns before an update-branch cancels CI.
# The first that answers (a refusal or a note) is the answer; the hook JSON goes to stdout. A merge
# whose guards can't be read from the base is refused.
#
# Usage: printf '%s' "$payload" | bash guards-from-base.sh CHECKOUT
set -uo pipefail
dir="${1:-.}"
input=$(</dev/stdin)
merge=0
case $input in *"pr merge"* | *"/merge"*) merge=1 ;; esac
# A merge the guards can't judge is refused, as merge_compile_guard.py refuses one it can't read;
# the update-branch warning only warns.
cannot() {
  if ((merge)); then
    python3 -I -c 'import json, sys; json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse",
      "permissionDecision": "deny", "permissionDecisionReason": sys.argv[1]}}, sys.stdout)' "$1"
    exit 0
  fi
  echo "$1" >&2
  exit 1
}
base="$(git -C "$dir" rev-parse -q --verify 'origin/feat-cmux-next^{commit}')" \
  || cannot "cmux guards: no origin/feat-cmux-next in $dir to run the merge guards from"
work="$(mktemp -d)" || cannot "cmux guards: no temporary directory for the merge guards"
trap 'rm -rf "$work"' EXIT
git -C "$dir" archive "$base" scripts/ci/merge-compile-guard-hook.sh scripts/ci/merge_compile_guard.py \
  scripts/ci/base-merge-warning-hook.sh scripts/ci/base_merge_warning.py | tar -x -C "$work" \
  || cannot "cmux guards: cannot read the guards at origin/feat-cmux-next ${base:0:12}"
for hook in merge-compile-guard-hook.sh base-merge-warning-hook.sh; do
  out="$(printf '%s' "$input" | bash "$work/scripts/ci/$hook")"
  status=$?
  if [[ -n "$out" || $status -ne 0 ]]; then
    printf '%s\n' "$out"
    exit "$status"
  fi
done
exit 0
