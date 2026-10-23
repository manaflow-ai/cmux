#!/usr/bin/env python3
"""Hidden web pages cost almost nothing: the page warm budget (plans/cmux-next/tab-lifecycle.md 3b,
perf-lead.md row 15). Pass/fail, for the tester; not wired into CI.

Opens one front Chromium tab (the shown tab; the engine's own processes start with it) and the
first WebKit bench tab (WebKit's shared processes start with it), samples the footprint, then
opens the rest of --chromium Chromium and --webkit WebKit tabs on local pages (each its own site,
so its own renderer, with a --heap-mb array standing in for a real site's heap) in the same pane
and shows the front tab again, so every bench tab is hidden well inside the 30 minute
`browser.hibernation` timeout. No neighbors (`keepNeighborTabsAwake` 0).

Then it waits (up to --wait s) for the hidden live pages to come down to the budget the app
reports (`debug.surfaces` hibernation `page_budget`; --budget on a build that reports none,
default 4), samples the footprint again and wakes --wakes hibernated tabs, reading each wake's
own record (`wakes`: snapshot shown, mounted_ms).

PASS when all hold:
  live      hidden live bench pages <= the budget
  bounded   footprint after - footprint before <= budget x --live-page-mb (default 90, a live
            renderer with its heap) + tabs opened after the sample x --max-mb-per-tab (default 3,
            a hibernated tab's record and pictures)
  picture   every woken tab showed its snapshot

On a build before the budget (e.g. 415ee799b49) every bench page stays live until the timeout:
live = all 18, the delta ~1 GB against a bound of ~410 MB, so it FAILS; with the budget it passes.
Printed too: per_tab_mb, the delta over the tabs opened after the sample.

Usage (a fleet GUI mini, never a laptop; a DEV build, it reads debug.surfaces):
  bench_hidden_memory.py --app BUNDLE [--chromium 12] [--webkit 6] [--heap-mb 20]
      [--live-page-mb 90] [--max-mb-per-tab 3] [--budget 4] [--wait 300] [--wakes 4] [--out FILE.json]
Prints PERF-HIDDEN lines and exits 0 on PASS, 1 on FAIL.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_hibernation as bh  # noqa: E402  (local pages, debug.surfaces, phases, wake records)
import bench_memory as bm  # noqa: E402  (launch, App, sample, end_bundle)
import bench_power as bp  # noqa: E402  (wipe_state)


def live_hidden(sock: str, tabs: list[str]) -> list[str]:
    asleep = set(bh.hibernation(sock).get("hibernated") or [])
    return [tab for tab in tabs if tab not in asleep]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--chromium", type=int, default=12)
    parser.add_argument("--webkit", type=int, default=6)
    parser.add_argument("--heap-mb", type=int, default=20)
    parser.add_argument("--live-page-mb", type=float, default=90, help="allowance per page the budget keeps live")
    parser.add_argument("--max-mb-per-tab", type=float, default=3, help="allowance per further hidden tab")
    parser.add_argument("--budget", type=int, default=4, help="the budget when the build reports none")
    parser.add_argument("--wait", type=float, default=300, help="seconds to wait for the pages to come down to the budget")
    parser.add_argument("--measure", type=float, default=10, help="seconds each footprint sample's CPU is read over")
    parser.add_argument("--wakes", type=int, default=4)
    parser.add_argument("--config", default="{}", help="extra cmux.json settings (JSON)")
    parser.add_argument("--out")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("bench-hidden-memory: macOS only (run it on a fleet mini)")
    bh._Handler.heap_mb = args.heap_mb
    count = max(args.chromium, args.webkit, 1)
    ports = [bh.serve() for _ in range(count)]
    config = bm.merged({"browser": {"hibernation": "moderate", "keepNeighborTabsAwake": 0}}, json.loads(args.config))
    bundle = os.path.realpath(args.app)
    signal.signal(signal.SIGTERM, bm.interrupted)
    bp.wipe_state(bundle)
    pid, sock, scratch = bm.launch(bundle, config)
    app = bm.App(bundle, sock)
    report: dict = {"app": bundle, "config": config, "phases": [], "wakes": []}
    verdict = 1

    def open_tab(engine: str, url: str) -> str | None:
        response = app.run(f"openBrowser.{engine}", url=url)
        created = [item for item in response.get("created", []) if str(item).startswith("tab_")]
        if response.get("error") or not created:
            print(f"   open {engine} {url}: {response.get('error') or response}", file=sys.stderr)
            return None
        tab = created[0]
        app.run("tab.focus", target=tab)
        if bh.evaluate(sock, tab, "1") is None:
            print(f"   {tab}: page did not answer", file=sys.stderr)
        return tab

    try:
        front = open_tab("chromium", f"http://front.localhost:{ports[0]}/?n=front")
        if not front:
            raise SystemExit("bench-hidden-memory: no front tab (Chromium missing? check debug.cef)")
        plan = [("chromium", i) for i in range(args.chromium)] + [("webkit", i) for i in range(args.webkit)]
        engine_of: dict[str, str] = {}
        tabs: list[str] = []

        def open_bench(engine: str, index: int):
            tab = open_tab(engine, bh.page_url(engine, index, ports))
            if tab:
                tabs.append(tab)
                engine_of[tab] = engine

        if args.webkit:
            open_bench(*plan.pop(args.chromium))  # WebKit's shared processes belong to the baseline
            app.run("tab.focus", target=front)
        time.sleep(10)  # test script: the engines' processes settle before the baseline
        before = bh.phase(pid, bundle, "baseline", args.measure, report)
        in_baseline = len(tabs)
        for engine, index in plan:
            open_bench(engine, index)
        app.run("tab.focus", target=front)
        opened_at = time.monotonic()
        status = bh.hibernation(sock)
        budget = status.get("page_budget")
        budget = args.budget if budget is None else int(budget)
        print(f"PERF-HIDDEN opened={len(tabs)} budget={budget} reported_budget={status.get('page_budget') is not None}", flush=True)
        # Agent grace (30 s after the last script call), the minute a page over the budget stays
        # hidden, then the planner's pace (2 pages per 5 s).
        done = bh.wait_for(lambda: len(live_hidden(sock, tabs)) <= budget, args.wait, 1)
        live = live_hidden(sock, tabs)
        settled_s = round(time.monotonic() - opened_at, 1)
        time.sleep(10)  # test script: renderers exit and the app settles
        after = bh.phase(pid, bundle, "hidden", args.measure, report)
        delta = round(after["total_footprint_mb"] - before["total_footprint_mb"], 1)
        added = max(len(tabs) - in_baseline, 1)
        per_tab = round(delta / added, 2)
        bound = round(budget * args.live_page_mb + added * args.max_mb_per_tab, 1)
        status = bh.hibernation(sock)
        print(f"PERF-HIDDEN live={len(live)} budget={budget} settled={bool(done)} settled_s={settled_s} "
              f"delta_mb={delta} bound_mb={bound} per_tab_mb={per_tab} hidden_live_pages={status.get('hidden_live_pages')} "
              f"snapshots={status.get('snapshots')} snapshot_bytes={status.get('snapshot_bytes')} "
              f"exemptions={json.dumps(status.get('exemptions') or {})}", flush=True)
        asleep = [t for t in tabs if t not in live][: args.wakes]
        for tab in asleep:
            report["wakes"].append(bh.wake(app, sock, tab, engine_of.get(tab, "?")))
            app.run("tab.focus", target=front)
            time.sleep(1)  # test script: the woken tab hides again before the next wake
        pictures = all(w.get("snapshot") for w in report["wakes"])
        checks = {"live": len(live) <= budget, "bounded": delta <= bound,
                  "picture": pictures if report["wakes"] else False}
        verdict = 0 if all(checks.values()) else 1
        report.update({"tabs": tabs, "budget": budget, "live": live, "delta_mb": delta, "bound_mb": bound,
                       "per_tab_mb": per_tab, "settled_s": settled_s,
                       "checks": checks, "pass": verdict == 0})
        mounted = [w.get("app_mounted_ms") for w in report["wakes"]]
        print(f"PERF-HIDDEN-RESULT {'PASS' if verdict == 0 else 'FAIL'} live={len(live)}/{budget} "
              f"delta_mb={delta}/{bound} per_tab_mb={per_tab} pictures={sum(1 for w in report['wakes'] if w.get('snapshot'))}/"
              f"{len(report['wakes'])} app_mounted_ms_p50={bh.percentile(mounted, 0.5)} checks={json.dumps(checks)}", flush=True)
    finally:
        app.run("quit")
        bm.wait_gone(pid, 20)
        bm.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=1)
            print(f"bench-hidden-memory: wrote {args.out}")
    return verdict


if __name__ == "__main__":
    sys.exit(main())
