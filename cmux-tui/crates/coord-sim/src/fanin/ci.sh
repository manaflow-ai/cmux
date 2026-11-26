#!/usr/bin/env bash
# The fan-in ramps on a CI Linux runner, from the repo root:
#   cmux-ci test --setup rust --timeout 7200 --artifact DIR -- bash cmux-tui/crates/coord-sim/src/fanin/ci.sh [RAMPS] [WINDOW_S] [HOSTS] [ROUNDS] [perf]
# Builds the acpmux daemon (release) and coord-sim, runs `coord-sim fanin` (real daemons both sides,
# one controller, N sessions over HOSTS hosts) and copies the tables and raw samples to
# $FAST_CHECKS_OUT. Defaults: ramps 50,200,2000, a 300 s window, 10 hosts, 3 fan-out rounds
# (ROUNDS 0, or FANIN_FANOUT_ROUNDS=0, measures fan-in with no fan-out bursts). A 5th argument
# `perf` builds acpmux with frame pointers and profiles the largest ramp's controller (perf.self.txt, perf.children.txt, perf.stacks.gz, and offcpu.stacks.gz where sudo -n works).
set -uo pipefail
RAMPS=${1:-50,200,2000}
WINDOW=${2:-300}
HOSTS=${3:-10}
ROUNDS=${4:-${FANIN_FANOUT_ROUNDS:-3}}
PROFILE=${5:-}
ROOT=$(pwd)
OUT=${FAST_CHECKS_OUT:-/tmp/fanin-out}
mkdir -p "$OUT"
ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true
ulimit -u unlimited 2>/dev/null || true
echo "runner: $(nproc) cpus, $(free -g | awk '/Mem:/{print $2}') GB, nofile $(ulimit -n), nproc $(ulimit -u)"
# A private target dir: a runner's shared one is written by other jobs at the same time, and cargo
# there linked another commit's cmux-tui-platform into this head's acpmux (cmux#49864 run32:
# "cannot find value ACPMUX_ARENAS", a constant this commit defines). It builds cold, which a
# 2-hour timeout covers.
export CARGO_TARGET_DIR=$ROOT/target-fanin
if [ "$PROFILE" = perf ]; then export RUSTFLAGS="${RUSTFLAGS:-} -C force-frame-pointers=yes"; fi
# FANIN_ACPMUX_BIN: a daemon built already (abba.sh runs a base build and a head build in turn).
if [ -n "${FANIN_ACPMUX_BIN:-}" ]; then
  BIN=$FANIN_ACPMUX_BIN
else
  (cd cmux-tui && cargo build --release -p acpmux --bin acpmux) || { echo "FANIN: acpmux build failed"; exit 1; }
  BIN=${CARGO_TARGET_DIR:-$ROOT/cmux-tui/target}/release/acpmux
fi
(cd cmux-tui/crates/coord-sim && env -u RUSTFLAGS cargo build --release && env -u RUSTFLAGS cargo test --release fanin) || { echo "FANIN: coord-sim build/test failed"; exit 1; }
SIM=${CARGO_TARGET_DIR:-$ROOT/cmux-tui/crates/coord-sim/target}/release/coord-sim
[ -x "$BIN" ] && [ -x "$SIM" ] || { echo "FANIN: binaries missing ($BIN, $SIM)"; exit 1; }
# Under /tmp (sticky): acpmux refuses a state directory below a writable, non-sticky ancestor.
RUN=$(mktemp -d /tmp/fanin-run.XXXXXX)
chmod 700 "$RUN"
# Each ramp starts its daemons from the binary path again, and a runner's target dir can be
# shared: another job's build there swapped a later ramp's controller to another commit's acpmux
# (cmux#49864 run29: n=2000 read build 3ded5d2ce while n=50 read this head). Run private copies.
mkdir -p "$RUN/bin" && cp "$BIN" "$RUN/bin/acpmux" && cp "$SIM" "$RUN/bin/coord-sim" \
  || { echo "FANIN: cannot copy the binaries into $RUN/bin"; exit 1; }
