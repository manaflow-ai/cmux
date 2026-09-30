#!/usr/bin/env bash
# Start real Codex sessions through a tagged Mac cmux socket while the paired
# iOS simulator is using that Mac over Iroh.
set -euo pipefail

TAG="${CMUX_E2E_TAG:-}"
EVIDENCE_DIR="${CMUX_CODEX_EVIDENCE_DIR:-}"
MODEL="${CMUX_CODEX_MODEL:-gpt-5.5-mini}"
DURATION_SECONDS="${CMUX_CODEX_DURATION_SECONDS:-900}"
COUNT="${CMUX_CODEX_SESSION_COUNT:-3}"
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

declare -a WORKSPACES=()
declare -a SURFACES=()
TASK_ROOT="/tmp/cmux-iroh-mario"
for ((index=1; index<=COUNT+2; index++)); do
  workdir="$TASK_ROOT-$index"
  mkdir -p "$workdir"
  if (( index <= COUNT )); then
    prompt="Build and iteratively improve a playable Mario-style HTML game in $workdir. Use real file edits and run local checks. Work independently for at least ten meaningful iterations. Print CMUX_CODEX_${index}_READY after the first playable version and CMUX_CODEX_${index}_ITER_<number> after every later improvement. Keep the game runnable from index.html."
    command="codex --yolo -m '$MODEL' -- $(printf '%q' "$prompt")"
  else
    command="while true; do printf 'CMUX_SUPPORT_${index}_READY\n'; sleep 30; done"
  fi
  response="$("${CLI[@]}" --json --id-format uuids workspace create --name "iroh codex $index" --cwd "$workdir" --command "$command" --focus false)"
  workspace="$(printf '%s' "$response" | json_value workspace_id)"
  [[ -n "$workspace" ]] || workspace="$(printf '%s' "$response" | json_value workspace_ref)"
  [[ -n "$workspace" ]] || { echo "workspace create failed: $response" >&2; exit 1; }
  surfaces_json="$("${CLI[@]}" --json --id-format uuids list-pane-surfaces --workspace "$workspace")"
  surface="$(printf '%s' "$surfaces_json" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); rows=d.get("surfaces",[]); print((rows[0].get("surface_id") or rows[0].get("id") or rows[0].get("surface_ref") or "") if rows else "")')"
  [[ -n "$surface" ]] || { echo "surface lookup failed: $surfaces_json" >&2; exit 1; }
  WORKSPACES+=("$workspace")
  SURFACES+=("$surface")
  printf '{"event":"session_started","index":%d,"workspace_id":"%s","surface_id":"%s","model":"%s","working_directory":"%s","started_at":"%s"}\n' \
    "$index" "$workspace" "$surface" "$MODEL" "$workdir" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
done

deadline=$(( $(date +%s) + DURATION_SECONDS ))
while (( $(date +%s) < deadline )); do
  for index in "${!WORKSPACES[@]}"; do
    screen="$(read_screen "${WORKSPACES[$index]}" "${SURFACES[$index]}")"
    marker="CMUX_CODEX_$((index + 1))_"
    if grep -q "$marker\\|CMUX_SUPPORT_" <<<"$screen"; then
      printf '{"event":"session_output","index":%d,"workspace_id":"%s","surface_id":"%s","model":"%s","observed_at":"%s","marker_seen":true}\n' \
        "$((index + 1))" "${WORKSPACES[$index]}" "${SURFACES[$index]}" "$MODEL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
    fi
  done
  sleep 15
done

for index in "${!WORKSPACES[@]}"; do
  printf '{"event":"session_final","index":%d,"workspace_id":"%s","surface_id":"%s","model":"%s","observed_at":"%s"}\n' \
    "$((index + 1))" "${WORKSPACES[$index]}" "${SURFACES[$index]}" "$MODEL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
done
echo "Codex workload completed: $COUNT sessions plus two supporting workspaces, model=$MODEL"
