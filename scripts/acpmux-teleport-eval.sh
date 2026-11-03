#!/usr/bin/env bash
# Teleport eval: one disposable agent chat goes around machines with `acpmux session move`
# and must remember, on every machine, a code word it was told on the first.
#
#   scripts/acpmux-teleport-eval.sh HARNESS MACHINE [MACHINE...]
#   scripts/acpmux-teleport-eval.sh claude cmux-lawrence chief-subagents-2 local
#
# The chat starts on this machine in ~/teleport-eval/<harness>-<stamp> (a plain folder, so no
# branch is pushed). Each hop is driven from here: the first with `--machine M`, the next with
# `--from PREV --machine M` (so the machines need not reach each other), `local` brings it back.
# After each hop one turn asks for the code word and the machine's hostname. A hop passes when
# the reply holds the code word and the turn ended there. Prints one line per hop and a JSON
# summary; exit 0 when every hop passed. The chat is left for inspection (its name is printed).
set -euo pipefail

harness="${1:?usage: acpmux-teleport-eval.sh HARNESS MACHINE [MACHINE...]}"
shift
[[ $# -ge 1 ]] || { echo "name at least one machine" >&2; exit 2; }
ACPMUX="${ACPMUX:-acpmux}"
WAIT="${TELEPORT_EVAL_WAIT:-600}"

stamp="$(date +%Y%m%d%H%M%S)"
name="teleport-eval-${harness}-t${stamp}"
word="WORD-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | tr a-f A-F)"
dir="$HOME/teleport-eval/${harness}-${stamp}"
mkdir -p "$dir"

# This script plays the person who owns the chat: run from inside an agent's session, a send
# would otherwise arrive as another agent's inbox message, which a careful agent will not answer
# with a code word. Only the session-identity variables go; the daemon socket stays.
here() {
  env -u ACPMUX_SESSION_ID -u ACPMUX_SESSION_NAME -u ACPMUX_SESSION_TOKEN \
    -u ACPMUX_SESSION_TOKEN_SOCKET -u CLAUDECODE -u CODEX_THREAD_ID "$ACPMUX" "$@"
}

# Runs acpmux for the chat where it is now: here, or on the ssh peer `$where`.
on() {
  if [[ "$where" == local ]]; then here "$@"; else
    local ssh
    ssh="$("$ACPMUX" --json machine ls 2>/dev/null | python3 -I -c '
import json, sys
name = sys.argv[1]
d = json.load(sys.stdin)
peers = d if isinstance(d, list) else (d.get("peers") or d.get("machines") or [])
for p in peers:
    if str(p.get("name", "")).lower() == name.lower():
        u = p.get("url", "")
        print(u.split("://", 1)[-1])
        break
' "$where")"
    [[ -n "$ssh" ]] || { echo "no ssh address for $where" >&2; return 1; }
    # Arguments are this script's own literals and the generated chat name and code word.
    ssh -o BatchMode=yes "$ssh" "PATH=\$HOME/.local/bin:\$PATH acpmux $(printf '%q ' "$@")"
  fi
}

# Sends one question and answers the reply that holds its tag `$2`: a turn the machine queues
# (its load budget) is waited for, and a previous turn's reply never counts.
ask() {
  local deadline=$(( $(date +%s) + WAIT )) reply=""
  on send --no-wait "$name" "$1" >/dev/null
  while (( $(date +%s) < deadline )); do
    on wait "$name" --all --timeout 60 >/dev/null || true
    reply="$(on last "$name" 2>/dev/null | tail -1)"
    [[ "$reply" == *"$2"* ]] && break
  done
  printf '%s\n' "$reply"
}

results=()
where=local
# `--machine local`: a new chat on a person's Mac is otherwise placed on another machine.
here new -m "$harness" -n "$name" --machine local --cwd "$dir" -d --quiet \
  "Remember the code word $word. Reply only: ok" >/dev/null
echo "chat $name ($harness) in $dir, code word $word"

prev=local
for m in "$@"; do
  if [[ "$prev" == local ]]; then
    move=("$ACPMUX" --json session move "$name" --machine "$m")
  else
    move=("$ACPMUX" --json session move "$name" --from "$prev" --machine "$m")
  fi
  t0=$(date +%s)
  if ! out="$("${move[@]}" 2>&1)"; then
    echo "hop $prev -> $m: MOVE FAILED: $(printf '%s' "$out" | tail -1)"
    results+=("{\"from\":\"$prev\",\"to\":\"$m\",\"pass\":false,\"why\":\"move failed\"}")
    break
  fi
  moved=$(( $(date +%s) - t0 ))
  where="$m"
  # A machine that still has a closed copy under that name gives the chat a new one (`-1`).
  name="$(printf '%s' "$out" | python3 -I -c '
import json, sys
text = sys.stdin.read()
d = json.loads(text[text.find("{"):])
print((d.get("moves") or [{}])[0].get("name") or sys.argv[1])
' "$name" 2>/dev/null || printf '%s' "$name")"
  tag="hop-$(( ${#results[@]} + 1 ))-$RANDOM"
  reply="$(ask "What code word did I ask you to remember? Run the command hostname too. Reply exactly: <codeword> <hostname> $tag" "$tag" 2>&1 | tail -1)"
  if [[ "$reply" == *"$word"* && "$reply" == *"$tag"* ]]; then pass=true; else pass=false; fi
  echo "hop $prev -> $m: moved in ${moved}s, reply: $reply, pass: $pass"
  results+=("{\"from\":\"$prev\",\"to\":\"$m\",\"moveSeconds\":$moved,\"pass\":$pass}")
  $pass || break
  prev="$m"
done

joined="$(IFS=,; echo "${results[*]}")"
echo "{\"harness\":\"$harness\",\"chat\":\"$name\",\"hops\":[${joined}]}"
[[ "$joined" != *'"pass":false'* && ${#results[@]} -eq $# ]]
