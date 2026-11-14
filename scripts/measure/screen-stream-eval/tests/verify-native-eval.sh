#!/usr/bin/env bash
# Fleet-only behavioral regression receipt, including old-code counterexamples.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
eval_dir="$root/scripts/measure/screen-stream-eval"
crate="$root/cmux-tui/crates/cmux-rd-host"
work=$(mktemp -d)
finish() {
  [[ ! -f "$work/bench-after.rs" ]] || cp "$work/bench-after.rs" "$crate/src/bench.rs"
  if [[ -n "${FAST_CHECKS_OUT:-}" ]]; then
    for file in metrics-before.log hello-before.log; do
      [[ ! -f "$work/$file" ]] || cp "$work/$file" "$FAST_CHECKS_OUT/$file"
    done
  fi
}
trap finish EXIT
# Broker snapshots contain the requested tree, not its complete history.
# Fetch the exact old commit used by both counterexamples explicitly.
git fetch --no-tags --depth=1 origin 32a072d97bd66eba4cec3a17ddc0d4ed960db2b7
cp "$eval_dir/test_rd_metrics.py" "$work/test_rd_metrics.py"
git show 32a072d97bd66eba4cec3a17ddc0d4ed960db2b7:scripts/measure/screen-stream-eval/rd-metrics.py >"$work/rd-metrics.py"
if python3 "$work/test_rd_metrics.py" >"$work/metrics-before.log" 2>&1; then
  echo 'FAIL: original metrics unexpectedly passed' >&2
  exit 1
fi
cat "$work/metrics-before.log"
python3 "$eval_dir/test_rd_metrics.py"
python3 "$eval_dir/test_eval.py"
cd "$root/cmux-tui"
cargo fmt --manifest-path "$crate/Cargo.toml" --check
cargo clippy --manifest-path "$crate/Cargo.toml" --no-default-features --features bench --all-targets -- -D warnings
cargo test --manifest-path "$crate/Cargo.toml" --no-default-features --features bench eval::tests
cargo build --manifest-path "$crate/Cargo.toml" --no-default-features --features bench
export CMUX_RD_EVAL_BIN="${CARGO_TARGET_DIR:-$crate/target}/debug/cmux-rd"
python3 "$eval_dir/test_netem.py"
# Restore the one changed native caller to reproduce the real Hello bypass.
cp "$crate/src/bench.rs" "$work/bench-after.rs"
git show 32a072d97bd66eba4cec3a17ddc0d4ed960db2b7:cmux-tui/crates/cmux-rd-host/src/bench.rs >"$crate/src/bench.rs"
cargo build --manifest-path "$crate/Cargo.toml" --no-default-features --features bench
if python3 "$eval_dir/test_netem.py" RelayTests.test_native_hello_advertises_relay_and_registers_viewer >"$work/hello-before.log" 2>&1; then
  echo 'FAIL: original native Hello unexpectedly passed' >&2
  exit 1
fi
cat "$work/hello-before.log"
cp "$work/bench-after.rs" "$crate/src/bench.rs"
