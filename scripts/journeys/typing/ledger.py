#!/usr/bin/env python3
"""Judges one TYPING UNDER LOAD run and appends its row to the gate's ledger (smoke-gate.py typing_blockers).

    ledger.py --run RUN_DIR --journey typing-load-l6 [--ledger DIR] [--dry-run]

The row: profile, build_job, commit, kit, kit_dirty, smoke_env (env_windows), refresh_ms (the movies' meta), source
("video" when both movies were judged by judge_keys.py, else "in-app"), p50/p95/p99/max refreshes over both parts,
lost, merged and order_ok (keys_check.py on echo.jsonl), the in-app probe's contents_ms p50/p95/max, the stalls over 2
refreshes, out. A run with no typist_play result writes nothing (exit 75).
"""
import argparse
import json
import os
import math
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
LEDGER = Path("/Users/lawrence/fun/wt/handoff/typing-load-results")


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(math.ceil(p / 100.0 * len(xs))) - 1)] if xs else None


def probe_contents(path):
    """contents_ms of the probe's complete rows (the echo's layer contents after the key's NSEvent time)."""
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return None
    head = lines[0].split(",") if lines else []
    if "contents_ms" not in head:
        return None
    k, c = head.index("contents_ms"), head.index("complete")
    vals = [float(r.split(",")[k]) for r in lines[1:] if r.split(",")[c] == "1" and r.split(",")[k]]
    return {"n": len(vals), "p50": pct(vals, 50), "p95": pct(vals, 95), "max": max(vals) if vals else None,
            "rows": len(lines) - 1}


def probe_starts(path):
    """The key-down times (s, CLOCK_UPTIME_RAW) of the in-app probe's rows (`event_uptime_ns`), in order."""
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return []
    head = lines[0].split(",") if lines else []
    if "event_uptime_ns" not in head:
        return []
    k = head.index("event_uptime_ns")
    return [int(r.split(",")[k]) / 1e9 for r in lines[1:] if len(r.split(",")) > k and r.split(",")[k]]


