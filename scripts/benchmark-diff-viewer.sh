#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE_BYTES="${CMUX_DIFF_BENCH_BYTES:-16777216}"
ITERATIONS="${CMUX_DIFF_BENCH_ITERATIONS:-20}"
export CMUX_DIFF_BENCH_MAX_MANIFEST_P95_US="${CMUX_DIFF_BENCH_MAX_MANIFEST_P95_US:-1000}"
export CMUX_DIFF_BENCH_MIN_READ_MIBPS="${CMUX_DIFF_BENCH_MIN_READ_MIBPS:-500}"
export CMUX_DIFF_BENCH_MAX_STREAM_P95_MS="${CMUX_DIFF_BENCH_MAX_STREAM_P95_MS:-250}"

"${ROOT}/scripts/run-diff-sidecar-cargo.sh" run \
  --quiet \
  --release \
  --locked \
  --manifest-path "${ROOT}/Native/DiffSidecar/Cargo.toml" \
  --bin cmux-diff-sidecar \
  --features benchmark \
  -- benchmark "$SAMPLE_BYTES" "$ITERATIONS"

(
  cd "${ROOT}/webviews"
  CMUX_DIFF_BENCH_ITERATIONS="${CMUX_DIFF_WEB_BENCH_ITERATIONS:-5}" \
    CMUX_DIFF_BENCH_RENDER_APP="${CMUX_DIFF_BENCH_RENDER_APP:-1}" \
    bun run benchmark
)
