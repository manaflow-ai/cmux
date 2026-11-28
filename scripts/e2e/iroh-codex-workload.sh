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

# Scan only the bytes appended since the previous poll. The Codex process can
# produce arbitrarily large output, so the polling loop must never materialize
# the full session log or rescan its prefix.
scan_session_log() {
  /usr/bin/python3 - "$1" "$2" "$3" "$4" <<'PY'
import os
import re
import sys

path, raw_offset, raw_index, carry = sys.argv[1:]
offset = max(0, int(raw_offset))
index = int(raw_index)
try:
    size = os.path.getsize(path)
except OSError:
    print("0|0||0")
    raise SystemExit
if size < offset:
    offset = 0
ready_marker = f"CMUX_CODEX_{index}_READY"
iteration_pattern = re.compile(rf"CMUX_CODEX_{index}_ITER_([0-9]+)")
error_pattern = re.compile(r"command not found|login required|authentication required", re.IGNORECASE)
ready = False
error = False
iterations = set()
with open(path, "rb") as stream:
    stream.seek(offset)
    while True:
        chunk = stream.read(64 * 1024)
        if not chunk:
            break
        text = carry + chunk.decode("utf-8", errors="replace")
        ready = ready or ready_marker in text
        error = error or bool(error_pattern.search(text))
        for match in iteration_pattern.finditer(text):
            iterations.add(int(match.group(1)))
        carry = text[-256:]
markers = ",".join(str(value) for value in sorted(iterations))
print(f"{size}|{int(ready)}|{markers}|{int(error)}")
PY
}

shell_quote() {
  printf '%q' "$1"
}

declare -a WORKSPACES=()
declare -a SURFACES=()
declare -a READY_SESSIONS=()
declare -a ITERATION_COUNTS=()
declare -a LOG_OFFSETS=()
declare -a LOG_TAILS=()
declare -a ITERATION_MARKERS=()

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
  LOG_OFFSETS+=(0)
  LOG_TAILS+=("")
  ITERATION_MARKERS+=("")
  printf '{"event":"session_started","role":"%s","index":%d,"workspace_id":"%s","surface_id":"%s","model":"%s","working_directory":"%s","started_at":"%s"}\n' \
    "$role" "$index" "$workspace" "$surface" "$MODEL" "$workdir" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
done

deadline=$(( $(date +%s) + DURATION_SECONDS ))
while (( $(date +%s) < deadline )); do
  for index in "${!WORKSPACES[@]}"; do
    screen="$(read_screen "${WORKSPACES[$index]}" "${SURFACES[$index]}")"
    session_number=$((index + 1))
    session_log="$TASK_ROOT-$session_number/codex-session.log"
    combined_output="$screen"
    marker_seen=0
    if (( session_number <= COUNT )); then
      ready_marker="CMUX_CODEX_${session_number}_READY"
      log_scan="$(scan_session_log "$session_log" "${LOG_OFFSETS[$index]}" "$session_number" "${LOG_TAILS[$index]}")"
      IFS='|' read -r log_size log_ready log_markers log_error <<<"$log_scan"
      if [[ "$log_size" =~ ^[0-9]+$ ]]; then
        LOG_OFFSETS[$index]="$log_size"
        LOG_TAILS[$index]="$(tail -c 256 "$session_log" 2>/dev/null || true)"
      fi
      if [[ "$log_ready" == "1" ]] || grep -qF "$ready_marker" <<<"$combined_output"; then
        READY_SESSIONS[$index]=1
        marker_seen=1
      fi
      if [[ -n "$log_markers" ]]; then
        IFS=',' read -r -a new_markers <<<"$log_markers"
        for marker in "${new_markers[@]}"; do
          [[ "$marker" =~ ^[0-9]+$ ]] || continue
          case ",${ITERATION_MARKERS[$index]}," in
            *",$marker,"*) ;;
            *)
              if [[ -n "${ITERATION_MARKERS[$index]}" ]]; then
                ITERATION_MARKERS[$index]+=",$marker"
              else
                ITERATION_MARKERS[$index]="$marker"
              fi
              ;;
          esac
        done
      fi
      iteration_count=0
      while [[ ",${ITERATION_MARKERS[$index]}," == *",$((iteration_count + 1)),"* ]]; do
        iteration_count=$((iteration_count + 1))
      done
      if (( iteration_count > ITERATION_COUNTS[index] )); then
        ITERATION_COUNTS[$index]="$iteration_count"
        marker_seen=1
      fi
      if (( READY_SESSIONS[index] == 0 )) \
         && { [[ "$log_error" == "1" ]] || grep -Eqi 'command not found|login required|authentication required' <<<"$combined_output"; }; then
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
    workdir="$TASK_ROOT-$session_number"
    [[ -s "$workdir/index.html" ]] || {
      echo "error: Codex session $session_number did not leave a playable index.html" >&2
      exit 1
    }
    artifact_bytes="$(wc -c < "$workdir/index.html" | tr -d ' ')"
    printf '{"event":"session_verified","index":%d,"workspace_id":"%s","surface_id":"%s","model":"%s","iterations":%d,"artifact":"%s/index.html","artifact_bytes":%s,"observed_at":"%s"}\n' \
      "$session_number" "${WORKSPACES[$index]}" "${SURFACES[$index]}" "$MODEL" "${ITERATION_COUNTS[index]}" "$workdir" "$artifact_bytes" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
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
