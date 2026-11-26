#!/usr/bin/env python3
"""Replay the newest N heads merged into a branch, in order, through one warm verdict worker; report the wall p50/p90.

    scripts/measure/warm-verdict-replay.py --source REPO --tip SHA [--count 20] [--state DIR] [--out report.json]

One harness for before and after: it drives scripts/ci/warm-verdict-worker.py's own code (the same Worker class
`serve` runs) on this machine. SOURCE is a git repository holding TIP (a local mirror is fine: the worker clones it
once, --shared). The heads are TIP's first-parent history (each a squash-merged pull request, diffed against its
parent, as its PR diffed against the base it merged into).

  1. route pass: check out every head and route it (no build) to learn which crates, Cargo workspaces and web
     packages the window touches;
  2. warm: at the oldest head's parent, build what step 1 found (`cargo check -p`, the touched crates' unit-test
     builds, `bun install`, tsc) and run its Python tests once (the worker learns each file's seconds), timed
     apart: the state a resident worker holds after earlier traffic;
  3. replay: each head in order, one verdict each, every phase timed.

The report gives p50/p90 of wall time per head, per phase and per lane, how many heads came in under --target
seconds, the Swift-touching heads apart (they need the Mac job), and the worker's disk use.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("warm_verdict_worker", REPO / "scripts/ci/warm-verdict-worker.py")
wv = importlib.util.module_from_spec(spec)
sys.modules["warm_verdict_worker"] = wv
spec.loader.exec_module(wv)


def pct(values: list[float], q: float) -> float:
    """Nearest-rank percentile (q in 0..100) of VALUES; 0.0 for none."""
    if not values:
        return 0.0
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(q / 100 * len(s) + 0.5)) - 1))
    return round(s[k], 2)


def stats(rows: list[dict], key: str) -> dict:
    vals = [r[key] for r in rows]
    return {"n": len(vals), "p50": pct(vals, 50), "p90": pct(vals, 90),
            "mean": round(statistics.fmean(vals), 2) if vals else 0.0, "max": round(max(vals, default=0.0), 2)}


def phase_stats(rows: list[dict], field: str) -> dict:
    names = sorted({k for r in rows for k in r[field]})
    return {k: {"p50": pct([r[field].get(k, 0.0) for r in rows], 50),
                "p90": pct([r[field].get(k, 0.0) for r in rows], 90)} for k in names}


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--source", required=True)
    ap.add_argument("--tip", required=True)
    ap.add_argument("--count", type=int, default=20)
    ap.add_argument("--state", type=Path, default=Path.home() / ".cache/warm-verdict-worker")
    ap.add_argument("--out", type=Path, default=Path("warm-verdict-replay.json"))
    ap.add_argument("--target", type=float, default=0.64 * 60, help="seconds a verdict should come in under")
    ap.add_argument("--jobs", type=int)
    a = ap.parse_args(argv)

    w = wv.Worker(a.state, a.source, a.jobs)
    w.ensure_tree()
    w.fetch(a.tip)
    heads = wv.git(w.tree, "log", "--first-parent", "--format=%H", f"-{a.count}", a.tip).split()[::-1]
    report: dict = {"tip": a.tip, "heads": heads, "host": subprocess.run(["hostname"], capture_output=True,
                    text=True).stdout.strip(), "nproc": subprocess.run(["nproc"], capture_output=True,
                    text=True).stdout.strip(), "target_s": a.target}

    t = time.monotonic()
    crates, direct, other_ws, python = set(), set(), set(), set()
    for h in heads:
        w.checkout(h)
        r = w.route(wv.git(w.tree, "rev-parse", f"{h}^"), h)
        crates |= set(r["crates"])
        direct |= set(r["direct"])
        other_ws |= set(r["other_ws"])
        python |= set(r["python"])
    report["route_pass_s"] = round(time.monotonic() - t, 2)
    base = wv.git(w.tree, "rev-parse", f"{heads[0]}^")
    print(f"warm at {base[:12]}: {len(crates)} crates, {len(direct)} tested, other workspaces {sorted(other_ws)}",
          flush=True)
    report["warm"] = w.warm(base, sorted(crates), sorted(direct), sorted(other_ws), sorted(python))
    print("warm:", json.dumps({k: report["warm"][k] for k in ("wall_s", "steps")}), flush=True)

    rows = []
    for i, h in enumerate(heads, 1):
        v = w.verdict(h)
        v["subject"] = wv.git(w.tree, "log", "-1", "--format=%s", h)[:90]
        rows.append(v)
        print(f"[{i:2}/{len(heads)}] {h[:12]} {v['verdict']:10} {v['wall_s']:7.2f}s "
              f"{json.dumps(v['phases'])} swift={len(v['swift_needs'])} {v['subject'][:60]}", flush=True)
    linux = [r for r in rows if not r["swift_needs"]]
    swift = [r for r in rows if r["swift_needs"]]
    report.update({
        "rows": rows,
        "wall": stats(rows, "wall_s"),
        "wall_linux_only": stats(linux, "wall_s"),
        "wall_swift_heads_linux_part": stats(swift, "wall_s"),
        "phases": phase_stats(rows, "phases"),
        "lanes": phase_stats(rows, "lanes"),
        "under_target": sum(1 for r in rows if r["wall_s"] < a.target),
        "verdicts": {k: sum(1 for r in rows if r["verdict"] == k) for k in ("pass", "pass-linux", "fail")},
        "swift_heads": [{"head": r["head"][:12], "needs": r["swift_needs"][:6]} for r in swift],
        "disk": w.disk(),
    })
    a.out.write_text(json.dumps(report, indent=1))
    print("summary:", json.dumps({k: report[k] for k in ("wall", "wall_linux_only", "phases", "lanes",
                                                           "under_target", "verdicts", "disk")}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
