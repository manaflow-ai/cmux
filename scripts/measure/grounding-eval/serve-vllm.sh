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
read -r hf family min_pixels max_pixels params_b < <(python3 -I -c '
import json, sys
m = {m["id"]: m for m in json.load(open(sys.argv[1]))["models"]}[sys.argv[2]]
assert m["serve"] in ("vllm", "both"), m["id"] + " does not serve on vllm"
print(m["hf"], m["family"], m["min_pixels"], m["max_pixels"], m["params_b"])' "$here/models.json" "$model_id")

args=(serve "$hf" --host 127.0.0.1 --port "$port" --served-model-name "$model_id" --dtype bfloat16
      --max-model-len 32768 --limit-mm-per-prompt '{"image": 1, "video": 0}'
      --mm-processor-kwargs "{\"min_pixels\": $min_pixels, \"max_pixels\": $max_pixels}" --gpu-memory-utilization 0.9
      # Each request is a fresh screenshot in use, so no prefix or image cache flatters the latency.
      --no-enable-prefix-caching --mm-processor-cache-gb 0)
case "$family" in
  opencua) args+=(--trust-remote-code) ;;
esac
# Only a model too big for one GPU is split (tensor parallel costs latency at batch 1), over the GPUs
# this process may use.
if [[ -n "${CUDA_VISIBLE_DEVICES:-}" ]]; then
  gpus="$(tr ',' '\n' <<<"$CUDA_VISIBLE_DEVICES" | grep -c .)"
else
  gpus="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"
fi
gpu_gib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | awk '{print int($1/1024)}')"
if awk -v p="$params_b" -v g="$gpu_gib" 'BEGIN {exit !(p * 2 > g * 0.7)}' && [[ "$gpus" -gt 1 ]]; then
  tp=1
  while [[ $((tp * 2)) -le "$gpus" ]]; do tp=$((tp * 2)); done
  args+=(--tensor-parallel-size "$tp")
fi

vllm "${args[@]}" >"$out/$model_id.vllm.log" 2>&1 </dev/null &
pid=$!
peak_file="$out/$model_id.gpu-peak"
: >"$peak_file"
(
  peak=0
  while kill -0 "$pid" 2>/dev/null; do
    used="$(nvidia-smi ${CUDA_VISIBLE_DEVICES:+--id="$CUDA_VISIBLE_DEVICES"} --query-gpu=memory.used --format=csv,noheader,nounits | awk '{s+=$1} END {print s+0}')"
    if [[ "$used" -gt "$peak" ]]; then peak="$used"; awk -v m="$peak" 'BEGIN {printf "%.2f\n", m/1024}' >"$peak_file"; fi
    sleep 1
  done
) </dev/null >/dev/null 2>&1 &
for _ in $(seq 1 900); do
  if curl -fsS "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; then echo "$pid"; exit 0; fi
  kill -0 "$pid" 2>/dev/null || { echo "serve-vllm.sh: vllm exited; see $out/$model_id.vllm.log" >&2; tail -30 "$out/$model_id.vllm.log" >&2; exit 1; }
  sleep 2
done
echo "serve-vllm.sh: $model_id did not answer in 30 minutes" >&2
kill "$pid"
exit 1
