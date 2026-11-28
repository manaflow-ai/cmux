#!/usr/bin/env python3
"""Transcript fling in the real app: the React transcript against the native one (RFD 0121, app-perf.md section 6,
"First PR": "the native transcript behind a flag, read-only, the 3,000-row fixture, measured against the web arm
in the same app on the same display").

Both arms run in one launched app (bench_launch.BenchApp), interleaved: web, native, web, native ... for
`--rounds` rounds after one warm-up pair, so drift in the machine (thermals, other load) lands on both.

- web: a new agent chat, `debug.agent_pane seed_rows` 3,000 rows, then its `fling` for `--seconds` (bottom to
  top) and `perf_stats raw`: the page's own frame intervals while flinging.
- native: `debug.native_transcript open` (the 3,000-row fixture in its own CAMetalLayer window, drawn on its own
  render thread), `scroll_to` the end, `stats_reset`, `fling` at `--velocity` and wait `--seconds`, then `stats`:
  the presented-time intervals of what reached the glass (`presented_*`), else the scene's own frame clock, and
  the late textures (a rich row on screen before its texture was ready).

Per arm and round: frame interval p50 / p95 / max ms, intervals over 1.5 refresh periods, frames over one 120 Hz
frame (8.33 ms, `late_frames`), blank frames (web) and late textures (native). The summary is the median over the
rounds, one JSON line per arm in webviews/bench/transcript-fling.bench.ts's shape (`TRANSCRIPT_FLING_JSON {...}`
on stdout; `--out` writes the lines), so scripts/perf-bench/xbench.py `transcript_fling_rows` reads it.

Report only: exit 0 whatever the numbers; 1 only when the app never came up.
Run (a Mac with a Debug or bench build): python3 scripts/ci/frame-pacing/transcript_fling.py --app PATH.app
"""
import argparse
import json
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = "cmux/transcript-fling/v1"
ROWS = 3000
FRAME_120_MS = 1000 / 120
ARMS = ("web", "native")


# ---------------------------------------------------------------- judge (pure; tests/test_transcript_fling.py)

def percentile(values, q):
    """The nearest-rank `q` quantile (0..1) of `values`; None when empty."""
    ordered = sorted(v for v in values if v is not None)
    if not ordered:
        return None
    return ordered[min(len(ordered) - 1, max(0, round((len(ordered) - 1) * q)))]


def median(values):
    ordered = sorted(v for v in values if v is not None)
    if not ordered:
        return None
    mid = len(ordered) // 2
    return ordered[mid] if len(ordered) % 2 else (ordered[mid - 1] + ordered[mid]) / 2


def _r(value):
    return None if value is None else round(float(value), 2)


def web_arm(perf, rows=ROWS, refresh_ms=FRAME_120_MS):
    """One web round from `debug.agent_pane perf_stats raw` (`samples[].interval_ms`, `blank`)."""
    if not isinstance(perf, dict) or perf.get("error"):
        return {"error": str((perf or {}).get("error") if isinstance(perf, dict) else perf)[:300]}
    samples = [s for s in perf.get("samples") or [] if isinstance(s, dict)]
    intervals = [float(s["interval_ms"]) for s in samples if isinstance(s.get("interval_ms"), (int, float))
                 and s["interval_ms"] > 0]
    if not intervals:
        return {"error": "no frame intervals in perf_stats"}
    blank = perf.get("blank_frames")
    if blank is None:
        blank = sum(1 for s in samples if s.get("blank"))
    return {"frames": len(intervals), "frame_p50_ms": _r(percentile(intervals, 0.5)),
            "frame_p95_ms": _r(percentile(intervals, 0.95)), "frame_max_ms": _r(max(intervals)),
            "late_frames": sum(1 for v in intervals if v > FRAME_120_MS + 0.01),
            "over_1_5_refresh": sum(1 for v in intervals if v > refresh_ms * 1.5),
            "blank_frames": int(blank), "late_textures": None, "clock": "page", "rows": rows}


