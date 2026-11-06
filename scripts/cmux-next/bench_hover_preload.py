#!/usr/bin/env python3
"""Hover preload bench (plans/cmux-next/hover-preload-DESIGN.md, cmux-ad m34).

Uses only debug socket calls (`debug.pointer_hover {row}`, `debug.pointer_sweep`, `debug.frames`,
`debug.surfaces`), so the same run measures a build without hover preload (the base, with this harness
cherry-picked) and one with it, on one mini. The synthetic pointer aims at a row by its sidebar row id (the
store id in the row key; the bench names each workspace uniquely and maps its ws_ id by that title), read
in the app at the move (rows a reveal scroll moved are followed), and the sweep runs in the app, one move
per main-actor turn paced by the clock (not one socket round trip, a display frame, per move).

  (a) sweep   --workspaces sidebar rows, each with one hidden browser page, frozen or hibernated
              first. The synthetic pointer crosses --hz rows a second, down and up, until it crossed
              --crossings rows, then leaves the sidebar. Printed: wakes started (prewarmed_total and
              restores, must be 0), missed refreshes and main-thread busy ms per frame over the sweep
              (p50/p95/p99/max), each move's main-thread ms (event delivery and every handler it ran),
              and how many moves left their row hovered. Only rows the pointer really hovers are swept
              (each is checked once first); the sweep is reported invalid when the swept pages did not
              all freeze or hibernate first.
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
        self.titles: dict[str, str] = {}  # daemon workspace id -> the unique title the bench gave it
        self.mapped_by = "none"  # how row_keys mapped them: by "title", or by "order" when a rename was refused

    def rpc(self, method: str, params: dict | None = None, timeout: float = 30):
        return bp.rpc(self.sock, method, params, timeout=timeout) or {}

    def hibernation(self) -> dict:
        return self.rpc("debug.surfaces").get("hibernation") or {}

    def rows(self) -> list[dict]:
        windows = self.rpc("debug.sidebar_rows").get("windows") or []
        rows = (windows[0] if windows else {}).get("rows") or []
        rows = [r for r in rows if str(r.get("key", "")).startswith("workspace(") and r.get("in_list") and r.get("window_frame")]
        return sorted(rows, key=lambda r: float(r["window_frame"]["y"]))

    def hover(self, point: list[float] | None) -> float:
        started = time.perf_counter()
        self.rpc("debug.pointer_hover", {"point": point} if point else {})
        return (time.perf_counter() - started) * 1000

    def hover_row(self, workspace: str) -> dict:
        """The pointer to the middle of `workspace`'s sidebar row as the app draws it now (`workspace` is the row's
        store id, `row_key`); the reply says which workspace's row shows hovered after the move (`row_hovered`)."""
        return self.rpc("debug.pointer_hover", {"row": workspace})

    def row_keys(self, titles: dict[str, str]) -> dict[str, str]:
        """Each daemon workspace id (ws_..., what actions take) -> its sidebar row's store id (the UUID in the row
        key `workspace(<id>)`, what `debug.pointer_hover {row}` and `debug.pointer_sweep` take), by the unique
        title the bench gave each workspace. Waits until every title shows in the sidebar's rows."""
        def listed() -> list[tuple[str, str]]:
            windows = self.rpc("debug.sidebar_rows").get("windows") or []
            return [(key[len("workspace("):-1], str(row.get("title") or "")) for row in (windows[0] if windows else {}).get("rows") or []
                    for key in [str(row.get("key", ""))] if key.startswith("workspace(") and key.endswith(")")]

        def read():
            by_title = {title: key for key, title in listed()}
            found = {ws: by_title[title] for ws, title in titles.items() if title in by_title}
            return found if len(found) == len(titles) else None
        found = wait_for(read, 15, 0.25)
        if found:
            self.mapped_by = "title"
            return found
        # A rename the app refused: the bench's workspaces are the last rows, in the order newAtBottom made them.
        rows = listed()
        if len(rows) < len(titles):
            return {}
        self.mapped_by = "order"
        return {ws: key for ws, (key, _) in zip(titles, rows[-len(titles):])}

    def still(self) -> bool:
        """The sidebar's rows hold still (no reveal scroll or row motion in flight): two reads 0.3 s apart agree."""
        def frames():
            return [(r.get("key"), r["window_frame"].get("y")) for r in self.rows()]
        first = frames()
        time.sleep(0.3)  # test script: two reads apart
        return bool(first) and first == frames()

    def hoverable(self, workspaces: list[str]) -> tuple[list[str], list[dict]]:
        """The workspaces whose row the synthetic pointer really hovers (not under the footer, not scrolled off),
        and each refusal with what the app answered."""
        wait_for(self.still, 10, 0.2)
        kept, refused = [], []
        for workspace in workspaces:
            reply = self.hover_row(workspace)
            if str(reply.get("row_hovered") or "").endswith(workspace):
                kept.append(workspace)
            else:
                refused.append({"workspace": workspace, "reply": reply})
        self.hover(None)
        return kept, refused

    def open_workspace(self, engine: str, urls: list[str]) -> tuple[str | None, list[str]]:
        made = self.app.run("workspace.newAtBottom")
        created = [c for c in made.get("created", []) if str(c).startswith("ws_")]
        if not created:
            print(f"   workspace.newAtBottom: {made.get('error') or made}", file=sys.stderr)
            return None, []
        self.app.run("workspace.selectLast")
        # A unique title, so the bench finds this workspace's sidebar row (rows are keyed by store id, not ws_).
        self.titles[created[0]] = f"hover-bench-{len(self.titles)}"
        named = self.app.action("renameWorkspace", workspace=created[0], name=self.titles[created[0]])
        if named.get("error"):  # then through the CLI's --target
            named = self.app.run("renameWorkspace", target=created[0], name=self.titles[created[0]])
        if named.get("error"):
            print(f"   renameWorkspace {created[0]}: {named['error']}", file=sys.stderr)
        tabs = []
        for index, url in enumerate(urls):
            if index:
                self.app.run("splitRight")
            reply = self.app.run(f"openBrowser.{engine}", url=url)
            made_tabs = [t for t in reply.get("created", []) if str(t).startswith("tab_")]
            for tab in made_tabs:
                # A fresh profile starts on Home: a tab the daemon made has no page until it shows (as
                # bench_hibernation.open_tab). Show it, then wait until its page loaded.
                self.app.run("tab.focus", target=tab)
                if not wait_for(lambda t=tab: self.live(t, set()), 30, 0.1):
                    print(f"   {tab}: page did not load", file=sys.stderr)
            tabs += made_tabs
        return created[0], tabs

    def live(self, tab: str, hibernated: set[str]) -> bool:
        # Never asks a hibernated page (a script call would wake it); a live page answers once it loaded.
        if tab in hibernated:
            return False
        answer = self.rpc("browser.page.eval", {"tab": tab, "script": "document.readyState"}, timeout=5)
        return not answer.get("error") and answer.get("value") == "complete"

    def asleep(self, tabs: list[str]) -> bool:
        return set(tabs) <= set(self.hibernation().get("hibernated") or [])

    def diagnose(self, label: str, tabs: list[str]) -> dict:
        """Why `tabs` are not asleep: each one's lifecycle phase and exemption, counted, plus the setting the
        app reports. Printed as one PERF-HOVER-DIAG line and kept in the report."""
        h = self.hibernation()
        hibernated, frozen = set(h.get("hibernated") or []), set(h.get("frozen") or [])
        phases, exemptions = h.get("page_phases") or {}, h.get("exemptions") or {}
        counts: dict[str, int] = {}
        for tab in tabs:
            state = "hibernated" if tab in hibernated else phases.get(tab, "no_page")
            if tab in frozen:
                state += "+frozen"
            key = f"{state}/{exemptions.get(tab, '-')}"
            counts[key] = counts.get(key, 0) + 1
        result = {"label": label, "tabs": len(tabs), "states": counts, "mode": h.get("mode"),
                  "pressure": h.get("pressure"), "hibernated_total": h.get("hibernated_total"),
                  "sample_ids": {"bench": tabs[:2], "app": sorted(phases)[:2]}}
        print(f"PERF-HOVER-DIAG {json.dumps(result)}", flush=True)
        return result


