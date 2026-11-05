#!/usr/bin/env bash
# The grounding eval, end to end on one host: for each model, serve it, run both benchmarks, stop it.
#   run.sh server=vllm|mlx [models=ID,ID] [data=DIR] [limit=N] [quant=bf16|8|4] [max_pixels=N] [bench=...]
# server=vllm runs on a fleet GPU host, server=mlx on Apple silicon. models defaults to every model in
# models.json that serves there. data defaults to $GROUNDING_EVAL_DATA or .build/grounding-eval/data
# (prepared on first use). Results: .build/grounding-eval/<model>.json, its .samples.jsonl, and
# summary.md (grounding_eval.py summarize). Exit 0 when every model ran, 1 when one failed.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
server="" models="" limit=0 quant=bf16 max_pixels=0 bench=screenspot-pro,osworld-g
out="${GROUNDING_EVAL_OUT:-$PWD/.build/grounding-eval}"
data="${GROUNDING_EVAL_DATA:-$out/data}"
for arg in "$@"; do
  case "$arg" in
    server=*) server="${arg#server=}" ;;
    models=*) models="${arg#models=}" ;;
    data=*) data="${arg#data=}" ;;
    limit=*) limit="${arg#limit=}" ;;
    quant=*) quant="${arg#quant=}" ;;
    max_pixels=*) max_pixels="${arg#max_pixels=}" ;;
    bench=*) bench="${arg#bench=}" ;;
    *) echo "run.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$server" == vllm || "$server" == mlx ]] || { echo "run.sh: server=vllm or server=mlx" >&2; exit 2; }
python="${GROUNDING_EVAL_PYTHON:-python3}"
export GROUNDING_EVAL_OUT="$out" GROUNDING_EVAL_PYTHON="$python"
export GROUNDING_EVAL_REV="${GROUNDING_EVAL_REV:-$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)}"
mkdir -p "$out"
if [[ -z "$models" ]]; then
  models="$(python3 -I -c '
import json, sys
print(",".join(m["id"] for m in json.load(open(sys.argv[1]))["models"] if m["serve"] in (sys.argv[2], "both")))' \
    "$here/models.json" "$server")"
fi
if [[ ! -f "$data/osworld-g/annotations.json" ]]; then
  "$python" -I "$here/grounding_eval.py" prepare --data "$data" || exit 1
fi
echo "GROUNDING-EVAL-MACHINE host=$(hostname -s) server=$server rev=$GROUNDING_EVAL_REV models=$models"
status=0
results=()
# Stops a server this script started (its pid, printed by serve-*.sh), waiting until it is gone so
# the next model never starts beside it; on vLLM, also until the GPU memory is given back.
stop_server() {
  local pid="$1"
  kill "$pid" 2>/dev/null
  for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  if [[ "$server" == vllm ]]; then
    for _ in $(seq 1 60); do
      used="$(nvidia-smi ${CUDA_VISIBLE_DEVICES:+--id="$CUDA_VISIBLE_DEVICES"} --query-gpu=memory.used --format=csv,noheader,nounits | awk '{s+=$1} END {print s+0}')"
      [[ "$used" -le $((baseline + 512)) ]] && break
      sleep 1
    done
  fi
}
baseline=0
if [[ "$server" == vllm ]]; then
  baseline="$(nvidia-smi ${CUDA_VISIBLE_DEVICES:+--id="$CUDA_VISIBLE_DEVICES"} --query-gpu=memory.used --format=csv,noheader,nounits | awk '{s+=$1} END {print s+0}')"
fi
IFS=',' read -r -a ids <<<"$models"
for id in "${ids[@]}"; do
  port=$((8000 + RANDOM % 1000))
  suffix=""
  [[ "$max_pixels" != 0 ]] && suffix="-px$max_pixels"
  if [[ "$server" == vllm ]]; then
    pid="$("$here/serve-vllm.sh" "$id" "$port")" || { echo "GROUNDING-EVAL model=$id status=serve-failed"; status=1; continue; }
    served="$id" tag="$id$suffix" extra=(--structured --gpu-peak-file "$out/$id.gpu-peak")
  else
    pid="$("$here/serve-mlx.sh" "$id" "$port" "$quant")" || { echo "GROUNDING-EVAL model=$id status=serve-failed"; status=1; continue; }
    served="${GROUNDING_EVAL_MLX_CACHE:-$HOME/.cache/cmux-grounding/mlx}/$id-$quant" tag="$id-$quant$suffix" extra=()
  fi
  "$python" -I "$here/grounding_eval.py" run --data "$data" --model "$id" --server "$server" \
    --endpoint "http://127.0.0.1:$port/v1" --served-name "$served" --bench "$bench" --limit "$limit" \
    --max-pixels "$max_pixels" ${extra[@]+"${extra[@]}"} --resume --out "$out/$tag.json" || status=1
  stop_server "$pid"
  [[ -f "$out/$tag.json" ]] && results+=("$out/$tag.json")
done
if [[ ${#results[@]} -gt 0 ]]; then
  "$python" -I "$here/grounding_eval.py" summarize "${results[@]}" | tee "$out/summary.md"
fi
exit "$status"
