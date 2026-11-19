#!/usr/bin/env python3
"""The perf cron's memory-day part (split-spring-terminal.py --suite=memory-day): the app's memory growth per hour
over a typical day, replayed in minutes, as perf-cron rows.

Leo, 2026-11-19: "a lot of this is just applying things properly and having those measurements in so that we're
aware of things." Leo, 2026-11-14: "the bigger question is of memory and cpu staying flat on infinite chats. i
obviously dont mean infinite at once, but the dream of never ever needing to close a tab or workspace or anything."

The cron stored the app's memory at rest (memory-agents: empty and with 10 idle chats) and, on Linux, the daemons'
growth per simulated day (infinite-items: acpmux and headless cmux-tui). Nothing measured the app itself (its own
process, Chromium's renderers and GPU process, the bundled daemons) while it is used for hours. This replays a day of
use on the bench (Release) app, at many times real speed, and fits the growth per simulated hour per process kind.

The app launches on a scratch home (bench_memory.launch), opens KEEP workspaces, and samples. Then each simulated hour:
  - a new workspace on a new agent chat whose first turn is answered (the acpmux test agent), with a terminal tab and
    a browser tab on a page of its own site (a new renderer under site isolation);
  - a terminal tab opened in it, SEQ lines of output written to it, the tab closed;
  - a browser tab opened on another new site, the tab closed;
  - SWITCHES workspace switches across the open workspaces;
  - the oldest workspace closed, so KEEP workspaces stay open: a day's sample is always the same app shape;
then it settles SETTLE seconds and samples every process's physical footprint (bench_memory.sample). The app's own
timers run on the wall clock; no product clock is moved (the hidden-chat and hibernation timers keep their
defaults, so a compressed hour does less of their work than a real one: this is the growth from use, not from time).

Each row is the least-squares slope of a kind's footprint over the samples of hours 1 to HOURS (hour 0, right after
the first workspaces opened, holds the one-time warm-up), in MB per simulated hour; a shrinking kind reads 0 (perf-cron
and NOW read a negative number as none). Kinds (bench_memory.kind_of, grouped so a row each stays across builds):
  app            the app process
  cef_renderer   Chromium renderers (cmux's own pages and web pages)
  cef_gpu        Chromium's GPU process
  cef_other      Chromium's utility, plugin and other helpers
  webkit         the WebKit processes the app is responsible for
  daemon         every bundled daemon and helper: cmux-tui and its terminal hosts and holder, acpmux and its helpers
  total          all of them
memory.day_replay.<kind>.mb_per_h is the row; its target and noise floor are the kind's FLOOR_MB_PER_H (flat: a slope
under the noise of a run reads as flat). The report also keeps every sample, each fit's standard error, and the
open/close counts.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FAKE_AGENT = "cmux-tui/crates/acpmux/tests/fake_agent.py"
PREFIX = "memory.day_replay."
KINDS = ("app", "cef_renderer", "cef_gpu", "cef_other", "webkit", "daemon", "total")
# Flat, within a run's noise (MB per simulated hour). Goal: Leo's "never ever needing to close a tab or workspace"
# (CMUX-571 infinite-items-flat: RAM bounded over days), so the target is no growth; the floor is what one run's slope
# moves by with no leak. The app-wide footprint moved 849-941 MB launch to launch (memory-agents TOTAL_FLOOR_MB = 50);
# within one run, sample to sample at one shape, the first runs read the standard errors in the PR that added this.
FLOOR_MB_PER_H = {"app": 5.0, "cef_renderer": 10.0, "cef_gpu": 5.0, "cef_other": 2.0, "webkit": 5.0, "daemon": 5.0,
                  "total": 20.0}


def kind_group(kind: str) -> str:
    """bench_memory's process kind as one of KINDS (pure)."""
    if kind == "app":
        return "app"
    if kind == "cef-renderer":
        return "cef_renderer"
    if kind == "cef-gpu":
        return "cef_gpu"
    if kind.startswith("cef-"):
        return "cef_other"
    if kind.startswith("webkit-"):
        return "webkit"
    return "daemon"


