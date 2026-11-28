"""abba.sh's helpers. `sample OUT`: every second, each fan-in host daemon's CPU ticks (a daemon
whose ACPMUX_HOME ends in /nN/hI), one JSON line each. `table DIR`: the ABBA table from DIR's
base1, head1, head2, base2 runs (ci.sh's files and the samples)."""
import gzip
import json
import os
import re
import statistics
import sys
import time

HOST_HOME = re.compile(rb"ACPMUX_HOME=[^\0]*/n\d+/h\d+\0")


def host_ticks():
    out = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/environ", "rb") as f:
                if not HOST_HOME.search(f.read() + b"\0"):
                    continue
            with open(f"/proc/{pid}/stat") as f:
                fields = f.read().rsplit(")", 1)[1].split()
            # utime and stime: fields 14 and 15, the 12th and 13th after the command name.
            out[pid] = int(fields[11]) + int(fields[12])
        except (OSError, IndexError, ValueError):
            continue
    return out


def sample(path):
    with open(path, "w") as f:
        f.write(json.dumps({"tck": os.sysconf("SC_CLK_TCK")}) + "\n")
        while True:
            t = time.time_ns() // 1000
            f.write(json.dumps({"t_us": t, "ticks": host_ticks()}) + "\n")
            f.flush()
            time.sleep(1.0)


def intervals(path):
    """[(t0_us, t1_us, ticks)]: the hosts' ticks between two samples (daemons in both)."""
    tck, prev, out = 100, None, []
    with open(path) as f:
        for line in f:
            d = json.loads(line)
            if "tck" in d:
                tck = d["tck"]
                continue
            if prev:
                ticks = sum(v - prev["ticks"][p] for p, v in d["ticks"].items() if p in prev["ticks"])
                out.append((prev["t_us"], d["t_us"], max(ticks, 0)))
            prev = d
    return tck, out


def cpu_between(iv, a, b):
    total = 0.0
    for t0, t1, ticks in iv:
        lo, hi = max(a, t0), min(b, t1)
        if hi > lo and t1 > t0:
            total += ticks * (hi - lo) / (t1 - t0)
    return total


def largest(run):
    ns = [d for d in os.listdir(run) if re.fullmatch(r"n\d+", d)]
    return max(ns, key=lambda d: int(d[1:])) if ns else None


def bursts(ndir):
    """{round: (start_us, end_us, prompts)} from the fan-out's sends, sights and replies."""
    rounds = {}
    with gzip.open(os.path.join(ndir, "events.ndjson.gz"), "rt") as f:
        for line in f:
            e = json.loads(line)
            if e.get("src") != "turn":
                continue
            r = rounds.setdefault(e["seq"], [None, 0, 0])
            r[0] = e["emit_us"] if r[0] is None else min(r[0], e["emit_us"])
            r[1] = max(r[1], e.get("reader_us") or 0)
            r[2] += 1
    longest = {}
    with open(os.path.join(ndir, "ops.ndjson")) as f:
        for line in f:
            o = json.loads(line)
            if o.get("op") == "prompt" and "round" in o:
                longest[o["round"]] = max(longest.get(o["round"], 0), o.get("latency_us") or 0)
    return {k: (s, max(e, s + longest.get(k, 0)), n) for k, (s, e, n) in rounds.items()}


def run_row(run):
    nd = largest(run)
    if nd is None:
        return None
    ndir = os.path.join(run, nd)
    tck, iv = intervals(os.path.join(run, "hostcpu.ndjson"))
    per = []
    for _, (s, e, n) in sorted(bursts(ndir).items()):
        a, b = s - 1_000_000, e + 2_000_000
        idle = cpu_between(iv, s - 11_000_000, s - 1_000_000) / 10.0  # ticks a second
        extra = cpu_between(iv, a, b) - idle * (b - a) / 1e6
        per.append(extra / tck * 1000.0 / max(n, 1))
    table = next((t for t in json.load(open(os.path.join(run, "fanin-summary.json")))["tables"]
                  if f"n{t.get('n')}" == nd), {})
    fo, ev = table.get("fanout_ms", {}), table.get("events", {})
    return {
        "per": per,
        "median": statistics.median(per) if per else float("nan"),
        "mean": statistics.fmean(per) if per else float("nan"),
        "cpu_s": table.get("controller", {}).get("hosts_cpu_s_life"),
        "fanout": (fo.get("p50"), fo.get("p95"), fo.get("p99")),
        "lost_dup": (ev.get("lost", 0) + ev.get("fanout_lost", 0), ev.get("dup", 0) + ev.get("fanout_dup", 0)),
    }


def fmt(x, d=2):
    return "-" if x is None else f"{x:.{d}f}"


def table(out):
    rows = {r: run_row(os.path.join(out, r)) for r in ("base1", "head1", "head2", "base2")}
    print("| run | host ms/prompt median | mean | host cpu-s (run) | fan-out p50/p95/p99 ms | lost/dup |")
    print("|---|---|---|---|---|---|")
    for name, r in rows.items():
        if r is None:
            print(f"| {name} | missing | | | | |")
            continue
        fo = "/".join(fmt(x, 0) for x in r["fanout"])
        print(f"| {name} | {fmt(r['median'], 3)} | {fmt(r['mean'], 3)} | {fmt(r['cpu_s'], 1)} | {fo} | "
              f"{r['lost_dup'][0]}/{r['lost_dup'][1]} |")
    for side in ("base", "head"):
        rs = [rows[f"{side}1"], rows[f"{side}2"]]
        if None in rs:
            continue
        avg = lambda k: statistics.fmean(r[k] for r in rs)
        cpu = [r["cpu_s"] for r in rs if r["cpu_s"] is not None]
        print(f"| {side} avg | {fmt(avg('median'), 3)} | {fmt(avg('mean'), 3)} | "
              f"{fmt(statistics.fmean(cpu) if cpu else None, 1)} | | |")
    for name, r in rows.items():
        if r:
            print(f"\n{name} per round ms/prompt: " + ", ".join(fmt(x, 3) for x in r["per"]))


if __name__ == "__main__":
    {"sample": sample, "table": table}[sys.argv[1]](sys.argv[2])