BIN=$RUN/bin/acpmux SIM=$RUN/bin/coord-sim
echo "FANIN: acpmux $("$BIN" --version 2>/dev/null | head -1)"
# The largest ramp's controller, found by the home in its environment (`fanin/fleet.rs` env_for).
profile() {
  local top=${RAMPS##*,} pid="" p
  command -v perf >/dev/null || { echo "FANIN perf: perf is not installed on this runner"; return; }
  # Ubuntu runners ship perf_event_paranoid 4 (no user profiling at all); a CI runner's sudo lowers it.
  if [ "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)" -gt 1 ] 2>/dev/null; then
    sudo -n sysctl -qw kernel.perf_event_paranoid=1 2>/dev/null \
      || echo "FANIN perf: perf_event_paranoid is $(cat /proc/sys/kernel/perf_event_paranoid) and sudo -n cannot lower it"
  fi
  for _ in $(seq 1 3600); do
    for p in $(pgrep -f -- "$BIN daemon run" || true); do
      tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q "n$top/controller" && { pid=$p; break; }
    done
    [ -n "$pid" ] && break
    sleep 1
  done
  [ -n "$pid" ] || { echo "FANIN perf: no controller for n=$top"; return; }
  echo "FANIN perf: recording controller pid $pid"
  # Where its threads block (a lock, a full channel): each switch away, with its stack. A
  # scheduler tracepoint, so it needs root; a runner without `sudo -n` keeps the CPU profile only.
  local off=""
  if sudo -n true 2>/dev/null; then
    sudo -n perf record -e sched:sched_switch --call-graph fp -p "$pid" -o "$OUT/offcpu.data" \
      -- sleep $((WINDOW + 30)) >"$OUT/offcpu.record.log" 2>&1 &
    off=$!
  fi
  # perf exits non-zero when the controller ends first: what it wrote is the profile either way.
  perf record -F 299 --call-graph fp -p "$pid" -o "$OUT/perf.data" -- sleep $((WINDOW + 30)) >"$OUT/perf.record.log" 2>&1
  if [ -n "$off" ]; then
    wait "$off"
    sudo -n perf script -i "$OUT/offcpu.data" -F tid,time,ip,sym 2>/dev/null | gzip >"$OUT/offcpu.stacks.gz"
    sudo -n rm -f "$OUT/offcpu.data"
    echo "FANIN perf: off-CPU $(grep -o '([0-9]* samples)' "$OUT/offcpu.record.log")"
  fi
  [ -s "$OUT/perf.data" ] || { echo "FANIN perf: record failed: $(tail -3 "$OUT/perf.record.log")"; return; }
  echo "FANIN perf: $(grep -o '([0-9]* samples)' "$OUT/perf.record.log")"
  perf report -i "$OUT/perf.data" --stdio --no-children --sort sym -g none --percent-limit 0.3 >"$OUT/perf.self.txt" 2>/dev/null
  perf report -i "$OUT/perf.data" --stdio --children --sort sym -g none --percent-limit 2 >"$OUT/perf.children.txt" 2>/dev/null
  # Every sample's stack, for any caller/callee split afterwards (perf.data itself is too big to keep).
  perf script -i "$OUT/perf.data" -F tid,time,ip,sym 2>/dev/null | gzip >"$OUT/perf.stacks.gz"
  rm -f "$OUT/perf.data"
  echo "FANIN perf: top self:"; grep -E '^ +[0-9]' "$OUT/perf.self.txt" | head -25
}
[ "$PROFILE" = perf ] && { profile & PROF=$!; }
"$SIM" fanin --hosts "$HOSTS" --sessions 2000 --ramps "$RAMPS" --rate 0.333 --window-s "$WINDOW" --fanout-rounds "$ROUNDS" \
  --out "$RUN" --acpmux "$BIN" --wall-clock-cap 6000 2>&1 | tee "$OUT/fanin.log" | grep -v '^FANIN_SUMMARY'
code=${PIPESTATUS[0]}
[ -n "${PROF:-}" ] && wait "$PROF"
"$SIM" fanin teardown --out "$RUN" || true
cp "$RUN/fanin-summary.json" "$OUT/" 2>/dev/null || true
for d in "$RUN"/n*; do
  n=$(basename "$d")
  mkdir -p "$OUT/$n"
  cp "$d"/*.json "$OUT/$n/" 2>/dev/null || true
  gzip -c "$d/events.ndjson" > "$OUT/$n/events.ndjson.gz" 2>/dev/null || true
  cp "$d/ops.ndjson" "$d/proc.ndjson" "$OUT/$n/" 2>/dev/null || true
  for h in "$d"/controller "$d"/h[0-9]*; do
    [ -f "$h/daemon.stderr" ] && tail -c 20000 "$h/daemon.stderr" > "$OUT/$n/$(basename "$h").stderr.tail"
  done
done
python3 - "$RUN/fanin-summary.json" <<'PY' || true
import json, sys
d = json.load(open(sys.argv[1]))
print("FANIN ratios vs n=%s:" % d.get("ratio_base_n"))
for r in d["ratios"]:
    print("  ", json.dumps(r))
for t in d["tables"]:
    if "error" in t:
        print("FANIN n=%s ERROR %s" % (t["n"], t["error"][:400]))
        continue
    c = t["controller"]
    print("FANIN n=%s attach p95 %s ms, attach_one p95 %s, fanin p95 %s, fanout p95 %s, list %s ms, cpu %s%% (%s/session), rss %s KB (%s/session), lost %s dup %s, gaps %s" % (
        t["n"], t["attach_ms"].get("p95"), t["attach_one_ms"].get("p95"), t["fanin_ms"].get("p95"),
        t["fanout_ms"].get("p95"), t["list"]["whole_ms_at_rest"], c["cpu_pct"], c["cpu_pct_per_session"],
        c["rss_kb"], c["rss_kb_per_session"], t["events"]["lost"], t["events"]["dup"], t["gaps"]))
print("FANIN goal_met_at_2000:", d.get("goal_met_at_2000"))
PY
[ -f "$RUN/fanin-summary.json" ] && summary=1 || summary=0
rm -rf "$RUN"
echo "FANIN exit $code"
# A failed fleet run returns no artifacts: once a summary exists (a ramp that broke is in it), exit 0.
[ "$summary" = 1 ] && exit 0
exit "$code"