def sweep(bench: Bench, args, report: dict, rows: list[str]):
    if len(rows) < 2:
        report["sweep"] = {"error": f"rows={len(rows)}"}
        print(f"PERF-HOVER-SWEEP error rows={len(rows)}", flush=True)
        return
    before = bench.hibernation()
    path, index, step = [], 0, 1
    while len(path) < args.crossings:
        path.append(rows[index])
        if not 0 <= index + step < len(rows):
            step = -step
        index += step
    bench.rpc("debug.frames", {"action": "start"})
    moved = bench.rpc("debug.pointer_sweep", {"path": path, "hz": args.hz}, timeout=90)
    time.sleep(0.5)  # test script: past the dwell, so a pending intent would have fired
    frames = bench.rpc("debug.frames", {"action": "stop", "raw": True})
    main_ms = [float(v) for v in frames.get("main_ms") or []]
    move_ms = [float(v) for v in moved.get("move_ms") or []]
    after = bench.hibernation()
    woke = (after.get("prewarmed_total") or 0) - (before.get("prewarmed_total") or 0)
    restores = (after.get("restored_total") or 0) - (before.get("restored_total") or 0)
    seconds = float(moved.get("seconds") or 0)
    result = {"rows_on_screen": len(rows), "crossings": len(path), "hz": args.hz, "duration_s": seconds,
              "rows_per_s": round(len(path) / seconds, 1) if seconds else None, "late_moves": moved.get("late"),
              "missing_rows": moved.get("missing"), "landed": moved.get("landed"), "hover_areas": moved.get("areas"),
              "error": moved.get("error"), "wakes": woke, "restores": restores,
              "move_ms": dist(move_ms), "main_busy_ms_per_frame": dist(main_ms),
              "frames": {k: frames.get(k) for k in (
                  "frames", "refresh_ms", "missed", "p50_ms", "p99_ms", "max_ms", "main_over_8_3_ms")}}
    report["sweep"] = result
    print(f"PERF-HOVER-SWEEP crossings={len(path)} rows_per_s={result['rows_per_s']} late_moves={result['late_moves']} "
          f"landed={result['landed']} missing={result['missing_rows']} wakes={woke} restores={restores} "
          f"refresh_ms={frames.get('refresh_ms')} missed={frames.get('missed')} "
          f"main={json.dumps(result['main_busy_ms_per_frame'])} move_ms={json.dumps(result['move_ms'])}"
          + (f" error={moved.get('error')}" if moved.get("error") else ""), flush=True)


