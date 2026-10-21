#!/usr/bin/env bash
# Claude Code PreToolUse(Bash) guards for cmux, run from the feat-cmux-next tip and never from the
# session's checkout (.claude/settings.json reads this file from origin/feat-cmux-next and runs it).
# A pull request's worktree holds that branch's copy of the guards: a branch made before a guard fix
# kept the old guard, and a pull request could edit the guard that judges its own merge
# (palette-audit, 2026-10-21).
#
# A merge is judged by the landing gate installed from cmuxterm-hq main (tools/agent-guards'
# require-cmux-guards, which guards-sync keeps current every 10 minutes), never by a copy in this
# repository: after hq#2830, #23472 still ran a copy here without that fix (deputy-2, 2026-10-21). When
# this account registers the gate, Claude Code runs it and this defers; when only its file is
# installed, this runs it; when it is not installed, the merge is refused.
#
# The update-branch warning (base-merge-warning-hook.sh, base_merge_warning.py) still comes from
# origin/feat-cmux-next (the settings hook fetched it first for a merge), into a temporary directory.
# The first that answers (a refusal or a note) is the answer; the hook JSON goes to stdout.
#
# Usage: printf '%s' "$payload" | bash guards-from-base.sh CHECKOUT
set -uo pipefail
dir="${1:-.}"
input=$(</dev/stdin)
merge=0
case $input in *"pr merge"* | *"/merge"*) merge=1 ;; esac
# A merge the guards can't judge is refused, as the landing gate refuses one it can't read;
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
if ((merge)); then
  gate="$HOME/.claude/hooks/require-cmux-guards.sh"  # where tools/agent-guards/install.py puts it
  [[ -f $gate ]] || cannot "cmux guards: the landing gate (require-cmux-guards, cmuxterm-hq tools/agent-guards) is not \
installed on this machine, so nothing judges this merge. Install it with guards-sync (cmuxterm-hq \
tools/agent-guards/guards-sync, which also keeps it current) or python3 tools/agent-guards/install.py from a \
cmuxterm-hq checkout, then merge again."
  # install.py's own test of a registration: the guard's file name in a PreToolUse command of this account's settings.
  if ! python3 -I - "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" <<'PY'; then
import json, sys
try:
    with open(sys.argv[1]) as f:
        pre = (json.load(f).get("hooks") or {}).get("PreToolUse") or []
    sys.exit(0 if any("require-cmux-guards" in str((h or {}).get("command", ""))
                      for e in pre for h in (e or {}).get("hooks") or []) else 1)
except (OSError, ValueError, AttributeError, TypeError):
    sys.exit(1)
PY
    printf '%s' "$input" | bash "$gate"
    exit
  fi
  exit 0
fi
base="$(git -C "$dir" rev-parse -q --verify 'origin/feat-cmux-next^{commit}')" \
  || cannot "cmux guards: no origin/feat-cmux-next in $dir to run the guards from"
work="$(mktemp -d)" || cannot "cmux guards: no temporary directory for the guards"
trap 'rm -rf "$work"' EXIT
git -C "$dir" archive "$base" scripts/ci/base-merge-warning-hook.sh scripts/ci/base_merge_warning.py | tar -x -C "$work" \
  || cannot "cmux guards: cannot read the guards at origin/feat-cmux-next ${base:0:12}"
printf '%s' "$input" | bash "$work/scripts/ci/base-merge-warning-hook.sh"
