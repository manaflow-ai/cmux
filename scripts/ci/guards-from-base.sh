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
# A refusal from either is the answer; otherwise their warnings are joined into one answer on stdout. A
# merge whose guards can't be read from the base, or whose guard fails, goes ahead with a warning: only a
# compile that finished red refuses (merge_compile_guard.py).
#
# Usage: printf '%s' "$payload" | bash guards-from-base.sh CHECKOUT
set -uo pipefail
dir="${1:-.}"
input=$(</dev/stdin)
merge=0
case $input in *"pr merge"* | *"/merge"*) merge=1 ;; esac
# A merge the guards can't judge goes ahead with a warning the person and the agent both see, as
# merge_compile_guard.py lets through one it can't read; the update-branch warning goes to stderr.
cannot() {
  if ((merge)); then
    python3 -I -c 'import json, sys; text = sys.argv[1] + "; merging anyway"
json.dump({"systemMessage": text, "hookSpecificOutput": {"hookEventName": "PreToolUse",
  "additionalContext": text}}, sys.stdout)' "$1"
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
# Each guard runs: a refusal from either is the answer. Otherwise their warnings are joined, so a merge's
# warning never hides the update-branch warning of the same command. A guard that crashes or exits
# non-zero (exit 2 would block the tool call in Claude Code) is only a warning: no guard blocks on its own failure.
said=()
for hook in merge-compile-guard-hook.sh base-merge-warning-hook.sh; do
  out="$(printf '%s' "$input" | bash "$work/scripts/ci/$hook" 2>/dev/null)"
  status=$?
  if ((status != 0)); then
    out="cmux guards: $hook exited $status, so it judged nothing"
  fi
  [[ -n "$out" ]] || continue
  # A refusal is the answer the moment its guard gives it, read as JSON whatever its spacing: the next
  # guard could run the hook past its timeout with the refusal unprinted.
  if python3 -I -c 'import json, sys
try:
    spec = json.loads(sys.argv[1]).get("hookSpecificOutput") or {}
except (ValueError, AttributeError):
    sys.exit(1)
sys.exit(0 if isinstance(spec, dict) and spec.get("permissionDecision") == "deny" else 1)' "$out"; then
    printf '%s\n' "$out"
    exit 0
  fi
  said+=("$out")
done
((${#said[@]})) || exit 0
# No refusal: one answer from every warning. A guard's JSON gives its systemMessage and additionalContext,
# any other text is a note. The person sees the systemMessage, the agent the additionalContext.
python3 -I -c 'import json, sys
shown, context = [], []
for out in sys.argv[2:]:
    try:
        answer = json.loads(out)
        spec = answer.get("hookSpecificOutput") or {}
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