def grouped(sample: dict) -> dict[str, float]:
    """{group: footprint MB} of one bench_memory sample, with `total` (pure)."""
    out = {k: 0.0 for k in KINDS}
    for kind, entry in (sample.get("kinds") or {}).items():
        value = (entry or {}).get("footprint_mb") if isinstance(entry, dict) else None
        if isinstance(value, (int, float)):
            out[kind_group(str(kind))] += value
            out["total"] += value
    return {k: round(v, 1) for k, v in out.items()}


def fit(xs: list[float], ys: list[float]) -> tuple[float, float | None]:
    """(least-squares slope, its standard error or None under 3 points) (pure)."""
    n = len(xs)
    if n < 2:
        return 0.0, None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if not sxx:
        return 0.0, None
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    if n < 3:
        return slope, None
    resid = sum((y - (my + slope * (x - mx))) ** 2 for x, y in zip(xs, ys))
    return slope, (resid / (n - 2) / sxx) ** 0.5


def rows_from(report: dict) -> tuple[list[dict], dict]:
    """perf-cron rows and the per-kind fit from the replay's samples (pure). Only hours 1.. at the steady shape count:
    a sample whose workspaces differ from the run's KEEP is not that shape and is left out."""
    keep = report.get("keep")
    hours = [s for s in report.get("samples") or [] if isinstance(s, dict) and isinstance(s.get("hour"), int)
             and s["hour"] >= 1 and s.get("workspaces") == keep]
    if len(hours) < 3:
        return [], {}
    xs = [float(s["hour"]) for s in hours]
    fits, rows = {}, []
    for kind in KINDS:
        ys = [grouped(s)[kind] for s in hours]
        slope, se = fit(xs, ys)
        fits[kind] = {"mb_per_h": round(slope, 2), "se": round(se, 2) if se is not None else None,
                      "first_mb": ys[0], "last_mb": ys[-1]}
        value = round(max(0.0, slope), 2)
        rows.append({"name": f"{PREFIX}{kind}.mb_per_h", "p50": value, "p95": value, "unit": "MB/h",
                     "budget": FLOOR_MB_PER_H[kind], "floor": FLOOR_MB_PER_H[kind], "hours": len(hours)})
    return rows, fits


def created(response: dict, prefix: str) -> str | None:
    return next((str(i) for i in (response or {}).get("created", []) if str(i).startswith(prefix)), None)


