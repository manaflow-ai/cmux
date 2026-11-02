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
import math
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
VENV = "/work/tmp/video-extra/venv/bin/python"
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
    keys = {}
    if (jdir / "echo.jsonl").is_file():
        sys.path.insert(0, str(HERE))
        import keys_check
        reads = [json.loads(l) for l in (jdir / "echo.jsonl").read_text().splitlines() if '"bytes"' in l]
        keys = keys_check.check(events, reads)
    refreshes, stalls, refresh_ms, judged = [], [], None, 0
    for p in plays:
        label = p["result"].get("label")
        mov = jdir / "video" / f"{label}.mov"
        if not mov.is_file() or mov.stat().st_size == 0:
            continue
        out = mov.with_suffix(".keys.json")
        done = subprocess.run([VENV, str(HERE / "judge_keys.py"), "--video", str(mov), "--frames", f"{mov}.frames.json",
                               "--result", str(jdir / "result.json"), "--label", label, "--out", str(out)],
                              capture_output=True, text=True)
        if done.returncode != 0 or not out.is_file():
            continue
        rep = json.loads(out.read_text())
        judged += 1
        refreshes += [r["refreshes"] for r in rep["keys"] if r.get("refreshes") is not None]
        stalls += [dict(s, part=label) for s in rep["stalls"]]
        refresh_ms = rep["input"].get("refresh_ms")
    source = "video" if judged == len(plays) and refreshes else "in-app"
    profile = a.journey.split("typing-load-")[1].split("-")[0].upper()
    row = {"profile": profile, "journey": a.journey, "build_job": row0.get("build_job"), "commit": row0.get("commit"),
           "kit": row0.get("kit"), "kit_dirty": row0.get("kit_dirty"), "smoke_env": smoke, "status": row0.get("status"),
           "refresh_ms": refresh_ms, "source": source, "keys": len(events),
           "p50_refreshes": pct(refreshes, 50), "p95_refreshes": pct(refreshes, 95), "p99_refreshes": pct(refreshes, 99),
           "max_refreshes": max(refreshes) if refreshes else None, "missing_frames": len(events) - len(refreshes) if judged else None,
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
