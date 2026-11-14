#!/usr/bin/env bash
# Fleet-only behavioral regression receipt, including old-code counterexamples.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
# Fetching the counterexamples must not start background Git maintenance.
source "$root/scripts/cmux-next/tests/lib/git-fixture.sh"
eval_dir="$root/scripts/measure/screen-stream-eval"
crate="$root/cmux-tui/crates/cmux-rd-host"
work=$(mktemp -d)
finish() {
  [[ ! -f "$work/bench-after.rs" ]] || cp "$work/bench-after.rs" "$crate/src/bench.rs"
  if [[ -n "${FAST_CHECKS_OUT:-}" ]]; then
    for file in metrics-before.log hello-before.log cleanup-before.log tcp-before.log alternate-before.log; do
      [[ ! -f "$work/$file" ]] || cp "$work/$file" "$FAST_CHECKS_OUT/$file"
    done
  fi
}
git_fixture_trap_exit finish
# Broker snapshots contain the requested tree, not its complete history.
# Fetch the exact old commit used by both counterexamples explicitly.
git fetch --no-tags --depth=1 origin 32a072d97bd66eba4cec3a17ddc0d4ed960db2b7
cp "$eval_dir/test_netem.py" "$work/test_netem.py"
git show 32a072d97bd66eba4cec3a17ddc0d4ed960db2b7:scripts/measure/screen-stream-eval/netem.py >"$work/netem.py"
if python3 "$work/test_netem.py" RelayTests.test_idle_tcp_survives_connect_deadline >"$work/tcp-before.log" 2>&1; then
  echo 'FAIL: original idle TCP relay unexpectedly passed' >&2
  exit 1
fi
cat "$work/tcp-before.log"
python3 "$eval_dir/test_netem.py" RelayTests.test_idle_tcp_survives_connect_deadline
cp "$eval_dir/test_rd_metrics.py" "$work/test_rd_metrics.py"
git show 32a072d97bd66eba4cec3a17ddc0d4ed960db2b7:scripts/measure/screen-stream-eval/rd-metrics.py >"$work/rd-metrics.py"
if CMUX_RD_METRICS_LEGACY=1 python3 "$work/test_rd_metrics.py" >"$work/metrics-before.log" 2>&1; then
  echo 'FAIL: original metrics unexpectedly passed' >&2
  exit 1
fi
cat "$work/metrics-before.log"
python3 "$eval_dir/test_rd_metrics.py"
python3 -m unittest discover -s "$eval_dir" -p 'test_eval*.py'
python3 "$eval_dir/test_rd_cleanup.py"
git show 32a072d97bd66eba4cec3a17ddc0d4ed960db2b7:scripts/measure/screen-stream-eval/targets/rd.sh >"$work/rd-before.sh"
if RD_CLEANUP_SCRIPT="$work/rd-before.sh" python3 "$eval_dir/test_rd_cleanup.py" >"$work/cleanup-before.log" 2>&1; then
  echo 'FAIL: original cleanup unexpectedly passed' >&2
  exit 1
fi
cat "$work/cleanup-before.log"
cd "$root/cmux-tui"
cargo fmt --manifest-path "$crate/Cargo.toml" --check
cargo clippy --manifest-path "$crate/Cargo.toml" --no-default-features --features bench --all-targets -- -D warnings
cargo test --manifest-path "$crate/Cargo.toml" --no-default-features --features bench eval::tests
cargo build --manifest-path "$crate/Cargo.toml" --no-default-features --features bench
export CMUX_RD_EVAL_BIN="${CARGO_TARGET_DIR:-$crate/target}/debug/cmux-rd"
python3 "$eval_dir/test_netem.py"
# The merged codec adapter must contribute successful decodes to the passive
# first-frame gate. The same branch handles VP9 and AV1; exercise it via the
# AV1 feature without requiring a system codec library.
cargo test --manifest-path "$crate/Cargo.toml" --no-default-features --features bench,av1 bench::eval_tests
cp "$crate/src/bench.rs" "$work/bench-after.rs"
git fetch --no-tags --depth=1 origin 2d4c0800300a0e3e52ec9ced6c3aa99e61fdb147
git show 2d4c0800300a0e3e52ec9ced6c3aa99e61fdb147:cmux-tui/crates/cmux-rd-host/src/bench.rs >"$crate/src/bench.rs"
cat >>"$crate/src/bench.rs" <<'EOF'

#[cfg(all(test, any(feature = "vp9", feature = "av1")))]
#[path = "bench_eval_tests.rs"]
mod eval_tests;
EOF
if cargo test --manifest-path "$crate/Cargo.toml" --no-default-features --features bench,av1 bench::eval_tests >"$work/alternate-before.log" 2>&1; then
  echo 'FAIL: unintegrated alternate decoder unexpectedly passed' >&2
  exit 1
fi
cat "$work/alternate-before.log"
cp "$work/bench-after.rs" "$crate/src/bench.rs"
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