def replay(args: argparse.Namespace, report: dict) -> None:
    sys.path.insert(0, HERE)
    import bench_memory as bm

    bundle = os.path.realpath(args.app)
    signal.signal(signal.SIGTERM, bm.interrupted)
    pid, sock, scratch = bm.launch(bundle, {})
    app = bm.App(bundle, sock)
    sites = bm.local_sites(2 * (args.hours + args.keep) + 2)
    counts = report["counts"] = {"workspaces_opened": 0, "workspaces_closed": 0, "terminal_tabs": 0,
                                 "browser_tabs": 0, "chats": 0, "switches": 0, "failures": []}
    opened: list[str] = []
    site = iter(sites)

    def fail(what, response):
        counts["failures"].append(f"{what}: {(response or {}).get('error') or (response or {}).get('message') or response}"[:200])

    def open_one(index: int) -> None:
        workspace = bm.open_workspace(app, "terminal+chat+browser", next(site), index, chats)
        if workspace is None:
            fail(f"workspace {index}", {"error": "not made"})
            return
        opened.append(workspace)
        counts["workspaces_opened"] += 1
        counts["chats"] += 1

    def sample(hour: int) -> None:
        time.sleep(args.settle)  # bench: let the app and its helpers go idle before the sample
        s = bm.sample(pid, bundle, f"hour-{hour}", len(opened) + 1)
        s["hour"] = hour
        s["groups"] = grouped(s)
        report["samples"].append(s)
        print(f"memory-day: hour {hour} workspaces {len(opened) + 1} {json.dumps(s['groups'])}", flush=True)

    try:
        chats = bm.FakeChats(app, bundle, os.path.join(ROOT, FAKE_AGENT))
        for index in range(args.keep - 1):  # the launch workspace counts as one
            open_one(index)
        sample(0)
        for hour in range(1, args.hours + 1):
            open_one(100 + hour)
            terminal = created(app.run("newSurface"), "tab_")
            if terminal:
                counts["terminal_tabs"] += 1
                sent = app.call("action.run", {"action": "terminal.sendText", "target": f"tab:{terminal}",
                                               "args": {"text": f"seq 1 {args.seq}\r"}})
                if sent.get("error"):
                    fail("terminal.sendText", sent)
                time.sleep(args.dwell)  # bench: the output drains into the terminal before its tab closes
                app.run("tab.close", target=terminal)
            else:
                fail("newSurface", {"error": "no tab"})
            page = created(app.run("openBrowser.chromium", url=next(site)), "tab_")
            if page:
                counts["browser_tabs"] += 1
                time.sleep(args.dwell)  # bench: the page loads before its tab closes
                app.run("tab.close", target=page)
            else:
                fail("openBrowser.chromium", {"error": "no tab"})
            for step in range(args.switches):
                if opened:
                    app.action("goToWorkspace", workspace=opened[(hour + step) % len(opened)], focus=True)
                    counts["switches"] += 1
            while len(opened) + 1 > args.keep:
                bm.close_workspace(app, opened.pop(0))
                counts["workspaces_closed"] += 1
            sample(hour)
    finally:
        for workspace in opened:
            bm.close_workspace(app, workspace)
        app.run("quit")
        bm.wait_gone(pid, 20)
        bm.end_bundle(bundle)
        report["pane_failures"] = bm.PANE_FAILURES[:20]
        if scratch:
            import shutil
            shutil.rmtree(scratch, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--json", required=True, help="the part's report.json")
    parser.add_argument("--out", default=None, help="split-spring's artifact folder (the replay's own samples go there)")
    parser.add_argument("--hours", type=int, default=12, help="simulated hours (a sample each)")
    parser.add_argument("--keep", type=int, default=5, help="workspaces open at each sample, the launch one included")
    parser.add_argument("--switches", type=int, default=6, help="workspace switches a simulated hour")
    parser.add_argument("--seq", type=int, default=20000, help="terminal output lines a simulated hour")
    parser.add_argument("--dwell", type=float, default=2.0, help="seconds a short-lived tab stays open")
    parser.add_argument("--settle", type=float, default=20.0, help="seconds before each sample")
    args, _rest = parser.parse_known_args(argv)  # split-spring's own args (--tag) are not this suite's
    if sys.platform != "darwin":
        raise SystemExit("memory-day-replay: macOS only (a fleet measure Mac)")
    if args.keep < 2 or args.hours < 3:
        raise SystemExit("memory-day-replay: --keep 2 or more and --hours 3 or more (a slope needs 3 samples)")
    out_dir = args.out or os.path.dirname(os.path.abspath(args.json))
    os.makedirs(out_dir, exist_ok=True)
    report = {"hours": args.hours, "keep": args.keep, "switches": args.switches, "seq": args.seq, "samples": []}
    error = None
    try:
        replay(args, report)
    except (Exception, KeyboardInterrupt, SystemExit) as exc:  # noqa: BLE001 - the samples so far are still written
        error = repr(exc)[:500]
        report["error"] = error
    with open(os.path.join(out_dir, "memory-day.json"), "w") as f:
        json.dump(report, f, indent=1)
    rows, fits = rows_from(report)
    out = {"rows": rows, "fits": fits, "counts": report.get("counts"), "hours": args.hours, "keep": args.keep,
           "groups": [{"hour": s["hour"], **s.get("groups", {})} for s in report["samples"]]}
    missing = []
    if error:
        missing.append(f"the replay stopped: {error}")
    if not rows:
        missing.append(f"under 3 samples at {args.keep} workspaces")
    if missing:
        out["incomplete"] = missing
    with open(args.json, "w") as f:
        json.dump(out, f, indent=1)
    for kind, f_ in fits.items():
        print(f"memory-day: {PREFIX}{kind}.mb_per_h = {f_['mb_per_h']} (se {f_['se']}; {f_['first_mb']} -> "
              f"{f_['last_mb']} MB)")
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
