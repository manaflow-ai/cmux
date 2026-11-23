#!/usr/bin/env bash
# rd with the resolution ladder (screen share P4, D3/D5): the host steps the picture down a rung when
# bits per pixel fall under the floor and caps the frame QP at 40, and the viewer sends the
# `video.scaled` cap that lets it (the Mac viewer pane does). Same harness as rd.sh otherwise.
set -euo pipefail
EVAL_RD_HOST_FLAGS="--resolution-ladder 1 --max-qp 40${EVAL_RD_LADDER_KBPS:+ --max-kbps $EVAL_RD_LADDER_KBPS}" EVAL_RD_BENCH_FLAGS="--caps video.scaled" \
  exec bash "$(dirname "${BASH_SOURCE[0]}")/rd.sh" "$@"