def click_trials(bench: Bench, args, report: dict, target: str, row: str, tabs: list[str], away: str, hoverable: bool):
    """`target` is the workspace's daemon id (for actions), `row` its sidebar row id (for the pointer)."""
    trials = []
    for trial in range(args.trials):
        if report.get("click_stopped"):
            break
        for mode in ("cold", "dwell"):
            bench.hover(None)  # first: the reveal scroll must not move rows under a resting pointer
            bench.app.action("goToWorkspace", workspace=away)
            if not wait_for(lambda: bench.asleep(tabs), args.sleep_wait_s, 1):
                trials.append({"trial": trial, "mode": mode, "error": "pages did not hibernate",
                               "diag": bench.diagnose(f"click-{trial}-{mode}", tabs)})
                print(f"PERF-HOVER-CLICK trial={trial} mode={mode} error=not_hibernated", flush=True)
                # Every later trial would wait the same timeout for the same reason: the arm stops here.
                report["click_stopped"] = f"trial {trial} {mode}: pages did not hibernate"
                break
            if mode == "dwell":
                landed = str(bench.hover_row(row).get("row_hovered") or "").endswith(row) if hoverable else False
                if not landed:
                    trials.append({"trial": trial, "mode": mode, "error": "row not hoverable"})
                    print(f"PERF-HOVER-CLICK trial={trial} mode={mode} error=row_not_hoverable", flush=True)
                    continue
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
            if not done:
                # Why no content: each page's phase and what it answers now.
                entry["diag"] = bench.diagnose(f"click-{trial}-{mode}-no-content", tabs)
                entry["answers"] = {t: bench.rpc("browser.page.eval", {"tab": t, "script": "document.readyState"}, timeout=5)
                                    for t in tabs}
                print(f"PERF-HOVER-CLICK-NOCONTENT {json.dumps(entry['answers'])}", flush=True)
            trials.append(entry)
            print(f"PERF-HOVER-CLICK trial={trial} mode={mode} content_ms={entry['content_ms']} "
                  f"select_rtt_ms={entry['select_rtt_ms']}", flush=True)
    summary = {}
    for mode in ("cold", "dwell"):
        values = [t["content_ms"] for t in trials if t.get("mode") == mode and t.get("content_ms") is not None]
        summary[mode] = dist(values)
    report["click"] = {"trials": trials, "summary": summary}
    print(f"PERF-HOVER-CLICK-SUMMARY cold={json.dumps(summary['cold'])} dwell={json.dumps(summary['dwell'])}", flush=True)


