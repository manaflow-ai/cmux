#!/usr/bin/env python3
"""Terminal memory and throughput bench for cmux-tui (terminal-perf-100x).

One isolated headless daemon (the bench-scale.py harness), then:

1. idle: physical footprint and threads per role (daemon, terminal host)
   at each of --counts idle terminals;
2. scrollback: --fill-terminals terminals each print --fill-lines lines of
   --line-bytes bytes and stay open; the footprint growth per role divided
   by the line count gives the cost of 10,000 lines in each copy;
3. throughput: one terminal `cat`s a --cat-mb MB file of mixed text; the
   time until the child exits is bounded by how fast the host (and the
   daemon mirror, when it applies backpressure) parses the output;
4. busy: --busy-terminals terminals print --busy-rate lines/s; CPU % per
   role over --busy-seconds (no client attached: every terminal is hidden).

Prints TERMINAL-PERF lines and writes --out JSON. Memory figures are
macOS phys_footprint (proc_pid_rusage) or Linux PSS, as bench-scale.py reads.

  bench-terminal-perf.py --bin target/release/cmux-tui --out perf.json
"""

import argparse
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bench_scale", os.path.join(HERE, "bench-scale.py"))
bs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bs)

MB = 1048576.0


def role_totals(bench, detail=True):
    snap = bench.snapshot(detail)
    out = {}
    for role, rows in snap.items():
        t = bench.totals(rows)
        out[role] = {
            "count": t.get("count"),
            "footprint_mb": round((t.get("pss") or 0) / MB, 2),
            "footprint_each_mb": round((t.get("pss_per") or 0) / MB, 3),
            "rss_mb": round((t.get("rss") or 0) / MB, 2),
            "threads": t.get("threads"),
            "cpu_s": t.get("cpu_s"),
        }
    return out


def emit(kind, **fields):
    print("TERMINAL-PERF " + kind + " " + " ".join(f"{k}={v}" for k, v in fields.items()), flush=True)


