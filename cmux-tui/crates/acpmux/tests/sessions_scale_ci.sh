#!/usr/bin/env bash
# The sessions_scale bench (`sessions_scale.rs`) on a CI Linux runner, then a flat CPU profile of
# the daemon at N=2000 under churn, from the repo root:
#   cmux-ci test --timeout 3600 -- bash cmux-tui/crates/acpmux/tests/sessions_scale_ci.sh [NS] [PROFILE_N]
# Defaults: NS 50,200,2000 and PROFILE_N 2000 (empty: no profile). The profile needs `perf`; a runner
# without it says so and skips it. Extra steps (another bench) go in SCALE_CI_AFTER, run last.
set -uo pipefail
NS=${1:-50,200,2000}
PROFILE_N=${2-2000}
OUT=${FAST_CHECKS_OUT:-/tmp/sessions-scale-out}
mkdir -p "$OUT"
echo "runner: $(nproc) cpus, $(free -g | awk '/Mem:/{print $2}') GB"
cd cmux-tui || exit 1
cargo test -p acpmux --release --test sessions_scale --no-run 2>&1 | tail -3
ACPMUX_SCALE_NS=$NS cargo test -p acpmux --release --test sessions_scale -- --ignored --nocapture \
  2>&1 | tee "$OUT/scale.log" | grep -E '^SCALE-(ROW|TABLE|RATIO)|panicked|test result'
code=${PIPESTATUS[0]}

if [ -n "$PROFILE_N" ]; then
  if ! command -v perf >/dev/null 2>&1; then
    sudo -n apt-get install -y -qq "linux-tools-$(uname -r)" linux-tools-generic >/dev/null 2>&1 || true
  fi
  PERF=$(command -v perf || ls /usr/lib/linux-tools/*/perf 2>/dev/null | head -1)
  if [ -z "$PERF" ] || ! "$PERF" --version >/dev/null 2>&1; then
    echo "PROFILE: no working perf on this runner; skipped"
  else
    sudo -n sysctl -q kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0 2>/dev/null || true
    bin=$(ls -t target/release/deps/sessions_scale-* | grep -v '\.d$' | head -1)
    ACPMUX_SCALE_NS=$PROFILE_N ACPMUX_SCALE_SECS=60 ACPMUX_SCALE_IDLE_SECS=2 "$bin" --ignored --nocapture \
      > "$OUT/profile-bench.log" 2>&1 &
    bench=$!
    daemon=
    for _ in $(seq 1 1200); do
      daemon=$(pgrep -P "$bench" -f 'daemon run' | head -1)
      [ -n "$daemon" ] && break
      sleep 0.5
    done
    # Past the list and idle windows, into the churn.
    sleep 40
    if [ -n "$daemon" ]; then
      sudo -n "$PERF" record -F 999 -p "$daemon" -o "$OUT/perf.data" -- sleep 20 >/dev/null 2>&1 \
        || "$PERF" record -F 999 -p "$daemon" -o "$OUT/perf.data" -- sleep 20 >/dev/null 2>&1
      sudo -n chmod a+r "$OUT/perf.data" 2>/dev/null || true
      "$PERF" report -i "$OUT/perf.data" --no-children --sort symbol --stdio 2>/dev/null \
        | grep -v '^#' | grep -v '^$' | head -70 | sed 's/^/PROFILE /'
      "$PERF" report -i "$OUT/perf.data" --no-children --sort comm --stdio 2>/dev/null \
        | grep -v '^#' | grep -v '^$' | head -15 | sed 's/^/PROFILE-THREAD /'
    else
      echo "PROFILE: the daemon was not found"
    fi
    wait "$bench"
    grep -E '^SCALE-TABLE' "$OUT/profile-bench.log" | sed 's/^/PROFILE-RUN /'
  fi
fi

cd ..
if [ -n "${SCALE_CI_AFTER:-}" ]; then
  echo "AFTER: $SCALE_CI_AFTER"
  bash -c "$SCALE_CI_AFTER"
fi
exit "$code"
