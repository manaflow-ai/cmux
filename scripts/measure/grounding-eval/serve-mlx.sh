#!/usr/bin/env bash
# Serve one grounding model with mlx-vlm on Apple silicon (OpenAI-compatible, 127.0.0.1 only).
#   serve-mlx.sh MODEL_ID [PORT] [QUANT]   MODEL_ID from models.json; QUANT is bf16 (default), 8 or 4 bits
# The weights are converted once into $GROUNDING_EVAL_MLX_CACHE (default ~/.cache/cmux-grounding/mlx) and
# reused. Prints the server's pid once /v1/models answers; stop it with `kill PID`. mlx-vlm reports each
# request's peak memory (timings.peak_memory_gb), which grounding_eval.py records.
# Needs: python3 with mlx-vlm (pip install 'mlx-vlm>=0.7.12'), macOS on Apple silicon.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
model_id="${1:?model id from models.json}"
port="${2:-8080}"
quant="${3:-bf16}"
out="${GROUNDING_EVAL_OUT:-$PWD/.build/grounding-eval}"
cache="${GROUNDING_EVAL_MLX_CACHE:-$HOME/.cache/cmux-grounding/mlx}"
python="${GROUNDING_EVAL_PYTHON:-python3}"
mkdir -p "$out" "$cache"
read -r hf min_pixels max_pixels < <(python3 -I -c '
import json, sys
m = {m["id"]: m for m in json.load(open(sys.argv[1]))["models"]}[sys.argv[2]]
assert m["serve"] in ("mlx", "both"), m["id"] + " does not serve on mlx"
print(m["hf"], m["min_pixels"], m["max_pixels"])' "$here/models.json" "$model_id")

dir="$cache/$model_id-$quant"
if [[ ! -f "$dir/config.json" ]]; then
  convert=(-m mlx_vlm.convert --hf-path "$hf" --mlx-path "$dir.part")
  case "$quant" in
    bf16) convert+=(--dtype bfloat16) ;;
    4|8) convert+=(-q --q-bits "$quant") ;;
    *) echo "serve-mlx.sh: QUANT is bf16, 8 or 4" >&2; exit 2 ;;
  esac
  rm -rf "$dir.part"
  "$python" "${convert[@]}" >"$out/$model_id-$quant.convert.log" 2>&1
  # Holo2's template turns thinking off only on `thinking`, and mlx-vlm passes the template only
  # `enable_thinking`: let either one turn it off.
  python3 -I - "$dir.part" <<'PY'
import json, pathlib, sys
old = "thinking is defined and thinking is false"
new = "(thinking is defined and thinking is false) or (enable_thinking is defined and enable_thinking is false)"
for path in pathlib.Path(sys.argv[1]).glob("*"):
    if path.suffix in (".jinja", ".json") and path.is_file():
        text = path.read_text()
        if old in text:
            path.write_text(text.replace(old, new))
PY
  mv "$dir.part" "$dir"
fi

# The card's pixel bounds, as the eval resizes to them; a vision cache of one (mlx-vlm needs at least
# one), with the eval's shuffled order, keeps a repeated screenshot from being served from cache.
"$python" -m mlx_vlm.server --host 127.0.0.1 --port "$port" --model "$dir" --min-pixels "$min_pixels" \
  --max-pixels "$max_pixels" --vision-cache-size 1 >"$out/$model_id-$quant.mlx.log" 2>&1 </dev/null &
pid=$!
for _ in $(seq 1 300); do
  if curl -fsS "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; then echo "$pid"; exit 0; fi
  kill -0 "$pid" 2>/dev/null || { echo "serve-mlx.sh: mlx-vlm exited; see $out/$model_id-$quant.mlx.log" >&2; tail -30 "$out/$model_id-$quant.mlx.log" >&2; exit 1; }
  sleep 2
done
echo "serve-mlx.sh: $model_id did not answer in 10 minutes" >&2
kill "$pid"
exit 1
