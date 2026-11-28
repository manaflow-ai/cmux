#!/usr/bin/env bash
# cloud-add-repo-mirror.sh: Cloud "Add repository" (git.seed.start clone_only, cmux-tui-core
# git_seed) of a real public GitHub repository, with the per-machine warm mirror off (today's
# direct blobless clone), on and cold (the add that makes the mirror) and on and warm (a second
# add of the same repository into another chat's folder), RUNS times each, then CROWD adds at
# once off, cold and warm. It runs the service's own code (the ignored test
# git_seed::tests::mirror::measure_add_repository_cold_and_warm), the anonymous GitHub path, in
# a fresh temp home, so nothing already on the machine is borrowed.
#
# Every line is stamped with the time; START names each row as it begins and WAIT is a
# running add's status every 30 s, so a stall reads apart from a slow clone.
#
# Each ROW: seconds until every add is done, pack_mb (bytes from GitHub written as packs: the
# folders' own objects plus what the mirror gained) and rx_mb (the machine's received bytes over
# the row, Linux only; noisy on a shared machine).
#
# Usage: scripts/measure/cloud-add-repo-mirror.sh [URL] [RUNS] [CROWD] [MODES]
#   URL    default https://github.com/manaflow-ai/cmux.git
#   RUNS   default 3; CROWD default 8 (1: no crowd rows).
#   MODES  e.g. cold-x8,warm-x8: only those rows (warm needs its cold before it).
# On the fleet: cmux-ci test -- scripts/measure/cloud-add-repo-mirror.sh
set -euo pipefail
cd "$(dirname "$0")/../../cmux-tui"
export CMUX_SEED_MEASURE_URL=${1:-https://github.com/manaflow-ai/cmux.git}
export CMUX_SEED_MEASURE_RUNS=${2:-3}
export CMUX_SEED_MEASURE_CROWD=${3:-8}
export GIT_TERMINAL_PROMPT=0
export CMUX_SEED_MEASURE_MODES=${4:-${CMUX_SEED_MEASURE_MODES:-}}
cargo test -q -p cmux-tui-core --lib git_seed::tests::mirror::measure_add_repository_cold_and_warm \
  -- --ignored --nocapture --test-threads 1 2>&1 |
  while IFS= read -r line; do printf '%(%H:%M:%S)T %s\n' -1 "$line"; done
