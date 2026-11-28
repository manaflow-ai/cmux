#!/usr/bin/env python3
"""A fan-out round's timeline from one ramp's raw events, and what the profiled daemon did in it.

usage: timeline.py EVENTS_NDJSON[.gz] [--hosts N] [--stacks perf.stacks.gz] [--offcpu offcpu.stacks.gz]
                   [--top K] [--json OUT]

`coord-sim fanin` sends one `session/prompt` to all N sessions at once in each round (ramp.rs) and
writes each one to events.ndjson as {"src": "turn", "seq": ROUND, "c": SESSION, "emit_us": SENT,
"reader_us": AGENT_GOT}. Per round this prints:
- the send span (driver: first to last prompt sent) and the receive spread (first, p50, last
  agent receipt, from the round's first send);
- each host's last receipt (session c is on host (c-1) % HOSTS), which tells a drain shared by
  every host (all hosts end together) from one slow host;
- the drain per prompt, (last - first receipt) / N: the `d` in the goal doc's ceiling (goals/
  sessions-2000-attached.md, `## Ceiling`, p95 ~= L0 + 0.95*N*d).

With --stacks/--offcpu (ci.sh `perf`, which profiles FANIN_PERF_ROLE: the controller by default,
`h00` a host), it folds the samples inside each round's window (first send to last receipt) by
their two innermost acpmux frames: the CPU the profiled daemon spent and what it waited on while
the round drained. CPU samples are also given as busy CPUs (samples * period / window), so a round
that drains on ~2 of 8 CPUs reads as a serial chain, not a saturated box.

Its first reading (cmux run 46093984625, controller, n=2000, 8 CPUs): sends 50-106 ms, receipts
spread 1.25-1.34 s, every host ends within 30 ms of the others, controller ~1.8 busy CPUs during
the drain. Python only reads the files it is given (run it with `python3 -I`).
"""
import argparse
import collections
import gzip
import json
import re
import sys

HEAD = re.compile(r"^\s*(\d+)\s+([\d.]+):\s*$")
SKIP = ("tokio::", "<tokio", "core::", "<core", "futures_util", "<futures", "std::sys", "alloc::",
        "<alloc", "[unknown]", "tracing::", "<tracing")


def opener(path):
    return gzip.open(path, "rt", errors="replace") if path.endswith(".gz") else open(path, errors="replace")


def rounds_of(path):
    rounds = collections.defaultdict(list)
    with opener(path) as f:
        for line in f:
            d = json.loads(line)
            if d.get("src") == "turn":
                rounds[d["seq"]].append((d["emit_us"], d.get("reader_us"), d["c"]))
    return rounds


def pct(xs, q):
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else None


def summarize(rounds, hosts):
    out = []
    for r, rows in sorted(rounds.items()):
        rows.sort()
        t0 = rows[0][0]
        got = sorted((rx - t0) / 1000 for _, rx, _ in rows if rx)
        last_by_host = collections.defaultdict(float)
        for _, rx, c in rows:
            if rx:
                h = (c - 1) % hosts
                last_by_host[h] = max(last_by_host[h], (rx - t0) / 1000)
        n = len(rows)
        out.append({
            "round": r, "n": n, "lost": n - len(got),
            "send_span_ms": round((rows[-1][0] - t0) / 1000, 3),
            "recv_first_ms": round(got[0], 3) if got else None,
            "recv_p50_ms": round(pct(got, 0.5), 3) if got else None,
            "recv_p95_ms": round(pct(got, 0.95), 3) if got else None,
            "recv_last_ms": round(got[-1], 3) if got else None,
            "drain_ms_per_prompt": round((got[-1] - got[0]) / max(1, len(got) - 1), 4) if got else None,
            "host_last_ms": [round(last_by_host[h]) for h in sorted(last_by_host)],
            # The window in the profile's clock is found from the stacks (below); in wall us here.
            "window_us": [t0, max((rx for _, rx, _ in rows if rx), default=t0)],
        })
    return out


