#!/usr/bin/env bash
# Start real Codex sessions through a tagged Mac cmux socket while the paired
# iOS simulator is using that Mac over Iroh.
set -euo pipefail

TAG="${CMUX_E2E_TAG:-}"
EVIDENCE_DIR="${CMUX_CODEX_EVIDENCE_DIR:-}"
MODEL="${CMUX_CODEX_MODEL:-gpt-5.5-mini}"
DURATION_SECONDS="${CMUX_CODEX_DURATION_SECONDS:-900}"
COUNT="${CMUX_CODEX_SESSION_COUNT:-3}"
SHUTDOWN_FILE="${CMUX_CODEX_SHUTDOWN_FILE:-}"
[[ -n "$TAG" && -n "$EVIDENCE_DIR" ]] || {
  echo "Usage: CMUX_E2E_TAG=<tag> CMUX_CODEX_EVIDENCE_DIR=<dir> $0" >&2
  exit 2
}
[[ "$DURATION_SECONDS" =~ ^[0-9]+$ && "$COUNT" =~ ^[1-9][0-9]*$ ]] || {
  echo "error: duration and session count must be positive integers" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI=(env "CMUX_TAG=$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh")
mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/codex-workload.jsonl"
: > "$LOG"

# The preferred model is unavailable to the ChatGPT account used by this
# hosted verification lane. Record the explicit fallback in the evidence so a
# successful run proves the workload ran with a real supported Codex model.
printf '{"event":"model_selection","requested_preferred":"gpt-5.3-codex-spark","selected":"%s","unavailable_reason":"unsupported ChatGPT account"}\n' "$MODEL" >> "$LOG"

json_value() {
  /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print(v if v is not None else "")' "$1"
}

read_screen() {
  "${CLI[@]}" read-screen --workspace "$1" --surface "$2" --lines 40 2>/dev/null || true
}

shell_quote() {
  printf '%q' "$1"
}

declare -a WORKSPACES=()
declare -a SURFACES=()
declare -a READY_SESSIONS=()
declare -a ITERATION_COUNTS=()

# Closing a workspace terminates the terminal process group that owns the
# Codex/support command. Always clean up, including when a marker or RPC check
# fails, so one gate cannot leave workspaces and child processes behind for the
# next gate.
cleanup() {
  local workspace
  set +e
  for workspace in "${WORKSPACES[@]}"; do
    "${CLI[@]}" close-workspace --workspace "$workspace" >/dev/null 2>&1
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TASK_ROOT="/tmp/cmux-iroh-mario"
for ((index=1; index<=COUNT+2; index++)); do
  workdir="$TASK_ROOT-$index"
  mkdir -p "$workdir"
  session_log="$workdir/codex-session.log"
  rm -f "$session_log"
  if (( index <= COUNT )); then
    role="codex"
    prompt="Build and iteratively improve a playable Mario-style HTML game in $workdir. Use real file edits and run local checks. Work independently for at least ten meaningful iterations. Print CMUX_CODEX_${index}_READY after the first playable version and CMUX_CODEX_${index}_ITER_<number> after every later improvement. Keep the game runnable from index.html."
    command="while true; do codex --yolo -m $(shell_quote "$MODEL") -- $(shell_quote "$prompt") 2>&1 | tee -a $(shell_quote "$session_log"); printf 'CMUX_CODEX_${index}_RUN_COMPLETE\\n' | tee -a $(shell_quote "$session_log"); sleep 5; done"
  else
    # The terminal driver must send shell input to an idle shell, never to
    # Codex or a foreground keepalive process.
    role="terminal"
    command="/bin/zsh -l"
  fi
  response="$("${CLI[@]}" --json --id-format uuids workspace create --name "iroh codex $index" --cwd "$workdir" --command "$command" --focus false)"
  workspace="$(printf '%s' "$response" | json_value workspace_id)"
  [[ -n "$workspace" ]] || workspace="$(printf '%s' "$response" | json_value workspace_ref)"
  [[ -n "$workspace" ]] || { echo "workspace create failed: $response" >&2; exit 1; }
  WORKSPACES+=("$workspace")
  surfaces_json="$("${CLI[@]}" --json --id-format uuids list-pane-surfaces --workspace "$workspace")"
  surface="$(printf '%s' "$surfaces_json" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); rows=d.get("surfaces",[]); print((rows[0].get("surface_id") or rows[0].get("id") or rows[0].get("surface_ref") or "") if rows else "")')"
  [[ -n "$surface" ]] || { echo "surface lookup failed: $surfaces_json" >&2; exit 1; }
  SURFACES+=("$surface")
  READY_SESSIONS+=(0)
  ITERATION_COUNTS+=(0)
  printf '{"event":"session_started","role":"%s","index":%d,"workspace_id":"%s","surface_id":"%s","model":"%s","working_directory":"%s","started_at":"%s"}\n' \
    "$role" "$index" "$workspace" "$surface" "$MODEL" "$workdir" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
done

deadline=$(( $(date +%s) + DURATION_SECONDS ))
while (( $(date +%s) < deadline )); do
  for index in "${!WORKSPACES[@]}"; do
    screen="$(read_screen "${WORKSPACES[$index]}" "${SURFACES[$index]}")"
    session_number=$((index + 1))
    session_log="$TASK_ROOT-$session_number/codex-session.log"
    durable_output="$(cat "$session_log" 2>/dev/null || true)"
    combined_output="$screen
$durable_output"
    marker_seen=0
    if (( session_number <= COUNT )); then
      ready_marker="CMUX_CODEX_${session_number}_READY"
      if grep -qF "$ready_marker" <<<"$combined_output"; then
        READY_SESSIONS[$index]=1
        marker_seen=1
      fi
      iteration_count="$(grep -oE "CMUX_CODEX_${session_number}_ITER_[0-9]+" <<<"$combined_output" \
        | sed -E 's/.*_ITER_//' | sort -n | tail -1 || true)"
      if [[ "$iteration_count" =~ ^[0-9]+$ ]] \
         && (( iteration_count > ITERATION_COUNTS[index] )); then
        ITERATION_COUNTS[$index]="$iteration_count"
        marker_seen=1
      fi
      if (( READY_SESSIONS[index] == 0 )) \
         && grep -Eqi 'command not found|login required|authentication required' <<<"$combined_output"; then
        echo "error: Codex session $session_number exited or needs authentication before its ready marker" >&2
        exit 1
      fi
    elif grep -qF "CMUX_SUPPORT_" <<<"$combined_output"; then
      marker_seen=1
    fi
    if (( marker_seen == 1 )); then
      printf '{"event":"session_output","index":%d,"workspace_id":"%s","surface_id":"%s","model":"%s","observed_at":"%s","marker_seen":true}\n' \
        "$session_number" "${WORKSPACES[$index]}" "${SURFACES[$index]}" "$MODEL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
    fi
  done
  sleep 15
done

for index in "${!WORKSPACES[@]}"; do
  session_number=$((index + 1))
  if (( session_number <= COUNT )); then
    if (( READY_SESSIONS[index] != 1 )); then
      echo "error: Codex session $session_number never emitted CMUX_CODEX_${session_number}_READY" >&2
      exit 1
    fi
    if (( ITERATION_COUNTS[index] < 10 )); then
      echo "error: Codex session $session_number emitted only ${ITERATION_COUNTS[index]} iterations, expected at least 10" >&2
      exit 1
    fi
    printf '{"event":"session_verified","index":%d,"workspace_id":"%s","surface_id":"%s","model":"%s","iterations":%d,"observed_at":"%s"}\n' \
      "$session_number" "${WORKSPACES[$index]}" "${SURFACES[$index]}" "$MODEL" "${ITERATION_COUNTS[index]}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  fi
done

for index in "${!WORKSPACES[@]}"; do
  printf '{"event":"session_final","index":%d,"workspace_id":"%s","surface_id":"%s","model":"%s","observed_at":"%s"}\n' \
    "$((index + 1))" "${WORKSPACES[$index]}" "${SURFACES[$index]}" "$MODEL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
done
echo "Codex workload completed: $COUNT sessions plus two supporting workspaces, model=$MODEL"
if [[ -n "$SHUTDOWN_FILE" ]]; then
  printf '{"event":"waiting_for_shutdown","observed_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  while [[ ! -e "$SHUTDOWN_FILE" ]]; do
    sleep 1
  done
  printf '{"event":"shutdown_requested","observed_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
fi
