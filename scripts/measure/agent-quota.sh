#!/usr/bin/env bash
# agent-quota: how many GitHub calls, and how long, real Claude Code agents spend waiting for one
# pull request's CI, with and without cmux's quota guidance.
#
#   scripts/measure/agent-quota.sh [arms=without,skill,shipped] [agents=1,6] [trials=3]
#                                  [ci_seconds=300] [model=claude-opus-5-5] acpmux=PATH
#
# Each trial starts AGENTS headless Claude Code agents at once (`claude -p --bare`: no hooks, no
# CLAUDE.md, no rules of the machine it runs on) in their own folders on one machine, each asked
# to wait for octo/app#7's CI and say whether it passed. The `gh` on their PATH is the stand-in
# next to this script: its one check finishes ci_seconds after the trial starts, and it logs every
# call that would reach GitHub (a --watch refresh is one call each; `gh api rate_limit` and `gh auth
# status`, which cost no quota, are logged as FREE).
#
# Arms:
#   without  no cmux skill or guidance.
#   skill    the cmux-quota skill as a plugin, as cmux ships it, listed but not in the prompt.
#   shipped  the skill plus CLAUDE_GUIDANCE (agent_guidance.rs) before the first prompt, as cmux
#            sends a chat's first turn.
# The skill and guidance are read from this checkout, so the bench measures the code it runs at.
# `acpmux` (with pr-wait) must be a build of this checkout.
#
# One line per trial:
#   AGENT-QUOTA row arm=A agents=K trial=N calls=C wall_s=W correct=X/K
# correct counts the agents whose last reply says the checks passed.
set -u
arms=without,skill,shipped agents=1,6 trials=3 ci_seconds=300 model=claude-opus-5-5 acpmux=""
for kv in "$@"; do
  case "$kv" in
    arms=*|agents=*|trials=*|ci_seconds=*|model=*|acpmux=*) eval "${kv%%=*}=\${kv#*=}";;
    *) echo "agent-quota: unknown argument $kv" >&2; exit 2;;
  esac
done
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
[ -x "$acpmux" ] || { echo "agent-quota: acpmux=PATH (a build of this checkout) is required" >&2; exit 2; }
command -v claude >/dev/null || { echo "agent-quota: claude is not on PATH" >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-quota.XXXXXX")
trap '[ -n "${AGENT_QUOTA_KEEP:-}" ] || rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/plugin/.claude-plugin" "$work/plugin/skills/cmux-quota"
cp "$here/agent-quota/gh" "$work/bin/gh" && cp "$acpmux" "$work/bin/acpmux" && chmod +x "$work/bin/"*
echo '{"name":"cmux","version":"0.0.0","description":"cmux agent tools"}' > "$work/plugin/.claude-plugin/plugin.json"
cp "$repo/cmux-tui/crates/acpmux/skills/cmux-quota/SKILL.md" "$work/plugin/skills/cmux-quota/"
awk '/^pub const CLAUDE_GUIDANCE: &str = "/{f=1; sub(/^pub const CLAUDE_GUIDANCE: &str = "/,"")}
     f{ if (sub(/";$/,"")) {print; exit} print }' \
  "$repo/cmux-tui/crates/acpmux/src/agent_guidance.rs" | sed 's/\\"/"/g' > "$work/guidance.txt"
[ -s "$work/guidance.txt" ] || { echo "agent-quota: CLAUDE_GUIDANCE not found" >&2; exit 2; }
# The person's login, through a key helper: --bare reads no OAuth login of its own.
settings=$work/settings.json
if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  echo '{"apiKeyHelper":"printf %s \"$ANTHROPIC_AUTH_TOKEN\""}' > "$settings"
else
  echo '{}' > "$settings"
fi
ask="I pushed commit 4f2c9a1e8b7d6c5f4e3d2c1b0a9f8e7d6c5b4a39 to pull request #7 of octo/app (this folder). Wait for its CI checks to finish, then tell me whether they passed. gh is logged in."

trial() { # ARM K N
  local arm=$1 k=$2 n=$3 t="$work/$1-$2-$3" i pre="" plugin=()
  mkdir -p "$t/state"
  [ "$arm" != without ] && plugin=(--plugin-dir "$work/plugin")
  [ "$arm" = shipped ] && pre="$(cat "$work/guidance.txt")"$'\n\n'
  date +%s > "$t/start"
  for i in $(seq 1 "$k"); do
    mkdir -p "$t/repo$i"
    git -C "$t/repo$i" init -q && git -C "$t/repo$i" remote add origin https://github.com/octo/app.git
    ( cd "$t/repo$i" && BENCH=$t CI_SECONDS=$ci_seconds ACPMUX_PR_WAIT_DIR=$t/state PATH="$work/bin:$PATH" \
        timeout $(( ci_seconds * 4 + 300 )) claude -p --bare --settings "$settings" --model "$model" --effort medium \
        --allowedTools Bash,Read ${plugin[@]+"${plugin[@]}"} --output-format stream-json --verbose "$pre$ask" \
        > "$t/transcript$i.jsonl" 2> "$t/stderr$i" ) &
  done
  wait
  local wall=$(( $(date +%s) - $(cat "$t/start") ))
  local calls; calls=$(grep -vc ' FREE ' "$t/calls.log" 2>/dev/null) || calls=0
  local ok=0
  for i in $(seq 1 "$k"); do
    jq -rs '[.[] | select(.type=="result")] | last | .result // ""' "$t/transcript$i.jsonl" 2>/dev/null \
      | grep -qiE 'pass|green|succeed|success' && ok=$((ok + 1))
  done
  echo "AGENT-QUOTA row arm=$arm agents=$k trial=$n calls=$calls wall_s=$wall correct=$ok/$k"
}

echo "AGENT-QUOTA-MACHINE host=$(hostname -s) os=$(uname -s) model=$model ci_seconds=$ci_seconds work=$work"
for k in ${agents//,/ }; do
  for arm in ${arms//,/ }; do
    for n in $(seq 1 "$trials"); do trial "$arm" "$k" "$n"; done
  done
done