def hog_held_gb(run, t0, t1):
    """The LEAST the hog held during the typing window (its log's t_mono, the clock of the key posts); 0 when its log
    has no sample in the window (review should-fix 4 at 71bef9a1695)."""
    rows = []
    for h in Path(run).glob("hog-*.jsonl"):
        for l in h.read_text(errors="replace").splitlines():
            try:
                rows.append(json.loads(l))
            except ValueError:
                pass
    held = [float(r.get("held_mb") or 0) for r in rows if isinstance(r, dict)
            and isinstance(r.get("t_mono", r.get("t")), (int, float)) and t0 <= float(r.get("t_mono", r.get("t"))) <= t1]
    return round(min(held) / 1024, 2) if held else 0.0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--run", required=True); ap.add_argument("--journey", required=True)
    ap.add_argument("--ledger", default=str(LEDGER)); ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    run = Path(a.run)
    jdir = run / a.journey
    res = json.loads((jdir / "result.json").read_text())
    row0 = next((json.loads(l) for l in (run / "results.jsonl").read_text().splitlines() if json.loads(l).get("id") == a.journey), {})
    plays = [s for s in res.get("steps", []) if s.get("do") == "typist_play" and s.get("result")]
    if not plays:
        print("no typist_play result: no row")
        return 75
    envs = [s.get("result") for s in res.get("steps", []) if s.get("do") == "env_windows" and isinstance(s.get("result"), dict)]
    smoke = not envs or any(e.get("smoke_env") for e in envs)
    events = [e for p in plays for e in p["result"]["events"]]
    # The keys each part was planned to play (its own seed, length and window), checked against the plan itself.
    import typist
    planned = 0
    for p in plays:
        st = next(x for x in res["steps"] if x is p)
        args = {k: st.get(k) for k in ("seed", "seconds", "from", "to")}
        want = [e for e in typist.plan(int(args["seed"] or 7), float(args["seconds"] or 120),
                                       columns=int(p["result"].get("columns") or 80))
                if float(args["from"] or 0) <= e["t"] < float(args["to"] if args["to"] is not None else 1e9)]
        if p["result"].get("planned") != len(want):
            planned = None
            break
        planned += len(want)
    # Start of each key: the key's own NSEvent time from the in-app probe (event_uptime_ns, CLOCK_UPTIME_RAW ns, the
    # clock of time.monotonic and of the recorder's frames), else t_post (before the CuaDriver call: an UPPER bound
    # of the latency; the gate counts such a row only when it passes: review should-fix 5 at 8802cbd6e87).
    starts = probe_starts(jdir / "probe.csv")
    start_clock = "nsevent" if starts else "t_post"
    for e in events:
        hit = [t for t in starts if e["t_post"] - 0.002 <= t <= e["t_back"] + 0.002]
        if hit:
            e["t_start"] = hit[0]
    if starts and sum(1 for e in events if "t_start" in e) < 0.95 * len(events):
        start_clock = "t_post"  # the probe missed keys: do not mix clocks
        for e in events:
            e.pop("t_start", None)
    keys = {}
    if (jdir / "echo.jsonl").is_file():
        import keys_check
        reads = [json.loads(l) for l in (jdir / "echo.jsonl").read_text().splitlines() if '"bytes"' in l]
        keys = keys_check.check(events, reads)
    refreshes, stalls, refresh_ms, judged, missing = [], [], None, 0, 0
    import judge as line_judge
    import judge_keys
    for p in plays:
        label = p["result"].get("label")
        mov = jdir / "video" / f"{label}.mov"
        if not mov.is_file() or mov.stat().st_size == 0:
            continue
        rect = next(s["result"] for s in res["steps"] if s.get("do") == "typing_rect" and s.get("ok"))
        meta = json.loads(Path(str(mov)[:-4] + ".meta.json").read_text())
        scale = float(meta["start"]["scale"])
        crop = [int(round(v * scale)) for v in rect["rect_points_top_left"]]
        crop[2] -= crop[2] % 2
        crop[3] -= crop[3] % 2
        frames = line_judge.decode_band(mov, crop)
        times = line_judge.movie_times(f"{mov}.frames.json")
        m = min(len(frames), len(times))
        cell = float(rect.get("cell_width") or 8) * scale
        cell_h = float(rect.get("cell_height") or 16) * scale
        ids = {(e["i"], e["t_post"]) for e in p["result"]["events"]}
        part = [x for x in events if (x["i"], x["t_post"]) in ids]  # this part's keys, with their t_start
        rep = judge_keys.judge(frames[:m], times[:m], part, cell, cell_h_px=cell_h)
        (mov.with_suffix(".keys.json")).write_text(json.dumps(rep, indent=1))
        judged += 1
        refreshes += [r["refreshes"] for r in rep["keys"] if r.get("refreshes") is not None]
        missing += rep["summary"]["missing"]
        stalls += [dict(s, part=label) for s in rep["stalls"]]
        refresh_ms = meta.get("refresh_ms")
    loads = [s.get("result") or {} for s in res.get("steps", []) if s.get("do") == "load_stop" and s.get("result", {}).get("profile")]
    load_ok = bool(loads) and all(l.get("alive_at_stop") and l.get("focus_changed") is False for l in loads)
    hog = hog_held_gb(run, min(e["t_post"] for e in events), max(e["t_back"] for e in events))
    lag = max([p["result"].get("post_late_ms", {}).get("max") or 0 for p in plays] or [0])
    source = "video" if judged == len(plays) == 2 and (refreshes or missing) else "in-app"
    profile = a.journey.split("typing-load-")[1].split("-")[0].upper()
    full = refreshes + [10 ** 6] * missing  # a key never shown is a breach (review must-fix 1)
    refreshes = full
    row = {"profile": profile, "journey": a.journey, "build_job": row0.get("build_job"), "commit": row0.get("commit"),
           "kit": row0.get("kit"), "kit_dirty": row0.get("kit_dirty"), "smoke_env": smoke, "status": row0.get("status"),
           "refresh_ms": refresh_ms, "source": source, "keys": len(events),
           "p50_refreshes": pct(refreshes, 50), "p95_refreshes": pct(refreshes, 95), "p99_refreshes": pct(refreshes, 99),
           "max_refreshes": max(refreshes) if refreshes else None, "missing_frames": missing,
           "start_clock": start_clock, "parts": len(plays), "planned_keys": planned,
           "load_ok": load_ok if profile != "L0" else True, "loads": loads, "hog_held_gb": hog, "typist_late_ms_max": lag,
           "lost": keys.get("lost"), "merged": keys.get("merged"), "order_ok": keys.get("order_ok"),
           "pty_ms": keys.get("pty_ms"), "probe_contents_ms": probe_contents(jdir / "probe.csv"),
           "stalls_over_2": stalls[:50], "out": str(run), "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    print(json.dumps({k: v for k, v in row.items() if k != "stalls_over_2"}))
    if not a.dry_run and row["build_job"]:
        led = Path(a.ledger)
        led.mkdir(parents=True, exist_ok=True)
        with open(led / f"{row['build_job']}.jsonl", "a") as f:
            f.write(json.dumps(row) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
