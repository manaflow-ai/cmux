#!/usr/bin/env bash
# An ABBA duress number for an acpmux change, in one fleet job, from the repo root:
#   ABBA_BASE=SHA cmux-ci test --setup rust --timeout 10800 -- bash cmux-tui/crates/coord-sim/src/fanin/abba.sh [RAMP] [WINDOW_S] [HOSTS] [ROUNDS]
# Runs `ci.sh RAMP WINDOW_S HOSTS ROUNDS` four times: base1, head1, head2, base2. Head is this
# checkout; base is it with `git diff $ABBA_BASE HEAD -- cmux-tui/crates/acpmux/src` reverted (so
# ABBA_BASE is the commit the change starts from). While each runs, a sampler sums the CPU ticks of
# the host daemons (every `acpmux daemon run` but the controller). Host ms/prompt: their CPU above
# the window's idle baseline from 2 s before each fan-out round to 25 s after it, over the sessions;
# median and mean over the rounds. Prints one `ABBA` table row per run and the base and head
# averages, as cmux#57967's table. ABBA_PERF=1 also records host h00 in head1 and base1
# (perf.h00.*.txt), with frame pointers in every build.
set -uo pipefail
RAMP=${1:-2000}
WINDOW=${2:-300}
HOSTS=${3:-10}
ROUNDS=${4:-5}
ROOT=$(pwd)
OUT=${FAST_CHECKS_OUT:-/tmp/abba-out}
mkdir -p "$OUT"
HERE=cmux-tui/crates/coord-sim/src/fanin
[ -n "${ABBA_BASE:-}" ] || { echo "ABBA: set ABBA_BASE to the commit the change starts from"; exit 2; }
git cat-file -e "$ABBA_BASE^{commit}" 2>/dev/null || git fetch -q --depth=1 origin "$ABBA_BASE" \
  || { echo "ABBA: cannot fetch $ABBA_BASE"; exit 1; }
BASE=$(mktemp -d /tmp/abba-base.XXXXXX)
git worktree add -q --detach "$BASE" HEAD || { echo "ABBA: worktree failed"; exit 1; }
git diff "$ABBA_BASE" HEAD -- cmux-tui/crates/acpmux/src | git -C "$BASE" apply -R \
  || { echo "ABBA: the revert does not apply"; exit 1; }
echo "ABBA: head $(git rev-parse --short HEAD), base = head less $(git diff --stat "$ABBA_BASE" HEAD -- cmux-tui/crates/acpmux/src | tail -1)"
[ "${ABBA_PERF:-}" = 1 ] && export RUSTFLAGS="${RUSTFLAGS:-} -C force-frame-pointers=yes"
if [ "${ABBA_PERF:-}" = 1 ] && [ "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)" -gt 1 ] 2>/dev/null; then
  sudo -n sysctl -qw kernel.perf_event_paranoid=1 2>/dev/null || echo "ABBA perf: cannot lower perf_event_paranoid"
fi

# Samples "wall_us host_ticks controller_ticks" every 0.25 s into $1 until killed. A daemon that
# exits keeps its last count, so each column only grows.
sampler() {
  python3 - "$1" <<'PY'
import os, re, sys, time
out = open(sys.argv[1], "w", buffering=1)
kind, last = {}, {}
tick = os.sysconf("SC_CLK_TCK")
while True:
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            if pid not in kind:
                cmd = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
                if not (len(cmd) > 2 and cmd[0].endswith(b"/bin/acpmux") and cmd[1:3] == [b"daemon", b"run"]):
                    kind[pid] = None
                    continue
                env = open(f"/proc/{pid}/environ", "rb").read().split(b"\0")
                home = next((e[len(b"ACPMUX_HOME="):] for e in env if e.startswith(b"ACPMUX_HOME=")), b"")
                kind[pid] = "ctl" if home.endswith(b"/controller") else ("host" if re.search(rb"/h\d+$", home) else None)
            if kind[pid] is None:
                continue
            f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
            last[pid] = int(f[11]) + int(f[12])
        except OSError:
            continue
    host = sum(v for p, v in last.items() if kind.get(p) == "host")
    ctl = sum(v for p, v in last.items() if kind.get(p) == "ctl")
    out.write(f"{time.time_ns() // 1000} {host / tick:.2f} {ctl / tick:.2f}\n")
    time.sleep(0.25)
PY
}

# perf of host h00's daemon for the window, into $1.
perf_h00() {
  local dir=$1 pid="" p
  command -v perf >/dev/null || { echo "ABBA perf: no perf"; return; }
  for _ in $(seq 1 3600); do
    for p in $(pgrep -f -- "/bin/acpmux daemon run" || true); do
      tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qE '^ACPMUX_HOME=.*/h0+$' && { pid=$p; break; }
    done
    [ -n "$pid" ] && break
    sleep 1
  done
  [ -n "$pid" ] || { echo "ABBA perf: no h00"; return; }
  perf record -F 499 --call-graph fp -p "$pid" -o "$dir/perf.data" -- sleep $((WINDOW + 60)) >"$dir/perf.record.log" 2>&1
  [ -s "$dir/perf.data" ] || { echo "ABBA perf: record failed: $(tail -3 "$dir/perf.record.log")"; return; }
  perf report -i "$dir/perf.data" --stdio --no-children --sort sym -g none --percent-limit 0.3 >"$dir/perf.h00.self.txt" 2>/dev/null
  perf report -i "$dir/perf.data" --stdio --children --sort sym -g none --percent-limit 1 >"$dir/perf.h00.children.txt" 2>/dev/null
  perf script -i "$dir/perf.data" -F tid,time,ip,sym 2>/dev/null | gzip >"$dir/perf.h00.stacks.gz"
  rm -f "$dir/perf.data"
}