def align(ts, windows, step=0.02):
    """Seconds to add to an events time (us / 1e6) to get perf time: the shift, in `step` steps,
    whose round windows hold the most samples. Rounds are the busiest stretches of a ramp."""
    import bisect
    w = [(lo / 1e6, hi / 1e6) for lo, hi in windows]
    first = w[0][0]
    rel = [(lo - first, hi - first) for lo, hi in w]
    best, best_n = ts[0] - first, -1
    k = 0
    while True:
        start = ts[0] + k * step
        if start + rel[-1][1] > ts[-1] + step:
            break
        n = sum(bisect.bisect_right(ts, start + hi) - bisect.bisect_left(ts, start + lo) for lo, hi in rel)
        if n > best_n:
            best, best_n = start - first, n
        k += 1
    return best


def fold(path, windows, top):
    """Samples per window, keyed by the two innermost acpmux frames, plus the window's sample count.

    perf's clock is not the events' clock, but the gaps between rounds are the same on both: the
    windows are placed by the one shift that puts the most samples inside them (align), then
    widened by 10% on each side."""
    samples = []
    stack = []
    t = None
    with opener(path) as f:
        for line in f:
            m = HEAD.match(line)
            if m:
                if t is not None:
                    samples.append((t, stack))
                t, stack = float(m.group(2)), []
                continue
            s = line.strip()
            if s and " " in s:
                stack.append(s.split(" ", 1)[1])
    if t is not None:
        samples.append((t, stack))
    if not samples:
        return []
    samples.sort(key=lambda x: x[0])
    ts = [x[0] for x in samples]
    shift = align(ts, windows)
    out = []
    for lo_us, hi_us in windows:
        lo, hi = lo_us / 1e6 + shift, hi_us / 1e6 + shift
        pad = (hi - lo) * 0.1
        c = collections.Counter()
        n = 0
        for tt, st in samples:
            if lo - pad <= tt <= hi + pad:
                n += 1
                frames = [x for x in st if "acpmux" in x and not x.startswith(SKIP)]
                c[" <- ".join(x[:100] for x in frames[:2]) or (st[0][:100] if st else "")] += 1
        out.append({"samples": n, "seconds": round(hi - lo + 2 * pad, 3),
                    "top": [[v, k] for k, v in c.most_common(top)]})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("events")
    ap.add_argument("--hosts", type=int, default=10)
    ap.add_argument("--stacks")
    ap.add_argument("--offcpu")
    ap.add_argument("--period-ms", type=float, default=None,
                    help="CPU sample period in ms; when given, CPU windows also print busy CPUs")
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--json")
    a = ap.parse_args()
    rounds = summarize(rounds_of(a.events), a.hosts)
    if not rounds:
        print("timeline: no fan-out rounds (src=turn) in", a.events)
        return 1
    windows = [tuple(r["window_us"]) for r in rounds]
    report = {"schema": "fanin-timeline.v1", "rounds": rounds}
    for r in rounds:
        print(f"round {r['round']}: n {r['n']} lost {r['lost']} sent over {r['send_span_ms']} ms; "
              f"receipts first {r['recv_first_ms']} p50 {r['recv_p50_ms']} p95 {r['recv_p95_ms']} "
              f"last {r['recv_last_ms']} ms; drain {r['drain_ms_per_prompt']} ms/prompt")
        print(f"  each host's last receipt (ms): {r['host_last_ms']}")
    for name, path in (("cpu", a.stacks), ("offcpu", a.offcpu)):
        if not path:
            continue
        folded = fold(path, windows, a.top)
        report[name] = folded
        for r, w in zip(rounds, folded):
            busy = ""
            if name == "cpu" and a.period_ms:
                busy = f", {w['samples'] * a.period_ms / 1000 / max(1e-6, w['seconds']):.2f} busy CPUs"
            print(f"{name} round {r['round']}: {w['samples']} samples over {w['seconds']} s{busy}")
            for v, k in w["top"]:
                print(f"  {v:7d} {k}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(report, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
