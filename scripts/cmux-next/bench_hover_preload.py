#!/usr/bin/env python3
"""Hover preload bench (plans/cmux-next/hover-preload-DESIGN.md, cmux-ad m34).

Uses only socket calls every DEV or bench build has (`debug.pointer_hover`, `debug.frames`,
`debug.sidebar_rows`, `debug.surfaces`), so the same run measures a build without hover preload
(the base) and one with it, on one mini.

  (a) sweep   --workspaces sidebar rows, each with one hidden browser page, frozen or hibernated
              first. The synthetic pointer crosses one row per display frame (--hz), down and up,
              until it crossed --crossings rows, then leaves the sidebar. Printed: wakes started
              (prewarmed_total and restores, must be 0), missed refreshes and main-thread busy ms
              per frame over the sweep (p50/p95/p99/max), and each pointer move's round trip through
              the main thread (an upper bound of its main-thread cost: it includes the socket). The
              synthetic pointer walks the window's tracking areas on every move, so these numbers carry
              the harness's own cost: only the difference between a base build and a head build counts.
              Only rows the pointer really hovers are swept (each is checked once first); the sweep is
              reported invalid when the swept pages did not all freeze or hibernate first.
  (b) click   one workspace with --panes browser panes, hibernated by the timeout. --trials times
              each: "cold" (select it from another workspace, no hover) and "dwell" (the pointer
              rests --dwell-ms on its row, then select). Time to content: from the select until
              every shown page is live (not the hibernated stand-in) and answers
              document.readyState == "complete".
  (c) grace   after a dwell with no select: renderer footprint before the hover, after the wake, and
              after hoverGrace (30 s) plus --grace-slack-s; the woken pages must hibernate again.

Usage (a fleet mini, never a laptop; DEV or bench build):
  bench_hover_preload.py --app BUNDLE [--engine webkit|chromium] [--workspaces 40] [--crossings 200]
      [--hz 120] [--panes 2] [--trials 5] [--dwell-ms 150] [--out FILE.json]
Prints PERF-HOVER lines.
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import shutil
import signal
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402  (launch, App, sample, end_bundle, wait_gone)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)

PAGE = (b"<!doctype html><title>hover bench</title><body style='font:16px sans-serif'>"
        + b"<h1>Hover preload bench</h1>" + b"<p>" + b"Lorem ipsum dolor sit amet. " * 400 + b"</p></body>")
GRACE_S = 30  # BrowserHibernation.hoverGrace


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (http.server API)
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def serve() -> int:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


class Sites:
    """A site of its own per page, so a discard or a wake changes its own renderer (as
    bench_hibernation.page_url): Chromium tN.localhost on one port, WebKit a port each."""

    def __init__(self, engine: str):
        self.engine, self.ports, self.count = engine, [serve()], 0

    def next(self, label: str) -> str:
        index, self.count = self.count, self.count + 1
        if self.engine == "chromium":
            return f"http://t{index}.localhost:{self.ports[0]}/?n={label}"
        if index >= len(self.ports):
            self.ports.append(serve())
        return f"http://127.0.0.1:{self.ports[index]}/?n={label}"


def pct(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round(p * (len(ordered) - 1))))], 3)


def dist(values: list[float]) -> dict:
    return {"n": len(values), "p50": pct(values, 0.5), "p95": pct(values, 0.95), "p99": pct(values, 0.99),
            "max": round(max(values), 3) if values else None}


def wait_for(predicate, seconds: float, step: float = 0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test script: polls the app's state
    return predicate()


class Bench:
    def __init__(self, sock: str, app: bm.App):
        self.sock, self.app = sock, app

    def rpc(self, method: str, params: dict | None = None, timeout: float = 30):
        return bp.rpc(self.sock, method, params, timeout=timeout) or {}

    def hibernation(self) -> dict:
        return self.rpc("debug.surfaces").get("hibernation") or {}

    def window(self) -> dict:
        mains = [w for w in self.rpc("debug.window_list").get("windows") or [] if w.get("kind") == "main"]
        return mains[0] if mains else {}

    def rows(self) -> list[dict]:
        windows = self.rpc("debug.sidebar_rows").get("windows") or []
        rows = (windows[0] if windows else {}).get("rows") or []
        rows = [r for r in rows if str(r.get("key", "")).startswith("workspace(") and r.get("in_list") and r.get("window_frame")]
        return sorted(rows, key=lambda r: float(r["window_frame"]["y"]))

    def center(self, row: dict, height: float) -> list[float]:
        # window_frame is top-left origin; debug.pointer_hover takes bottom-left window points.
        f = row["window_frame"]
        return [float(f["x"]) + float(f["width"]) / 2, height - (float(f["y"]) + float(f["height"]) / 2)]

    def hover(self, point: list[float] | None) -> float:
        started = time.perf_counter()
        self.rpc("debug.pointer_hover", {"point": point} if point else {})
        return (time.perf_counter() - started) * 1000

    def row_of(self, workspace: str) -> dict | None:
        return next((r for r in self.rows() if workspace in str(r.get("key"))), None)

    def hovered_keys(self) -> set[str]:
        windows = self.rpc("debug.sidebar_rows").get("windows") or []
        return {str(r.get("key")) for r in (windows[0] if windows else {}).get("rows") or [] if r.get("hovered")}

    def hoverable(self, rows: list[dict], height: float) -> list[tuple[dict, list[float]]]:
        """The rows whose center the synthetic pointer really hovers (not the overscan band, the footer)."""
        kept = []
        for row in rows:
            point = self.center(row, height)
            self.hover(point)
            if str(row.get("key")) in self.hovered_keys():
                kept.append((row, point))
        self.hover(None)
        return kept

    def open_workspace(self, engine: str, urls: list[str]) -> tuple[str | None, list[str]]:
        made = self.app.run("workspace.newAtBottom")
        created = [c for c in made.get("created", []) if str(c).startswith("ws_")]
        if not created:
            print(f"   workspace.newAtBottom: {made.get('error') or made}", file=sys.stderr)
            return None, []
        self.app.run("workspace.selectLast")
        tabs = []
        for index, url in enumerate(urls):
            if index:
                self.app.run("splitRight")
            reply = self.app.run(f"openBrowser.{engine}", url=url)
            tabs += [t for t in reply.get("created", []) if str(t).startswith("tab_")]
        return created[0], tabs

    def live(self, tab: str, hibernated: set[str]) -> bool:
        # Never asks a hibernated page (a script call would wake it); a live page answers once it loaded.
        if tab in hibernated:
            return False
        answer = self.rpc("browser.page.eval", {"tab": tab, "script": "document.readyState"}, timeout=5)
        return not answer.get("error") and answer.get("value") == "complete"

    def asleep(self, tabs: list[str]) -> bool:
        return set(tabs) <= set(self.hibernation().get("hibernated") or [])


def sweep(bench: Bench, args, report: dict, points: list[list[float]]):
    if len(points) < 2:
        report["sweep"] = {"error": f"rows={len(points)}"}
        print(f"PERF-HOVER-SWEEP error rows={len(points)}", flush=True)
        return
    before = bench.hibernation()
    path, index, step = [], 0, 1
    while len(path) < args.crossings:
        path.append(points[index])
        if not 0 <= index + step < len(points):
            step = -step
        index += step
    period = 1.0 / args.hz
    bench.rpc("debug.frames", {"action": "start"})
    rtts, late = [], 0
    started = time.perf_counter()
    for i, point in enumerate(path):
        due = started + i * period
        now = time.perf_counter()
        if now < due:
            time.sleep(due - now)  # test script: paces the pointer to one row per display frame
        elif now - due > period:
            late += 1
        rtts.append(bench.hover(point))
    rtts.append(bench.hover(None))
    duration = time.perf_counter() - started
    time.sleep(0.5)  # test script: past the dwell, so a pending intent would have fired
    frames = bench.rpc("debug.frames", {"action": "stop", "raw": True})
    main_ms = [float(v) for v in frames.get("main_ms") or []]
    after = bench.hibernation()
    woke = (after.get("prewarmed_total") or 0) - (before.get("prewarmed_total") or 0)
    restores = (after.get("restored_total") or 0) - (before.get("restored_total") or 0)
    result = {"rows_on_screen": len(points), "crossings": len(path), "hz": args.hz, "duration_s": round(duration, 3),
              "rows_per_s": round(len(path) / duration, 1), "late_moves": late, "wakes": woke, "restores": restores,
              "move_rtt_ms": dist(rtts), "main_busy_ms_per_frame": dist(main_ms),
              "harness_cost_included": True,
              "frames": {k: frames.get(k) for k in (
                  "frames", "refresh_ms", "missed", "p50_ms", "p99_ms", "max_ms", "main_over_8_3_ms")}}
    report["sweep"] = result
    print(f"PERF-HOVER-SWEEP crossings={len(path)} rows_per_s={result['rows_per_s']} late_moves={late} wakes={woke} "
          f"restores={restores} missed={frames.get('missed')} main={json.dumps(result['main_busy_ms_per_frame'])} "
          f"move_rtt={json.dumps(result['move_rtt_ms'])}", flush=True)


def click_trials(bench: Bench, args, report: dict, target: str, tabs: list[str], away: str,
                 point: list[float] | None):
    trials = []
    for trial in range(args.trials):
        for mode in ("cold", "dwell"):
            bench.hover(None)  # first: the reveal scroll must not move rows under a resting pointer
            bench.app.action("goToWorkspace", workspace=away)
            if not wait_for(lambda: bench.asleep(tabs), args.sleep_wait_s, 1):
                trials.append({"trial": trial, "mode": mode, "error": "pages did not hibernate"})
                print(f"PERF-HOVER-CLICK trial={trial} mode={mode} error=not_hibernated", flush=True)
                continue
            if mode == "dwell":
                if not point:
                    trials.append({"trial": trial, "mode": mode, "error": "row not hoverable"})
                    print(f"PERF-HOVER-CLICK trial={trial} mode={mode} error=row_not_hoverable", flush=True)
                    continue
                bench.hover(point)
                time.sleep(args.dwell_ms / 1000)  # test script: the pointer rests on the row
            started = time.perf_counter()
            bench.app.action("goToWorkspace", workspace=target)
            shown_at = (time.perf_counter() - started) * 1000
            def content():
                hibernated = set(bench.hibernation().get("hibernated") or [])
                return all(bench.live(t, hibernated) for t in tabs)
            done = wait_for(content, 20, 0.03)
            content_ms = (time.perf_counter() - started) * 1000 if done else None
            entry = {"trial": trial, "mode": mode, "select_rtt_ms": round(shown_at, 2),
                     "content_ms": round(content_ms, 1) if content_ms else None}
            trials.append(entry)
            print(f"PERF-HOVER-CLICK trial={trial} mode={mode} content_ms={entry['content_ms']} "
                  f"select_rtt_ms={entry['select_rtt_ms']}", flush=True)
    summary = {}
    for mode in ("cold", "dwell"):
        values = [t["content_ms"] for t in trials if t.get("mode") == mode and t.get("content_ms") is not None]
        summary[mode] = dist(values)
    report["click"] = {"trials": trials, "summary": summary}
    print(f"PERF-HOVER-CLICK-SUMMARY cold={json.dumps(summary['cold'])} dwell={json.dumps(summary['dwell'])}", flush=True)


def grace(bench: Bench, args, report: dict, pid: int, bundle: str, tabs: list[str], away: str,
          point: list[float] | None):
    bench.hover(None)
    bench.app.action("goToWorkspace", workspace=away)
    if not wait_for(lambda: bench.asleep(tabs), args.sleep_wait_s, 1):
        report["grace"] = {"error": "pages did not hibernate"}
        print("PERF-HOVER-GRACE error=not_hibernated", flush=True)
        return
    time.sleep(5)  # test script: renderers of the discarded pages exit
    asleep = bm.sample(pid, bundle, "asleep", 1)
    if not point:
        report["grace"] = {"error": "row not hoverable"}
        print("PERF-HOVER-GRACE error=row_not_hoverable", flush=True)
        return
    bench.hover(point)
    time.sleep(args.dwell_ms / 1000)  # test script: the pointer rests on the row
    bench.hover(None)
    woke = wait_for(lambda: not bench.asleep(tabs), 20, 0.1)
    time.sleep(3)  # test script: the woken pages load
    awake = bm.sample(pid, bundle, "woken", 1)
    back = wait_for(lambda: bench.asleep(tabs), GRACE_S + args.grace_slack_s, 1)
    time.sleep(5)  # test script: renderers of the discarded pages exit
    again = bm.sample(pid, bundle, "after_grace", 1)
    result = {"woke": bool(woke), "hibernated_again": bool(back),
              "footprint_mb": {"asleep": asleep["total_footprint_mb"], "woken": awake["total_footprint_mb"],
                               "after_grace": again["total_footprint_mb"]}}
    report["grace"] = result
    print(f"PERF-HOVER-GRACE woke={result['woke']} hibernated_again={result['hibernated_again']} "
          f"footprint_mb={json.dumps(result['footprint_mb'])}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--engine", default="webkit", choices=["webkit", "chromium"])
    parser.add_argument("--workspaces", type=int, default=40)
    parser.add_argument("--crossings", type=int, default=200)
    parser.add_argument("--hz", type=float, default=120)
    parser.add_argument("--panes", type=int, default=2)
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--dwell-ms", type=float, default=150)
    parser.add_argument("--sleep-wait-s", type=float, default=150)
    parser.add_argument("--grace-slack-s", type=float, default=30)
    parser.add_argument("--phases", default="sweep,click,grace")
    parser.add_argument("--out")
    args = parser.parse_args()
    phases = set(args.phases.split(","))
    # Hidden pages discard after 0.5 min (a timeout written, so the hover may restore them) and freeze after 5 s.
    config = {"browser": {"hibernation": 0.5, "freezeHiddenTabs": 5}}
    bundle = os.path.realpath(args.app)
    signal.signal(signal.SIGTERM, bm.interrupted)
    bp.wipe_state(bundle)
    pid, sock, scratch = bm.launch(bundle, config)
    app = bm.App(bundle, sock)
    bench = Bench(sock, app)
    sites = Sites(args.engine)
    report = {"app": bundle, "engine": args.engine, "config": config}
    try:
        # The workspace the bench shows while the others are hidden, then the target right after it, so the
        # target's row is near the top of the sidebar (a select of the first scrolls to the top).
        home, _ = bench.open_workspace(args.engine, [sites.next("home")])
        target, target_tabs = bench.open_workspace(args.engine, [sites.next(f"t{i}") for i in range(args.panes)])
        sweep_tabs = []
        if "sweep" in phases:
            for index in range(args.workspaces):
                _, tabs = bench.open_workspace(args.engine, [sites.next(f"s{index}")])
                sweep_tabs += tabs
        bench.hover(None)
        bench.app.action("goToWorkspace", workspace=home)
        report["target"] = {"workspace": target, "tabs": target_tabs}
        # Which row centers the pointer really hovers, found once now, while every page is still live: a probe
        # step that rests past the dwell then wakes nothing, and any hover grace it starts (30 s) ends long before
        # the settle wait below. Row positions do not change after this (the bench adds no row).
        height = float(bench.window().get("frame", {}).get("height") or 0)
        hoverable = bench.hoverable(bench.rows(), height) if height else []
        points = [point for _, point in hoverable]
        target_point = next((point for row, point in hoverable if target and target in str(row.get("key"))), None)
        report["rows_hoverable"] = len(points)
        report["target_row_hoverable"] = target_point is not None
        if "sweep" in phases:
            # Every swept page frozen or hibernated first, so a wake would count. The planner discards a few
            # pages per pass after the 30 s timeout: wait in proportion to the page count.
            def settled():
                h = bench.hibernation()
                return set(sweep_tabs) <= set(h.get("hibernated") or []) | set(h.get("frozen") or [])
            wait_s = 30 + 2.5 * (len(sweep_tabs) + len(target_tabs)) + 30
            report["sweep_pages_settled"] = bool(wait_for(settled, wait_s, 1))
            if report["sweep_pages_settled"]:
                sweep(bench, args, report, [p for p in points if p != target_point])
            else:
                report["sweep"] = {"error": "invalid: the swept pages did not all freeze or hibernate first"}
                print("PERF-HOVER-SWEEP invalid=not_settled", flush=True)
        if "click" in phases and target:
            click_trials(bench, args, report, target, target_tabs, home, target_point)
        if "grace" in phases and target:
            grace(bench, args, report, pid, bundle, target_tabs, home, target_point)
    finally:
        app.run("quit")
        bm.wait_gone(pid, 20)
        bm.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=1)
            print(f"bench-hover-preload: wrote {args.out}")


if __name__ == "__main__":
    main()
