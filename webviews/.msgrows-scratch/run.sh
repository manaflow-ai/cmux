#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
export OUT="${FAST_CHECKS_OUT:-/tmp/msgrows-shots}"
export SCENES="${SCENES:-agent-pane.message-line-look:leo-capture:dark,agent-pane.message-line-look:leo-capture:light,agent-pane.message-line-look:leo-capture-stacked:dark,agent-pane.message-line-look:single:dark,agent-pane.agent-message-row:both-directions:dark,agent-pane.agent-message-row:folded-run-opened:dark,agent-pane.agent-message-row:lanes:dark,agent-pane.received-messages:collapsed:dark}"
bun .msgrows-scratch/capture.ts
W=520 SCENES=agent-pane.message-line-look:leo-capture:dark OUT="$OUT/narrow" bun .msgrows-scratch/capture.ts
ls -la "$OUT"
