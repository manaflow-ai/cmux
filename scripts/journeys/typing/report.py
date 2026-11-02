#!/usr/bin/env python3
"""TYPING UNDER LOAD report of one run folder: the per-profile table and every stall over 1 refresh with its owner.

    report.py RUN_DIR --journey typing-load-l0 [--markdown]

Reads OUT/<journey>/: result.json (typist_play events with t_post), echo.jsonl (keys_check), probe.csv (in-app per-key
marks, ms after the key's NSEvent time; event_uptime_ns when the build has it), probe-before/after.json (debug.hangs:
main-thread turns over 4 ms with their stacks; debug.wakeups: CPU per process), video/*.keys.json when the ledger
judged the movies. A stall is named by the key whose post time is closest before it (CLOCK_UPTIME_RAW) and by its
first cmux frame and its deepest system frame.
"""
import argparse
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


def pct(xs, p):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(math.ceil(p / 100.0 * len(xs))) - 1)], 2) if xs else None


def owner(frames):
    app = next((f for f in frames if f.startswith("cmux ")), None)
    sysf = next((f for f in frames if not f.startswith("cmux ")), None)
    # The AppKit or CoreUI frame closest to the app (what cmux asked the system for)
    mid = None
    for f in frames:
        if f.startswith("cmux "):
            break
        if f.split(" ", 1)[0] in ("AppKit", "CoreUI", "QuartzCore", "Foundation", "CoreFoundation"):
            mid = f
    return {"app": (app or "")[:160], "system": (sysf or "")[:120], "via": (mid or "")[:160]}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("run"); ap.add_argument("--journey", required=True); ap.add_argument("--markdown", action="store_true")
    a = ap.parse_args()
    j = Path(a.run) / a.journey
    res = json.loads((j / "result.json").read_text())
    events = [e for s in res["steps"] if s.get("do") == "typist_play" and s.get("result") for e in s["result"]["events"]]
    out = {"keys": len(events)}
    if (j / "echo.jsonl").is_file():
        import keys_check
        reads = [json.loads(l) for l in (j / "echo.jsonl").read_text().splitlines() if '"bytes"' in l]
        k = keys_check.check(events, reads)
        out["order"] = {"order_ok": k["order_ok"], "lost": len(k["lost"]), "merged": len(k["merged"]), "pty_ms": k["pty_ms"]}
    if (j / "probe.csv").is_file():
        lines = (j / "probe.csv").read_text().splitlines()
        head = lines[0].split(",")
        rows = [dict(zip(head, l.split(","))) for l in lines[1:]]
        done = [r for r in rows if r.get("complete") == "1" and r.get("contents_ms")]
        out["probe"] = {c: {"p50": pct([float(r[c]) for r in done if r.get(c)], 50),
                            "p95": pct([float(r[c]) for r in done if r.get(c)], 95),
                            "p99": pct([float(r[c]) for r in done if r.get(c)], 99),
                            "max": pct([float(r[c]) for r in done if r.get(c)], 100)}
                        for c in ("dispatch_start_ms", "io_write_ms", "output_decoded_ms", "contents_ms")}
        out["probe"]["rows"] = len(rows)
    stalls = []
    try:
        before = json.loads((j / "probe-before.json").read_text())["debug.hangs"]["records"]
        after = json.loads((j / "probe-after.json").read_text())["debug.hangs"]["records"]
        seen = {r.get("sequence") for r in before}
        posts = sorted(e["t_post"] for e in events)
        by_post = {e["t_post"]: e for e in events}
        for r in after:
            if r.get("sequence") in seen:
                continue
            t = r.get("start_uptime_ns", 0) / 1e9
            prior = [p for p in posts if p <= t + 0.001]
            key = by_post[prior[-1]] if prior else None
            stalls.append({"ms": round(r.get("duration_ms", 0), 1), "cpu_ms": round(r.get("cpu_ms") or 0, 1),
                           "t": round(t, 3), "after_key": key and {"i": key["i"], "kind": key["kind"],
                                                                     "since_ms": round((t - key["t_post"]) * 1000, 1)},
                           **owner(r.get("frames") or [])})
    except (OSError, KeyError, ValueError):
        pass
    stalls.sort(key=lambda s: -s["ms"])
    out["stalls_over_8ms"] = [s for s in stalls if s["ms"] > 8.33]
    out["stalls_4_to_8ms"] = sum(1 for s in stalls if s["ms"] <= 8.33)
    video = []
    for kj in sorted((j / "video").glob("*.keys.json")) if (j / "video").is_dir() else []:
        rep = json.loads(kj.read_text())
        video.append({"part": kj.name, **rep["summary"]})
    out["video"] = video
    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