run() {
  local name=$1 tree=$2 dir=$OUT/$1 samp prof=""
  mkdir -p "$dir"
  echo "ABBA: $name in $tree"
  samp=$(mktemp /tmp/abba-samp.XXXXXX)
  # Its own target dir per tree, kept across that tree's two runs.
  ( cd "$tree" && FANIN_TARGET_DIR=$tree/target-abba FAST_CHECKS_OUT=$dir bash "$ROOT/$HERE/ci.sh" "$RAMP" "$WINDOW" "$HOSTS" "$ROUNDS" ) \
    > "$dir/ci.log" 2>&1 &
  local ci=$!
  sampler "$samp" & local sp=$!
  if [ "${ABBA_PERF:-}" = 1 ] && { [ "$name" = head1 ] || [ "$name" = base1 ]; }; then perf_h00 "$dir" & prof=$!; fi
  wait "$ci"
  kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  [ -n "$prof" ] && wait "$prof"
  cp "$samp" "$dir/host-cpu.txt"; rm -f "$samp"
  grep -E '^FANIN (n=|exit|:)' "$dir/ci.log" | tail -4
}

run base1 "$BASE"
run head1 "$ROOT"
run head2 "$ROOT"
run base2 "$BASE"
git worktree remove --force "$BASE" 2>/dev/null || true

python3 - "$OUT" "$RAMP" "$ROUNDS" <<'PY'
import json, os, statistics as st, sys
out, n, rounds = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rows = {}
for name in ["base1", "head1", "head2", "base2"]:
    d = os.path.join(out, name)
    try:
        t = json.load(open(os.path.join(d, f"n{n}", "table.json"))) if os.path.exists(os.path.join(d, f"n{n}", "table.json")) else \
            next(x for x in json.load(open(os.path.join(d, "fanin-summary.json")))["tables"] if x.get("n") == n)
        ops = [json.loads(l) for l in open(os.path.join(d, f"n{n}", "ops.ndjson"))]
        samples = [tuple(map(float, l.split())) for l in open(os.path.join(d, "host-cpu.txt")) if l.strip()]
    except Exception as e:
        print(f"ABBA {name}: no data ({e})")
        continue
    win_s = t["window_s"]
    # The window starts with its first attach_one; rounds fire at r/(rounds+1) of it.
    starts = [o["t_us"] for o in ops if o.get("op") == "attach_one" and o.get("t_us")]
    w0 = min(starts) / 1e6 if starts else None
    if w0 is None:
        print(f"ABBA {name}: no window start")
        continue
    ts = [s[0] / 1e6 for s in samples]
    host = [s[1] for s in samples]
    def at(x):
        # Host cpu-s at wall time x, interpolated.
        import bisect
        i = bisect.bisect_left(ts, x)
        if i <= 0: return host[0]
        if i >= len(ts): return host[-1]
        a, b = ts[i - 1], ts[i]
        return host[i - 1] + (host[i] - host[i - 1]) * (x - a) / (b - a or 1)
    bursts = [(w0 + win_s * r / (rounds + 1) - 2, w0 + win_s * r / (rounds + 1) + 25) for r in range(1, rounds + 1)]
    # Idle baseline: the window's CPU rate outside the bursts, per 5 s slice, median.
    rates, x = [], w0
    while x + 5 <= w0 + win_s:
        if not any(a < x + 5 and x < b for a, b in bursts):
            rates.append((at(x + 5) - at(x)) / 5)
        x += 5
    base = st.median(rates) if rates else 0.0
    per = [((at(b) - at(a)) - base * (b - a)) * 1000 / n for a, b in bursts]
    f = t["fanout_ms"]; ev = t["events"]
    rows[name] = dict(med=st.median(per), mean=st.mean(per), cpu=at(w0 + win_s) - at(w0),
                      p50=f.get("p50"), p95=f.get("p95"), p99=f.get("p99"),
                      lost=ev.get("lost", 0) + ev.get("fanout_lost", 0), dup=ev.get("dup", 0) + ev.get("fanout_dup", 0),
                      per=per, base=base)
print("| run | host ms/prompt median | mean | host cpu-s (window) | fan-out p50 / p95 / p99 ms | lost / dup |")
print("|---|---|---|---|---|---|")
for name, r in rows.items():
    print(f"| {name} | {r['med']:.2f} | {r['mean']:.2f} | {r['cpu']:.1f} | {r['p50']:.0f} / {r['p95']:.0f} / {r['p99']:.0f} | {r['lost']} / {r['dup']} |")
    print(f"ABBA {name} rounds ms/prompt {[round(p, 2) for p in r['per']]} idle {r['base']:.2f} cpu-s/s", file=sys.stderr)
def avg(names, k):
    v = [rows[x][k] for x in names if x in rows]
    return sum(v) / len(v) if v else float("nan")
B, H = ["base1", "base2"], ["head1", "head2"]
for label, names in [("base avg", B), ("head avg", H)]:
    med, mean, cpu = avg(names, "med"), avg(names, "mean"), avg(names, "cpu")
    pct = lambda h, b: f" ({(h / b - 1) * 100:+.1f}%)" if label == "head avg" and b else ""
    print(f"| **{label}** | **{med:.2f}{pct(med, avg(B, 'med'))}** | **{mean:.2f}{pct(mean, avg(B, 'mean'))}** | "
          f"**{cpu:.1f}{pct(cpu, avg(B, 'cpu'))}** | {avg(names, 'p50'):.0f} / {avg(names, 'p95'):.0f} / {avg(names, 'p99'):.0f} | "
          f"{sum(rows[x]['lost'] for x in names if x in rows)} |")
PY
echo "ABBA exit 0"
