#!/usr/bin/env bash
# Measurement only (to be removed before merge): this PR's before/after on cmux#51033's duress
# bench (its tests/duress_daemon.rs at 46691d6b199d, copied here). One worker, one test binary,
# two acpmux binaries: "after" is this tree, "before" is this tree with fix.patch reversed (base).
# Order before, after, after, before. The bench runs a pinned copy of target/release/acpmux, so
# each run copies its binary in right before it starts.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tui="$(cd "$here/../cmux-tui" && pwd)"
out="${FAST_CHECKS_OUT:-$(mktemp -d)}"
bins="$(mktemp -d)"
cd "$tui"
cp "$here/duress_daemon.rs" crates/acpmux/tests/duress_daemon.rs
host() { echo "host=$(hostname) cores=$(nproc) load='$(cut -d' ' -f1-3 /proc/loadavg)' free=$(df -h --output=avail /tmp | tail -1)"; }
echo "== host"; host
cargo build --release -p acpmux --bin acpmux 2>&1 | tail -1
exe="$(cargo test -p acpmux --release --test duress_daemon --no-run --message-format=json \
  | grep '"executable":"[^"]*duress_daemon' | sed 's/.*"executable":"\([^"]*\)".*/\1/' | tail -1)"
bin="$(dirname "$(dirname "$exe")")/acpmux"
cp "$bin" "$bins/after"
(cd "$tui/.." && git apply -R "$here/fix.patch")
cargo build --release -p acpmux --bin acpmux 2>&1 | tail -1
cp "$bin" "$bins/before"
(cd "$tui/.." && git apply "$here/fix.patch")
cp "$exe" "$bins/bench"
sha256sum "$bins"/*
run() {
  local label="$1" which="$2"
  mkdir -p "$out/$label"
  cp "$bins/$which" "$bin"
  echo "== $label ($which)"; host
  ACPMUX_DURESS=1 ACPMUX_DURESS_LEGS="${LEGS:-baseline,cpu}" FAST_CHECKS_OUT="$out/$label" \
    "$bins/bench" --ignored --nocapture duress_bench 2>&1 | grep -E 'DURESS-SUMMARY|panicked|FAILED|test result' || echo "run $label exited $?"
  echo "-- $label duress-bench.md:"; cat "$out/$label/duress-bench.md" 2>/dev/null || echo "(no md)"
}
run r1-before before
run r2-after after
run r3-after after
run r4-before before
echo "outputs in $out"
