#!/usr/bin/env bash
# The fan-in ramps on a CI Linux runner, from the repo root:
#   cmux-ci test --setup rust --timeout 7200 --artifact DIR -- bash cmux-tui/crates/coord-sim/src/fanin/ci.sh [RAMPS] [WINDOW_S] [HOSTS]
# Builds the acpmux daemon (release) and coord-sim, runs `coord-sim fanin` (real daemons both sides,
# one controller, N sessions over HOSTS hosts) and copies the tables and raw samples to
# $FAST_CHECKS_OUT. Defaults: ramps 50,200,2000, a 300 s window, 10 hosts.
set -uo pipefail
RAMPS=${1:-50,200,2000}
WINDOW=${2:-300}
HOSTS=${3:-10}
ROOT=$(pwd)
OUT=${FAST_CHECKS_OUT:-/tmp/fanin-out}
mkdir -p "$OUT"
ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true
ulimit -u unlimited 2>/dev/null || true
echo "runner: $(nproc) cpus, $(free -g | awk '/Mem:/{print $2}') GB, nofile $(ulimit -n), nproc $(ulimit -u)"
(cd cmux-tui && cargo build --release -p acpmux --bin acpmux) || { echo "FANIN: acpmux build failed"; exit 1; }
BIN=${CARGO_TARGET_DIR:-$ROOT/cmux-tui/target}/release/acpmux
(cd cmux-tui/crates/coord-sim && cargo build --release && cargo test --release fanin) || { echo "FANIN: coord-sim build/test failed"; exit 1; }
SIM=${CARGO_TARGET_DIR:-$ROOT/cmux-tui/crates/coord-sim/target}/release/coord-sim
[ -x "$BIN" ] && [ -x "$SIM" ] || { echo "FANIN: binaries missing ($BIN, $SIM)"; exit 1; }
# Under /tmp (sticky): acpmux refuses a state directory below a writable, non-sticky ancestor.
RUN=$(mktemp -d /tmp/fanin-run.XXXXXX)
chmod 700 "$RUN"
"$SIM" fanin --hosts "$HOSTS" --sessions 2000 --ramps "$RAMPS" --rate 0.333 --window-s "$WINDOW" \
  --out "$RUN" --acpmux "$BIN" --wall-clock-cap 6000 2>&1 | tee "$OUT/fanin.log" | grep -v '^FANIN_SUMMARY'
code=${PIPESTATUS[0]}
"$SIM" fanin teardown --out "$RUN" || true
cp "$RUN/fanin-summary.json" "$OUT/" 2>/dev/null || true
for d in "$RUN"/n*; do
  n=$(basename "$d")
  mkdir -p "$OUT/$n"
  cp "$d"/*.json "$OUT/$n/" 2>/dev/null || true
  gzip -c "$d/events.ndjson" > "$OUT/$n/events.ndjson.gz" 2>/dev/null || true
  cp "$d/ops.ndjson" "$d/proc.ndjson" "$OUT/$n/" 2>/dev/null || true
  for h in "$d"/controller "$d"/h00; do
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
