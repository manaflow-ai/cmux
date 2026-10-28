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
# installed, this runs it; when it is not installed, the merge goes ahead with a warning that says how
# to install it (2026-10-21: no guard blocks a merge it can't judge, only a compile that finished red).
#
# The update-branch warning (base-merge-warning-hook.sh, base_merge_warning.py) still comes from
# origin/feat-cmux-next (the settings hook fetched it first for a merge), into a temporary directory.
# A refusal is the answer; otherwise every warning is joined into one answer on stdout.
#
# Usage: printf '%s' "$payload" | bash guards-from-base.sh CHECKOUT
set -uo pipefail
dir="${1:-.}"
input=$(</dev/stdin)
merge=0
case $input in *"pr merge"* | *"/merge"* | *mergePullRequest* | *PullRequestAutoMerge*) merge=1 ;; esac
said=()
# A guard that can't run is a warning: for a merge the person and the agent both see it and the merge goes
# ahead; otherwise it goes to stderr.
cannot() {
  if ((merge)); then
    said+=("$1")
    return
  fi
  echo "$1" >&2
  exit 1
}
# judge NAME COMMAND...: runs one guard on the payload. A refusal is the answer the moment its guard gives it,
# read as JSON whatever its spacing: the next guard could run the hook past its timeout with the refusal
# unprinted. A guard that crashes or exits non-zero (exit 2 would block the tool call in Claude Code) is only a
# warning: no guard blocks on its own failure. The payload reaches the guard by process substitution, not a
# pipe: under pipefail a guard that answers without reading stdin made printf die of SIGPIPE, and the pipe's
# 141 read as the guard crashing (tests/test_guard_hooks_from_base.py, red on base under concurrent load).
judge() {
  local name=$1 out status
  shift
  out="$("$@" 2>/dev/null < <(printf '%s' "$input"))"
  status=$?
  if ((status != 0)); then
    out="cmux guards: $name exited $status, so it judged nothing"
  fi
  [[ -n "$out" ]] || return 0
  if python3 -I -c 'import json, sys
try:
    answer = json.loads(sys.argv[1])
    spec = answer.get("hookSpecificOutput") or answer
except (ValueError, AttributeError):
    sys.exit(1)
sys.exit(0 if isinstance(spec, dict) and spec.get("permissionDecision") == "deny" else 1)' "$out"; then
    printf '%s\n' "$out"
    exit 0
  fi
  said+=("$out")
}
if ((merge)); then
  gate="$HOME/.claude/hooks/require-cmux-guards.sh"  # where tools/agent-guards/install.py puts it
  if [[ ! -f $gate ]]; then
    cannot "cmux guards: the landing gate (require-cmux-guards, cmuxterm-hq tools/agent-guards) is not \
installed on this machine, so nothing judges this merge. Install it with guards-sync (cmuxterm-hq \
tools/agent-guards/guards-sync, which also keeps it current) or python3 tools/agent-guards/install.py from a \
cmuxterm-hq checkout"
  # A registration: a PreToolUse command of this account's settings, under a matcher that covers Bash (none, "*",
  # or a pattern Bash matches), that runs the gate's file: one of its words is that file, not just a mention of it.
  elif ! python3 -I - "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" <<'PY'; then
import json, os, re, shlex, sys
def covers_bash(matcher):
    if matcher in (None, "", "*"):
        return True
    try:
        return re.fullmatch(str(matcher), "Bash") is not None
    except re.error:
        return False
def runs_gate(command):
    try:
        words = shlex.split(str(command))
    except ValueError:
        return False
    return any(os.path.basename(word) in ("require-cmux-guards.sh", "require-cmux-guards.py") for word in words)
try:
    with open(sys.argv[1]) as f:
        pre = (json.load(f).get("hooks") or {}).get("PreToolUse") or []
    sys.exit(0 if any(covers_bash((e or {}).get("matcher")) and runs_gate((h or {}).get("command", ""))
                      for e in pre for h in (e or {}).get("hooks") or []) else 1)
except (OSError, ValueError, AttributeError, TypeError):
    sys.exit(1)
PY
    judge require-cmux-guards.sh bash "$gate"
  fi
fi
work=""
if base="$(git -C "$dir" rev-parse -q --verify 'origin/feat-cmux-next^{commit}')"; then
  if work="$(mktemp -d)"; then
    trap 'rm -rf "$work"' EXIT
    if git -C "$dir" archive "$base" scripts/ci/base-merge-warning-hook.sh scripts/ci/base_merge_warning.py \
      | tar -x -C "$work"; then
      judge base-merge-warning-hook.sh bash "$work/scripts/ci/base-merge-warning-hook.sh"
    else
      cannot "cmux guards: cannot read the guards at origin/feat-cmux-next ${base:0:12}"
    fi
  else
    cannot "cmux guards: no temporary directory for the guards"
  fi
else
  cannot "cmux guards: no origin/feat-cmux-next in $dir to run the guards from"
fi
((${#said[@]})) || exit 0
# No refusal: one answer from every warning. A guard's JSON gives its systemMessage and additionalContext,
# any other text is a note. The person sees the systemMessage, the agent the additionalContext.
python3 -I -c 'import json, sys
shown, context = [], []
for out in sys.argv[2:]:
    try:
        answer = json.loads(out)
        spec = answer.get("hookSpecificOutput") or answer
    except (ValueError, AttributeError):
        answer, spec = {}, {}
    if not spec and not answer.get("systemMessage"):
        note = out + ("; merging anyway" if sys.argv[1] == "1" else "")
        shown.append(note)
        context.append(note)
        continue
    if answer.get("systemMessage"):
        shown.append(answer["systemMessage"])
    if spec.get("additionalContext"):
        context.append(spec["additionalContext"])
result = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "\n".join(context)}}
if shown:
    result["systemMessage"] = "\n".join(shown)
json.dump(result, sys.stdout)' "$merge" "${said[@]}" || true
exit 0
