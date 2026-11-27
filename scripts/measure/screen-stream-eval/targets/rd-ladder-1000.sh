#!/usr/bin/env bash
# rd-ladder with the rate pinned at 1000 kbps: the budget where the frame-size guard's QP floor climbs
# past the ladder's ceiling (VideoToolbox -12902 before cmux#51389) and the ladder steps down.
set -euo pipefail
EVAL_RD_LADDER_KBPS=1000 exec bash "$(dirname "${BASH_SOURCE[0]}")/rd-ladder.sh" "$@"
