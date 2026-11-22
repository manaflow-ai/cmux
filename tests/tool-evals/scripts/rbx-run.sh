#!/bin/bash
# Runs tool-evals on the rbx host: rbx-run.sh <out-name> <run.mjs args...>. Results land in
# /home/lawrence/tool-evals-runs/<out-name> there; the laptop runs no daemons.
set -euo pipefail
NAME=$1; shift
ssh -o BatchMode=yes cmux-rust-builder-1 bash -s -- "$NAME" "$@" <<'REMOTE'
set -euo pipefail
NAME=$1; shift
L=/work/lanes/feat-cmux-next-tool-evals
set -a; . ~/.secrets/openrouter.env; set +a
mkdir -p ~/tool-evals-runs
cd $L/src/tests/tool-evals
exec ~/.bun/bin/bun run.mjs --cli $L/target/debug/cmux-tui --out ~/tool-evals-runs/$NAME "$@"
REMOTE