def wait_hosts(bench, want, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if len(bench.tree()["hosts"]) >= want:
            return True
        time.sleep(0.2)
    return False


def create(bench, argvs):
    """Create one terminal per argv in the bench's first workspace."""
    c = bs.Conn(bench.sock_path, timeout=120)
    surfaces = []
    for argv in argvs:
        data = bs.must(c.call("create-terminal", workspace=bench.workspaces[0], argv=argv, cols=80, rows=24), "create-terminal")
        surfaces.append(data.get("surface"))
    c.close()
    bench.terminals.extend({"surface": s, "busy": False} for s in surfaces)
    return surfaces


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bin", required=True)
    p.add_argument("--counts", default="1,10,100")
    p.add_argument("--fill-terminals", type=int, default=10)
    p.add_argument("--fill-lines", type=int, default=10000)
    p.add_argument("--line-bytes", type=int, default=80)
    p.add_argument("--cat-mb", type=int, default=64)
    p.add_argument("--busy-terminals", type=int, default=10)
    p.add_argument("--busy-rate", type=float, default=200.0)
    p.add_argument("--busy-seconds", type=float, default=10.0)
    p.add_argument("--settle", type=float, default=3.0)
    p.add_argument("--out")
    a = p.parse_args()

    root = tempfile.mkdtemp(prefix="tperf.", dir="/private/tmp" if sys.platform == "darwin" else None)
    args = argparse.Namespace(
        bin=a.bin, mode="durable", shell=["/bin/sh", "-c", "exec sleep 1000000"], busy_fraction=0.0, busy_rate=a.busy_rate,
        busy_line_bytes=a.line_bytes, per_workspace=1000000, fill="sequential", create_concurrency=4,
        settle_seconds=a.settle, settle_seconds_min=a.settle, idle_seconds=5, latency_terminals=1, latency_samples=1,
        topology_samples=1, out=None, root_dir=root, keep_root=False, counts=a.counts,
    )
    bench = bs.Bench(args)
    result = {"bin": a.bin, "args": vars(a), "idle": [], "scrollback": None, "throughput": None, "busy": None}
    status = 0
    try:
        bench.start()
        bench.setup_workspaces(1)
        base_terms = len(bench.tree()["hosts"])
        # 1. idle
        for n in [int(x) for x in a.counts.split(",") if x]:
            have = len(bench.tree()["hosts"])
            if n > have:
                create(bench, [args.shell] * (n - have))
                wait_hosts(bench, n)
            time.sleep(a.settle)
            roles = role_totals(bench)
            result["idle"].append({"terminals": n, "roles": roles})
            d, h = roles.get("daemon", {}), roles.get("hosts", {})
            emit("idle", terminals=n, daemon_mb=d.get("footprint_mb"), daemon_threads=d.get("threads"),
                 host_each_mb=h.get("footprint_each_mb"), hosts_mb=h.get("footprint_mb"), host_threads=h.get("threads"),
                 total_mb=round((d.get("footprint_mb") or 0) + (h.get("footprint_mb") or 0), 2))
        # 2. scrollback fill
        before = role_totals(bench)
        n_before = len(bench.tree()["hosts"])
        line = "y" * max(1, a.line_bytes - 12)
        fill = ["perl", "-e", f'$|=0; for my $i (1..{a.fill_lines}) {{ printf "%10d {line}\\n", $i; }} sleep 1000000']
        create(bench, [fill] * a.fill_terminals)
        wait_hosts(bench, n_before + a.fill_terminals)
        time.sleep(max(a.settle, 5))
        after = role_totals(bench)
        per = {}
        for role in ("daemon", "hosts"):
            grown = (after[role]["footprint_mb"] - before[role]["footprint_mb"]) / a.fill_terminals
            per[role] = round(grown * 10000 / a.fill_lines, 3)
        result["scrollback"] = {"before": before, "after": after, "mb_per_10k_lines": per}
        emit("scrollback", lines=a.fill_lines, line_bytes=a.line_bytes, terminals=a.fill_terminals,
             daemon_mb_per_10k_lines=per["daemon"], host_mb_per_10k_lines=per["hosts"],
             raw_mb_per_10k_lines=round(10000 * a.line_bytes / MB, 3))
        # 3. throughput
        blob = os.path.join(root, "cat.txt")
        with open(blob, "w") as f:
            chunk = "".join(f"{i:08d} the quick brown fox \x1b[1;3{i % 8}mjumps\x1b[0m over the lazy dog {'z' * (i % 40)}\n" for i in range(4096))
            want = a.cat_mb * 1024 * 1024
            written = 0
            while written < want:
                f.write(chunk)
                written += len(chunk)
        n_before = len(bench.tree()["hosts"])
        t0 = time.perf_counter()
        create(bench, [["/bin/sh", "-c", f"cat '{blob}'"]])
        hosts_seen = wait_hosts(bench, n_before + 1, timeout=30)
        deadline = time.time() + 600
        while time.time() < deadline and len(bench.tree()["hosts"]) > n_before:
            time.sleep(0.05)
        secs = time.perf_counter() - t0
        result["throughput"] = {"mb": a.cat_mb, "seconds": round(secs, 3), "mb_per_s": round(a.cat_mb / secs, 1), "host_seen": hosts_seen}
        emit("throughput", mb=a.cat_mb, seconds=round(secs, 3), mb_per_s=round(a.cat_mb / secs, 1))
        # 4. busy hidden terminals
        busy = ["perl", "-e", f'$|=1; my $n=0; while (1) {{ print "busy ", $n++, " {line}\\n"; select(undef,undef,undef,{1.0 / a.busy_rate:.4f}); }}']
        n_before = len(bench.tree()["hosts"])
        create(bench, [busy] * a.busy_terminals)
        wait_hosts(bench, n_before + a.busy_terminals)
        time.sleep(2)
        s0, t0 = role_totals(bench, detail=False), time.time()
        time.sleep(a.busy_seconds)
        s1, t1 = role_totals(bench, detail=False), time.time()
        cpu = {r: round(100.0 * ((s1[r].get("cpu_s") or 0) - (s0[r].get("cpu_s") or 0)) / (t1 - t0), 2) for r in ("daemon", "hosts")}
        result["busy"] = {"terminals": a.busy_terminals, "rate": a.busy_rate, "cpu_pct": cpu}
        emit("busy", terminals=a.busy_terminals, lines_per_s_each=a.busy_rate, daemon_cpu_pct=cpu["daemon"], hosts_cpu_pct=cpu["hosts"],
             daemon_cpu_pct_per_terminal=round(cpu["daemon"] / a.busy_terminals, 3))
    except Exception as e:  # noqa: BLE001
        result["error"] = repr(e)
        print("TERMINAL-PERF error", repr(e), bench.tail_log()[-1500:] if bench.daemon else "", flush=True)
        status = 1
    finally:
        bench.stop()
        if a.out:
            with open(a.out, "w") as f:
                json.dump(result, f, indent=1)
        shutil.rmtree(root, ignore_errors=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
