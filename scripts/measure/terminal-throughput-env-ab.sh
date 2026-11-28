#!/usr/bin/env bash
# Terminal throughput A/B of one env knob on one binary and one machine (goal terminal-throughput): the cmux-tui
# stage bench (cmux-tui/crates/cmux-tui/tests/terminal_throughput_stages.rs) built once, then run with the knob at
# each value in turn, interleaved for ROUNDS rounds, so host noise lands on every arm alike. Linux; run at a
# pushed head:
#
#   cmux-ci test -- bash scripts/measure/terminal-throughput-env-ab.sh VAR VALUE_A VALUE_B [ROUNDS=3]
#
# e.g. VAR=CMUX_HOST_PARSER_COALESCE_BYTES 0 65536. Env passed through: CMUX_THROUGHPUT_MB (200),
# CMUX_THROUGHPUT_RUNS (3), CMUX_THROUGHPUT_STAGES (daemon-hosted,daemon-hosted+viewer-frames). Prints each
# run's stage table rows, then the median MB/s per arm and stage. Exits non-zero when a bench run fails.
set -euo pipefail
var=${1:?VAR}; a=${2:?VALUE_A}; b=${3:?VALUE_B}; rounds=${4:-3}
root=$(cd "$(dirname "$0")/../.." && pwd)
# A CI checkout without submodules has an empty ghostty-next; ghostty-vt-sys needs it.
[ -f "$root/ghostty-next/build.zig" ] || git -C "$root" submodule update --init --depth 1 ghostty-next
cd "$root/cmux-tui"
export CMUX_THROUGHPUT_MB=${CMUX_THROUGHPUT_MB:-200}
export CMUX_THROUGHPUT_RUNS=${CMUX_THROUGHPUT_RUNS:-3}
export CMUX_THROUGHPUT_STAGES=${CMUX_THROUGHPUT_STAGES:-daemon-hosted,daemon-hosted+viewer-frames}
cargo test --release -p cmux-tui --test it --no-run
rows=$(mktemp)
trap 'rm -f "$rows"' EXIT
for round in $(seq 1 "$rounds"); do
  for value in "$a" "$b"; do
    echo "=== round $round $var=$value"
    out=$(env "$var=$value" cargo test --release -p cmux-tui --test it -- terminal_throughput_stages:: --ignored --nocapture 2>&1)
    grep -E '^\| (daemon|pty)' <<<"$out" | cut -c1-220
    grep -E '^\| (daemon|pty)' <<<"$out" | awk -F'|' -v v="$value" '{gsub(/ /,"",$2); gsub(/ /,"",$3); print v, $2, $3}' >>"$rows"
    grep -q 'test result: ok' <<<"$out" || { echo "bench failed at $var=$value"; tail -40 <<<"$out"; exit 1; }
  done
done
echo "=== median MB/s ($var)"
sort -k1,1 -k2,2 "$rows" | awk '{k=$1" "$2; v[k]=v[k]" "$3} END {for (k in v) {n=split(v[k],x," "); asort(x); printf "%s %s median %.1f (n=%d)\n", k, "", (n%2 ? x[(n+1)/2] : (x[n/2]+x[n/2+1])/2), n}}' | sort
