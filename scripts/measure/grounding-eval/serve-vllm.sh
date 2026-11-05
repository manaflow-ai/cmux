#!/usr/bin/env bash
# Serve one grounding model with vLLM on a fleet GPU host (OpenAI-compatible, 127.0.0.1 only).
#   serve-vllm.sh MODEL_ID [PORT]        MODEL_ID is an id from models.json
# Prints the server's pid on stdout once /v1/models answers. The GPU peak (GiB, all GPUs summed) is
# sampled every second into $GROUNDING_EVAL_OUT/MODEL_ID.gpu-peak until the server exits; the server log
# goes to $GROUNDING_EVAL_OUT/MODEL_ID.vllm.log. Stop it with `kill PID` (the pid it printed).
# Needs: vllm >= 0.13 (Holo2's chat template, OpenCUA's model class), nvidia-smi.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
model_id="${1:?model id from models.json}"
port="${2:-8000}"
out="${GROUNDING_EVAL_OUT:-$PWD/.build/grounding-eval}"
mkdir -p "$out"
read -r hf family max_pixels < <(python3 -I -c '
import json, sys
m = {m["id"]: m for m in json.load(open(sys.argv[1]))["models"]}[sys.argv[2]]
assert m["serve"] in ("vllm", "both"), m["id"] + " does not serve on vllm"
print(m["hf"], m["family"], m["max_pixels"])' "$here/models.json" "$model_id")

args=(serve "$hf" --host 127.0.0.1 --port "$port" --served-model-name "$model_id" --dtype bfloat16
      --max-model-len 32768 --limit-mm-per-prompt '{"image": 1, "video": 0}'
      --mm-processor-kwargs "{\"max_pixels\": $max_pixels}" --gpu-memory-utilization 0.9)
case "$family" in
  opencua) args+=(--trust-remote-code) ;;
esac
# A 30B+ model on more than one GPU: split it across all of them.
gpus="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"
if [[ "$gpus" -gt 1 ]]; then args+=(--tensor-parallel-size "$gpus"); fi

vllm "${args[@]}" >"$out/$model_id.vllm.log" 2>&1 &
pid=$!
peak_file="$out/$model_id.gpu-peak"
: >"$peak_file"
(
  peak=0
  while kill -0 "$pid" 2>/dev/null; do
    used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{s+=$1} END {print s+0}')"
    if [[ "$used" -gt "$peak" ]]; then peak="$used"; awk -v m="$peak" 'BEGIN {printf "%.2f\n", m/1024}' >"$peak_file"; fi
    sleep 1
  done
) &
for _ in $(seq 1 900); do
  if curl -fsS "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; then echo "$pid"; exit 0; fi
  kill -0 "$pid" 2>/dev/null || { echo "serve-vllm.sh: vllm exited; see $out/$model_id.vllm.log" >&2; tail -30 "$out/$model_id.vllm.log" >&2; exit 1; }
  sleep 2
done
echo "serve-vllm.sh: $model_id did not answer in 30 minutes" >&2
kill "$pid"
exit 1