def grace(bench: Bench, args, report: dict, pid: int, bundle: str, tabs: list[str], away: str, row: str,
          hoverable: bool):
    bench.hover(None)
    bench.app.action("goToWorkspace", workspace=away)
    if not wait_for(lambda: bench.asleep(tabs), args.sleep_wait_s, 1):
        report["grace"] = {"error": "pages did not hibernate", "diag": bench.diagnose("grace", tabs)}
        print("PERF-HOVER-GRACE error=not_hibernated", flush=True)
        return
    time.sleep(5)  # test script: renderers of the discarded pages exit
    asleep = bm.sample(pid, bundle, "asleep", 1)
    if not hoverable or not str(bench.hover_row(row).get("row_hovered") or "").endswith(row):
        report["grace"] = {"error": "row not hoverable"}
        print("PERF-HOVER-GRACE error=row_not_hoverable", flush=True)
        return
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
    # The arm's name in the report (the fleet entry runs the base build as "off" and the head as "on").
    parser.add_argument("--label", default="on")
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
    report = {"app": bundle, "engine": args.engine, "label": args.label, "config": config}
    print(f"PERF-HOVER-ARM label={args.label}", flush=True)
    try:
        # The workspace the bench shows while the others are hidden, then the target right after it, so the
        # target's row is near the top of the sidebar (a select of the first scrolls to the top).
        home, _ = bench.open_workspace(args.engine, [sites.next("home")])
        target, target_tabs = bench.open_workspace(args.engine, [sites.next(f"t{i}") for i in range(args.panes)])
        sweep_tabs, sweep_workspaces = [], []
        if "sweep" in phases:
            for index in range(args.workspaces):
                workspace, tabs = bench.open_workspace(args.engine, [sites.next(f"s{index}")])
                sweep_tabs += tabs
                sweep_workspaces += [workspace] if workspace else []
        bench.hover(None)
        bench.app.action("goToWorkspace", workspace=home)
        report["target"] = {"workspace": target, "tabs": target_tabs}
        # Every bench page must exist in the app before anything is timed: a page that never mounted cannot sleep.
        setup = bench.diagnose("setup", target_tabs + sweep_tabs)
        report["setup"] = setup
        if any(state.startswith("no_page") for state in setup["states"]):
            print("PERF-HOVER-SETUP invalid=pages_not_mounted", flush=True)
            raise SystemExit(3)
        # Which rows the pointer really hovers, found once now, while every page is still live: a probe step that
        # rests past the dwell then wakes nothing, and any hover grace it starts (30 s) ends long before the settle
        # wait below. The pointer aims at each row as drawn when it moves, so a later scroll does not matter.
        keys = bench.row_keys(bench.titles)
        report["row_keys"] = {"mapped": len(keys), "workspaces": len(bench.titles), "by": bench.mapped_by}
        print(f"PERF-HOVER-ROWKEYS mapped={len(keys)}/{len(bench.titles)} by={bench.mapped_by} sample={json.dumps(dict(list(keys.items())[:2]))}",
              flush=True)
        if len(keys) < len(bench.titles):
            print("PERF-HOVER-SETUP invalid=rows_not_mapped", flush=True)
            raise SystemExit(3)
        # The pointer names rows by their sidebar row id; actions keep the daemon id (target, home).
        target_row = keys.get(target) if target else None
        sweep_rows = [keys[w] for w in sweep_workspaces]
        kept, refused = bench.hoverable(([target_row] if target_row else []) + sweep_rows)
        why = (refused[0]["reply"].get("why") if refused else None) or {}
        if not kept and isinstance(why, dict) and (why.get("presentation") != "shown" or why.get("list_hidden")):
            # The window opened with its sidebar hidden (a narrow fleet display): show it, then look again.
            print(f"PERF-HOVER-ROWS sidebar_hidden why={json.dumps(why)}", flush=True)
            report["sidebar_shown_by_bench"] = bench.app.action("toggleSidebar")
            kept, refused = bench.hoverable(([target_row] if target_row else []) + sweep_rows)
        target_hoverable = bool(target_row) and target_row in kept
        report["rows_hoverable"] = len(kept)
        report["target_row_hoverable"] = target_hoverable
        report["rows_refused"] = refused[:5]
        print(f"PERF-HOVER-ROWS hoverable={len(kept)} refused={len(refused)} target={target_hoverable} "
              f"first_refused={json.dumps(refused[:2])}", flush=True)
        if "sweep" in phases:
            # Every swept page frozen or hibernated first, so a wake would count. The planner discards a few
            # pages per pass after the 30 s timeout: wait in proportion to the page count.
            def settled():
                h = bench.hibernation()
                return set(sweep_tabs) <= set(h.get("hibernated") or []) | set(h.get("frozen") or [])
            wait_s = 30 + 2.5 * (len(sweep_tabs) + len(target_tabs)) + 30
            report["sweep_pages_settled"] = bool(wait_for(settled, wait_s, 1))
            if report["sweep_pages_settled"]:
                sweep(bench, args, report, [w for w in kept if w != target_row])
            else:
                report["sweep"] = {"error": "invalid: the swept pages did not all freeze or hibernate first",
                                   "diag": bench.diagnose("sweep", sweep_tabs)}
                print("PERF-HOVER-SWEEP invalid=not_settled", flush=True)
        if "click" in phases and target:
            click_trials(bench, args, report, target, target_row, target_tabs, home, target_hoverable)
        if "grace" in phases and target:
            grace(bench, args, report, pid, bundle, target_tabs, home, target_row, target_hoverable)
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
