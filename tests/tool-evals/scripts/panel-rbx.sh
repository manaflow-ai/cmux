#!/bin/bash
# tool-evals panel on rbx: [CMUX_BIN=path] ~/tool-evals-panel.sh <tag> [surface]; one run per model, all in parallel.
TAG=$1; SURFACE=${2:-code}
L=/work/lanes/feat-cmux-next-tool-evals
set -a; . ~/.secrets/openrouter.env; set +a
cd $L/src/tests/tool-evals
MODELS="${PANEL_MODELS:-deepseek/deepseek-v4.1-flash-1017 qwen/qwen3.8-max-0902 moonshotai/kimi-k3.1-pro z-ai/glm-5.3-flashx z-ai/glm-5.3-prime google/gemini-4-argon x-ai/grok-4.7 minimax/minimax-m3.1-flash mistralai/mistral-large-4-0}"
mkdir -p ~/tool-evals-runs
for m in $MODELS; do
  slug=$(echo "$m" | tr "/." "--")
  ~/.bun/bin/bun run.mjs --cli ${CMUX_BIN:-$L/target/debug/cmux-tui} --model "openrouter:$m" --surface $SURFACE --samples 2 --concurrency 5 \
    --out ~/tool-evals-runs/$TAG-$SURFACE-$slug > ~/tool-evals-runs/$TAG-$SURFACE-$slug.log 2>&1 &
done
wait
echo "panel $TAG $SURFACE done"
