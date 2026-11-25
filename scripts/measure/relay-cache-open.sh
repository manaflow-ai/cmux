#!/usr/bin/env bash
# Relay cache rows (RFD 0142 R2/R9; cmux-next-ios/rust/crates/cmux-mobile-host/tests/relay_cache_rows.rs):
# first content with the Mac asleep (`mac-asleep x cold-open`) and resume after sleep
# (`lte x resume-after-sleep x relay`), before (cache off: today's path, waits for the Mac) and after
# (the relay's sealed snapshot and delta catch-up), idle and under the pair matrix's duress, over
# cmux-fault's seeded `lte` shaper. Prints `RELAYCELL {json}` per run and `RELAYROW {json}` per cell.
# Env RELAYCACHE_COLD_RUNS (default 5) and RELAYCACHE_RESUME_RUNS (default 10) pass through.
#   cmux-ci test -- bash -c 'scripts/measure/relay-cache-open.sh'
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/cmux-next-ios/rust"
cargo test --release -p cmux-mobile-host --test relay_cache_rows -- --ignored --nocapture 2>&1 \
  | grep -E '^(RELAYCELL|RELAYROW) |panicked|^test result' 
