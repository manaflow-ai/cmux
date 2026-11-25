#!/usr/bin/env bash
# Cloud session history: GiB freed by offloading every acpmux chat of a home, and the open time
# (every event read) p50/p95/max for a local chat, a locally archived chat (thaw) and an offloaded
# one (fetch + decrypt + thaw), before and after, from one harness
# (cmux-tui/crates/acpmux/examples/cloud_history_bench.rs; design: cmuxterm-hq
# docs/design/cloud-session-history.md). It works on a private COPY of the home, never the live
# one, and deletes the copy at the end.
#   scripts/measure/cloud-history-bench.sh [SESSIONS_DIR]   (default ~/.acpmux/sessions)
# With CMUX_SESSION_CLOUD_ORIGIN and CMUX_SESSION_CLOUD_TOKEN set, blobs go to that /v1/sync store;
# otherwise to a local folder (no network leg). CLOUD_HISTORY_BENCH_BIN runs a prebuilt binary
# (a Mac with no cargo); else it is built here in release. Prints one JSON line.
set -euo pipefail
src="${1:-$HOME/.acpmux/sessions}"
[[ -d "$src" ]] || { echo "cloud-history-bench.sh: no sessions folder at $src" >&2; exit 2; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bin="${CLOUD_HISTORY_BENCH_BIN:-}"
if [[ -z "$bin" ]]; then
  (cd "$repo_root/cmux-tui" && cargo build -q --release --locked -p acpmux --example cloud_history_bench)
  bin="$(cd "$repo_root/cmux-tui" && cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')/release/examples/cloud_history_bench"
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/blobs"
cp -a "$src" "$work/home/sessions"
# acpmux refuses a home it does not own privately.
chmod -R go-rwx "$work"
"$bin" "$work/home" "$work/blobs"