def native_arm(stats, rows=ROWS):
    """One native round from `debug.native_transcript stats`: the presented-time intervals when there are any
    (what reached the glass), else the scene's own frame clock."""
    if not isinstance(stats, dict) or stats.get("error"):
        return {"error": str((stats or {}).get("error") if isinstance(stats, dict) else stats)[:300]}
    presented = stats.get("presented_interval_p95_ms") is not None and (stats.get("presented_frames") or 0) > 1
    prefix, clock = ("presented_", "presented") if presented else ("", "scene")
    p95 = stats.get(prefix + "interval_p95_ms")
    if p95 is None:
        return {"error": "no frame intervals in native stats"}
    # Over 1.5 refresh periods is counted on the presented clock only; over 8.33 ms is the scene's own count.
    over = stats.get("presented_intervals_over_1_5_refresh") if presented else None
    late = stats.get("intervals_over_8_33")
    return {"frames": int(stats.get(prefix + "frames") or 0), "frame_p50_ms": _r(stats.get(prefix + "interval_p50_ms")),
            "frame_p95_ms": _r(p95), "frame_max_ms": _r(stats.get(prefix + "interval_max_ms")),
            "late_frames": None if late is None else int(late),
            "over_1_5_refresh": None if over is None else int(over), "blank_frames": 0,
            "late_textures": int(stats.get("late_textures") or 0),
            "skipped_frames": int(stats.get("skipped_frames") or 0), "clock": clock, "rows": rows}


def summarize(arm, rounds, engine, rows=ROWS):
    """The arm's JSON line (transcript-fling.bench.ts's shape plus this bench's fields): medians over the rounds
    that measured; `rounds_ok` of `rounds_run`."""
    good = [r for r in rounds if "error" not in r]
    out = {"schema": SCHEMA, "arm": f"app-{arm}", "engine": engine, "fixture": f"fixture-{rows}", "rows": rows,
           "mode": "fling", "rounds_run": len(rounds), "rounds_ok": len(good)}
    for key in ("frames", "frame_p50_ms", "frame_p95_ms", "frame_max_ms", "late_frames", "over_1_5_refresh",
                "blank_frames", "late_textures"):
        value = median([r.get(key) for r in good])
        out[key] = None if value is None else (_r(value) if key.endswith("_ms") else int(round(value)))
    errors = [r["error"] for r in rounds if "error" in r]
    if errors:
        out["errors"] = errors[:5]
    if not good:
        # xbench formats these numbers; a never-measured arm reports zeros and says so.
        out.update({k: 0 for k in ("frames", "frame_p50_ms", "frame_p95_ms", "frame_max_ms", "late_frames",
                                   "blank_frames")})
        out["not_measured"] = True
    return out


# ---------------------------------------------------------------- driving the app (macOS)

class Driver:
    def __init__(self, app, args):
        self.app, self.args = app, args

    def pane(self, action, timeout=30, **params):
        reply = self.app.rpc("debug.agent_pane", dict(params, action=action), timeout=timeout)
        return reply if isinstance(reply, dict) else {"error": f"invalid reply {reply!r}"[:200]}

    def native(self, action, timeout=30, **params):
        reply = self.app.rpc("debug.native_transcript", dict(params, action=action), timeout=timeout)
        return reply if isinstance(reply, dict) else {"error": f"invalid reply {reply!r}"[:200]}

    def wait(self, check, seconds, step=0.1):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = check()
            if value:
                return value
            time.sleep(step)  # bench: polls the live app
        return None

    def open_chat(self):
        reply = self.app.rpc("action.run", {"action": "palette.newAgentChat"})
        error = reply.get("error") if isinstance(reply, dict) else None
        if error and not (isinstance(error, dict) and (error.get("data") or {}).get("state") == "in_progress"):
            return {"error": f"open chat: {error}"[:300]}
        ready = self.wait(lambda: (lambda r: r if r.get("composer_visible") and r.get("document_ready") else None)(
            self.pane("readiness", timeout=5)), 40)
        if not ready:
            return {"error": "the chat page never became ready"}
        seeded = self.pane("seed_rows", count=ROWS, timeout=120)
        if seeded.get("error"):
            return {"error": f"seed_rows: {seeded['error']}"[:300]}
        time.sleep(2)  # bench: the seeded rows lay out before the first fling
        return {"engine": self.pane("engine").get("engine") or "web"}

    def web_round(self, refresh_ms):
        fling = self.pane("fling", seconds=self.args.seconds, wait=True, timeout=self.args.seconds + 30)
        if fling.get("error"):
            return {"error": f"fling: {fling['error']}"[:300]}
        return web_arm(self.pane("perf_stats", raw=True, timeout=30), refresh_ms=refresh_ms)

    def native_round(self):
        self.native("scroll_to", offset=1e12)
        time.sleep(0.5)  # bench: the end's rows and their textures arrive before the fling
        self.native("stats_reset")
        time.sleep(0.1)  # bench: the reset is drained at the next tick
        stats = self.native("fling", velocity=self.args.velocity, wait=self.args.seconds, timeout=self.args.seconds + 30)
        return native_arm(stats)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--rounds", type=int, default=3, help="measured rounds per arm, after one warm-up pair")
    parser.add_argument("--seconds", type=float, default=3, help="each fling's length")
    parser.add_argument("--velocity", type=float, default=-6000, help="the native fling's points per second")
    parser.add_argument("--json", help="the whole report (rounds and summaries)")
    parser.add_argument("--out", help="the summary arms, one JSON line each (xbench's TRANSCRIPT_FLING_OUT)")
    parser.add_argument("--artifacts", default=None, help="the app's log folder")
    parser.add_argument("--deadline", type=float, default=900, help="seconds for the whole run")
    opts = parser.parse_args(argv)
    sys.path.insert(0, os.path.join(HERE, "..", "..", "cmux-next"))
    from bench_launch import BenchApp, LaunchError  # noqa: E402  (macOS only: the judge above imports nowhere)

    artifacts = os.path.abspath(opts.artifacts or tempfile.mkdtemp(prefix="transcript-fling-"))
    os.makedirs(artifacts, exist_ok=True)
    report: dict = {"tool": "scripts/ci/frame-pacing/transcript_fling.py", "report_only": True, "rows": ROWS,
                    "seconds": opts.seconds, "velocity": opts.velocity, "rounds": {arm: [] for arm in ARMS}}

    def write(lines=None):
        for path, body in ((opts.json, json.dumps(report, indent=1)),
                           (opts.out, "\n".join(json.dumps(line) for line in lines or []) + "\n" if lines else None)):
            if path and body is not None:
                with open(path + ".tmp", "w") as handle:
                    handle.write(body)
                os.replace(path + ".tmp", path)

    app = BenchApp(opts.app, out=artifacts, window=(40, 40, 1000, 1100), screen="last")
    deadline = time.monotonic() + opts.deadline
    try:
        try:
            app.launch(timeout=180)
        except LaunchError as error:
            report["error"] = f"launch: {error}"
            write()
            return 1
        driver = Driver(app, opts)
        chat = driver.open_chat()
        opened = driver.native("open", width=900, height=1000, timeout=60)
        report["web_setup"], report["native_setup"] = chat, {k: v for k, v in opened.items() if not isinstance(v, float)}
        refresh_ms = opened.get("refresh_ms") or FRAME_120_MS
        report["refresh_ms"] = refresh_ms
        engine = {"web": chat.get("engine") or "web", "native": "metal"}
        for index in range(opts.rounds + 1):
            for arm in ARMS:
                if time.monotonic() > deadline - (opts.seconds + 40):
                    report["rounds"][arm].append({"error": "run deadline"})
                    continue
                if arm == "web":
                    result = chat if "error" in chat else driver.web_round(refresh_ms)
                elif "error" in opened or not opened.get("renderer"):
                    result = {"error": opened.get("error") or "no renderer (no GPU, or the scene refused the size)"}
                else:
                    result = driver.native_round()
                if index == 0:
                    report.setdefault("warmup", {})[arm] = result
                    continue
                report["rounds"][arm].append(result)
                print(f"TRANSCRIPT-FLING round={index} arm={arm} " + json.dumps(result), flush=True)
            write()
        lines = [summarize(arm, report["rounds"][arm], engine[arm]) for arm in ARMS]
        report["summary"] = lines
        for line in lines:
            print("TRANSCRIPT_FLING_JSON " + json.dumps(line), flush=True)
        write(lines)
        driver.native("close")
    finally:
        app.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
