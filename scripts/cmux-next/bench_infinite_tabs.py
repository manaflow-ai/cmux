#!/usr/bin/env python3
"""Infinite tabs on the Mac app: what 500 browser tabs, 200 workspaces and 100 agent chats cost once
most of them are hibernated, against the same app empty (cmuxterm-hq goals/infinite-tabs-flat.md).

Leo, 2026-11-22: "i also want us to keep pursuing the ability to have infinite fucking tabs and
workspaces and shit without getting starved of cpu/ram. having ultra awesome hibernation". Leo,
2026-11-12: "infinite everything feels like nothing" (every axis at most 1.2x empty).

scripts/measure/infinite-items.py runs the two daemons headless: no app, no page, no renderer. This
is the app's side of the same question, one launch:

  empty       the launched app with its first workspace, settled, then --measure idle seconds
  build       --workspaces workspaces, each with a terminal; the first --chats of them open on an agent
              chat whose first turn is answered (the acpmux test agent, --fake-agent); --tabs Chromium
              pages spread over them, each its own site (sN.localhost) with a --heap-mb stand-in heap,
              scrolled by script. A workspace is hibernated (Hibernate Workspace, then Hibernate Tab on
              any page still awake) once the build has moved --lag workspaces past it, so the machine
              never holds more than a few awake pages.
  full        a fresh empty workspace in front, everything else hibernated, settled, then --measure
              idle seconds
  switch      --wake hibernated pages shown again, one by one, each timed, then hidden again

Headlines (INFTABS lines, and one PERF_ROW JSON line each for the perf cron):
  memory_vs_empty      total RSS of every process the app owns at full over empty (the goal's check);
                       footprint_vs_empty is the same on physical footprint
  idle_cpu_pct, wakeups_per_s            at full, beside the empty app's own
  renderer_mb_per_tab  (Chromium renderer RSS at full - at empty) / tabs: a hibernated tab's renderer cost
  switch_mounted_ms    the app's own time from the restore to the page being back (debug.surfaces wakes)
  switch_live_ms       from the switch request to the page answering script with its scroll back
  switch_picture_ms    the app's own time from the restore to the pane holding the tab's last frame,
                       decoded (debug.surfaces wakes picture_ms; it draws in the next frame). Absent
                       for a wake whose placeholder showed none: no kept frame, or the page was back first
  snapshot_covered     the share of those wakes a kept last frame covered
INFTABS-KIND lines give each process kind at empty and full (count, RSS, footprint, CPU, wakeups).

Measurement only, never a gate. macOS only, a fleet Mac, never a laptop (DEV or bench build: it reads
debug.surfaces):
  bench_infinite_tabs.py --app BUNDLE --fake-agent cmux-tui/crates/acpmux/tests/fake_agent.py
      [--tabs 500] [--workspaces 200] [--chats 100] [--wake 20] [--measure 30] [--out FILE.json]
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
import bench_memory as bm  # noqa: E402
import bench_power as bp  # noqa: E402
import bench_workspace_hibernation as bw  # noqa: E402

ROWS: list[dict] = []
# A ratio's denominator is at least its noise floor (as infinite-items.py): an empty app at 0.00 % CPU divides by nothing.
CPU_FLOOR_PCT, WAKEUPS_FLOOR = 0.1, 1.0


def perf_row(name: str, value, unit: str, p95=None):
    if value is None:
        return
    row = {"name": f"infinite_tabs.mac.{name}", "p50": round(value, 4), "p95": round(value if p95 is None else p95, 4), "unit": unit}
    ROWS.append(row)
    print("PERF_ROW " + json.dumps(row), flush=True)


def hibernation(sock: str) -> dict:
    return bw.surfaces(sock).get("hibernation") or {}


def counts(sock: str) -> dict:
    status = bw.surfaces(sock)
    sleep = status.get("hibernation") or {}
    return {"live_terminals": status.get("live_terminals"), "parked_workspaces": status.get("parked_workspaces"),
            "hibernated_workspaces": status.get("hibernated_workspaces"), "workspace_pages": status.get("workspace_pages"),
            "hibernated_pages": len(sleep.get("hibernated") or []), "frozen_pages": len(sleep.get("frozen") or []),
            "chat_pages": len(sleep.get("chat_pages") or []), "snapshots": sleep.get("snapshots"),
            "snapshot_mb": round((sleep.get("snapshot_bytes") or 0) / 1048576, 1), "exemptions": len(sleep.get("exemptions") or {})}


def phase(pid: int, bundle: str, sock: str, label: str, items: int, seconds: float, report: dict) -> dict:
    result = bm.sample(pid, bundle, label, items, measure=seconds)
    result["app_counts"] = counts(sock)
    result["total_cpu_pct"] = round(sum(r.get("cpu_pct", 0.0) for r in result["processes"]), 3)
    result["total_wakeups_per_s"] = round(sum(r.get("wakeups_per_s", 0.0) for r in result["processes"]), 2)
    print(f"INFTABS-PHASE label={label} items={items} processes={len(result['processes'])} total_rss_mb={result['total_rss_mb']} "
          f"total_footprint_mb={result['total_footprint_mb']} idle_cpu_pct={result['total_cpu_pct']} "
          f"wakeups_per_s={result['total_wakeups_per_s']} counts={json.dumps(result['app_counts'])}", flush=True)
    report["phases"][label] = result
    return result


def new_workspace(app: bm.App) -> str | None:
    made = app.run("workspace.newAtBottom")
    workspace = next((str(i) for i in made.get("created", []) if str(i).startswith("ws_")), None)
    if workspace is None:
        print(f"   workspace.newAtBottom: {made.get('error') or made}", file=sys.stderr)
    return workspace


def build_workspace(app: bm.App, sock: str, chats: bm.FakeChats | None, index: int, urls: list[str]) -> dict | None:
    """One workspace, shown while it is built: a chat (the first --chats of them) or a terminal, then its pages."""
    if chats is not None:
        workspace = chats.open(index)
        kind = "chat"
    else:
        workspace = new_workspace(app)
        kind = "terminal"
    if workspace is None:
        return None
    app.action("goToWorkspace", workspace=workspace)
    if kind == "terminal":
        made = app.run("newSurface")
        if made.get("error"):
            print(f"   workspace {index}: terminal: {made['error']}", file=sys.stderr)
    pages = []
    for url in urls:
        # Shown, as a person's open is: a page opened behind (the CLI's script origin) is never on screen, so it
        # has no leave picture and hibernates with no last frame.
        opened = app.action("openBrowser.chromium", focus=True, url=url)
        page = bw.created_tab(opened)
        if page is None:
            print(f"   workspace {index}: no page for {url}: {opened.get('error') or opened}", file=sys.stderr)
            continue
        # The page answers script only once it loaded: a page hibernated before that has no last frame to keep.
        if bw.evaluate(sock, page, bw.SET_SCROLL) is None:
            print(f"   {page}: page did not answer", file=sys.stderr)
        pages.append({"tab": page, "url": url})
    return {"workspace": workspace, "kind": kind, "pages": pages}


def hibernate(app: bm.App, sock: str, entry: dict, tally: dict):
    """Hibernate Workspace, then Hibernate Tab on each of its pages that is still awake."""
    reply = app.run("workspace.hibernate", target=entry["workspace"])
    if reply.get("error"):
        tally["workspace_refused"] += 1
    tabs = {page["tab"] for page in entry["pages"]}
    if not tabs:
        return
    asleep = bw.wait_for(lambda: tabs <= set(hibernation(sock).get("hibernated") or []), 3, 0.25)
    if asleep:
        return
    for tab in sorted(tabs - set(hibernation(sock).get("hibernated") or [])):
        tally["tab_asked"] += 1
        if app.run("hibernateTab", target=tab).get("error"):
            tally["tab_refused"] += 1


def wake(app: bm.App, sock: str, entry: dict) -> dict:
    """Shows a hibernated workspace's last page and times it back: the app's own record and end to end."""
    page = entry["pages"][-1]
    before = hibernation(sock)
    restored = before.get("restored_total") or 0
    asleep = page["tab"] in (before.get("hibernated") or [])
    started = time.monotonic()
    app.action("goToWorkspace", workspace=entry["workspace"])
    app.run("tab.focus", target=page["tab"])
    mounted = bw.wait_for(lambda: (hibernation(sock).get("restored_total") or 0) > restored and time.monotonic(), 15, 0.01) if asleep else None
    live, got = None, {}
    state = bw.evaluate(sock, page["tab"], bw.READ_STATE)
    while state is not None:
        try:
            got = json.loads(state) if isinstance(state, str) else {}
        except ValueError:
            got = {}
        if abs((got.get("y") or 0) - bw.SCROLL_Y) <= 2:
            live = time.monotonic()
            break
        if time.monotonic() - started > 15:
            break
        time.sleep(0.02)  # test script: the page restores its scroll after it loads
        state = bw.evaluate(sock, page["tab"], bw.READ_STATE, 5)
    row = {"workspace": entry["workspace"], "tab": page["tab"], "kind": entry["kind"], "was_hibernated": asleep,
           "seen_mounted_ms": round((mounted - started) * 1000) if mounted else None,
           "live_ms": round((live - started) * 1000) if live else None,
           "scroll_ok": abs((got.get("y") or 0) - bw.SCROLL_Y) <= 2, "url_ok": got.get("href") == page["url"]}
    # The app's own record of the wake: restore to the page back, to its load ending, and the snapshot.
    own = bw.wait_for(lambda: next((w for w in reversed(hibernation(sock).get("wakes") or [])
                                    if w.get("tab") == page["tab"] and w.get("loaded_ms") is not None), None), 3) if asleep else None
    if own:
        row.update({"picture_ms": own.get("picture_ms"), "mounted_ms": own.get("mounted_ms"), "loaded_ms": own.get("loaded_ms"),
                    "snapshot": own.get("snapshot")})
    print(f"INFTABS-WAKE {json.dumps(row)}", flush=True)
    return row


def kinds_table(empty: dict, full: dict):
    for kind in sorted(set(empty["kinds"]) | set(full["kinds"]), key=lambda k: -full["kinds"].get(k, {}).get("rss_mb", 0)):
        e, f = empty["kinds"].get(kind, {}), full["kinds"].get(kind, {})
        print(f"INFTABS-KIND kind={kind} n={e.get('count', 0)}->{f.get('count', 0)} rss_mb={e.get('rss_mb', 0)}->{f.get('rss_mb', 0)} "
              f"footprint_mb={e.get('footprint_mb', 0)}->{f.get('footprint_mb', 0)} cpu_pct={e.get('cpu_pct', 0)}->{f.get('cpu_pct', 0)} "
              f"wakeups_per_s={e.get('wakeups_per_s', 0)}->{f.get('wakeups_per_s', 0)}", flush=True)


def summarize(args, report: dict, made: list[dict]) -> dict:
    empty, full = report["phases"]["empty"], report["phases"]["full"]
    pages = sum(len(entry["pages"]) for entry in made)
    rows = report["wakes"]
    woken = [r for r in rows if r["was_hibernated"]]
    renderer = lambda sample: sample["kinds"].get("cef-renderer", {})  # noqa: E731
    summary = {
        "tabs": pages, "workspaces": len(made), "chats": sum(1 for entry in made if entry["kind"] == "chat"),
        "rss_empty_mb": empty["total_rss_mb"], "rss_full_mb": full["total_rss_mb"],
        "memory_vs_empty": round(full["total_rss_mb"] / max(empty["total_rss_mb"], 1), 3),
        "footprint_empty_mb": empty["total_footprint_mb"], "footprint_full_mb": full["total_footprint_mb"],
        "footprint_vs_empty": round(full["total_footprint_mb"] / max(empty["total_footprint_mb"], 1), 3),
        "mb_per_item": round((full["total_rss_mb"] - empty["total_rss_mb"]) / max(1, pages + len(made)), 3),
        "idle_cpu_empty_pct": empty["total_cpu_pct"], "idle_cpu_pct": full["total_cpu_pct"],
        "idle_cpu_vs_empty": round(full["total_cpu_pct"] / max(empty["total_cpu_pct"], CPU_FLOOR_PCT), 2),
        "wakeups_empty_per_s": empty["total_wakeups_per_s"], "wakeups_per_s": full["total_wakeups_per_s"],
        "wakeups_vs_empty": round(full["total_wakeups_per_s"] / max(empty["total_wakeups_per_s"], WAKEUPS_FLOOR), 2),
        "processes_empty": len(empty["processes"]), "processes_full": len(full["processes"]),
        "renderers_empty": renderer(empty).get("count", 0), "renderers_full": renderer(full).get("count", 0),
        "renderer_rss_empty_mb": renderer(empty).get("rss_mb", 0), "renderer_rss_full_mb": renderer(full).get("rss_mb", 0),
        "renderer_mb_per_tab": round((renderer(full).get("rss_mb", 0) - renderer(empty).get("rss_mb", 0)) / max(1, pages), 4),
        "hibernated_pages": full["app_counts"]["hibernated_pages"], "hibernated_workspaces": full["app_counts"]["hibernated_workspaces"],
        "live_terminals": full["app_counts"]["live_terminals"], "chat_pages": full["app_counts"]["chat_pages"],
        "snapshot_mb": full["app_counts"]["snapshot_mb"],
        "switches": len(rows), "switches_hibernated": len(woken),
        "switch_picture_p50_ms": bw.percentile([r.get("picture_ms") for r in woken], 0.5),
        "switch_picture_p95_ms": bw.percentile([r.get("picture_ms") for r in woken], 0.95),
        "switch_pictures": sum(1 for r in woken if r.get("picture_ms") is not None),
        "switch_mounted_p50_ms": bw.percentile([r.get("mounted_ms") for r in woken], 0.5),
        "switch_mounted_p95_ms": bw.percentile([r.get("mounted_ms") for r in woken], 0.95),
        "switch_loaded_p50_ms": bw.percentile([r.get("loaded_ms") for r in woken], 0.5),
        "switch_loaded_p95_ms": bw.percentile([r.get("loaded_ms") for r in woken], 0.95),
        "switch_live_p50_ms": bw.percentile([r["live_ms"] for r in woken], 0.5),
        "switch_live_p95_ms": bw.percentile([r["live_ms"] for r in woken], 0.95),
        "snapshot_covered": sum(1 for r in woken if r.get("snapshot")),
        "restored": sum(1 for r in rows if r["scroll_ok"] and r["url_ok"]),
        "asked": {"tabs": args.tabs, "workspaces": args.workspaces, "chats": args.chats},
    }
    return summary


def run(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--tabs", type=int, default=500, help="Chromium pages, spread over the workspaces")
    parser.add_argument("--workspaces", type=int, default=200)
    parser.add_argument("--chats", type=int, default=100, help="workspaces that open on an answered agent chat (needs --fake-agent)")
    parser.add_argument("--fake-agent", metavar="SCRIPT", help="cmux-tui/crates/acpmux/tests/fake_agent.py")
    parser.add_argument("--heap-mb", type=int, default=20, help="each page's stand-in heap while it is awake")
    parser.add_argument("--lag", type=int, default=2, help="a workspace is hibernated once the build is this many past it")
    parser.add_argument("--wake", type=int, default=20, help="hibernated pages shown again and timed")
    parser.add_argument("--settle", type=float, default=45, help="seconds before each measured phase")
    parser.add_argument("--measure", type=float, default=30, help="idle seconds of CPU and wakeups in each phase")
    parser.add_argument("--config", default="{}", help="cmux.json settings merged over the run's own")
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                        help="an environment variable for the app (repeatable), e.g. CMUX_NEXT_TUI_TERMINAL_HOST_MODEL=holder")
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        raise SystemExit("bench-infinite-tabs: macOS only (a fleet Mac)")
    if args.chats and not args.fake_agent:
        raise SystemExit("bench-infinite-tabs: --chats needs --fake-agent")
    if args.chats > args.workspaces:
        raise SystemExit("bench-infinite-tabs: --chats is at most --workspaces (a chat opens as a workspace)")
    port = bw.serve(args.heap_mb)
    # Nothing hibernates on its own during the run (the bench asks, so the count is known); pages freeze as usual.
    config = bm.merged({"workspaces": {"hibernation": {"enabled": True, "idleMinutes": 10080}},
                        "browser": {"hibernation": "moderate", "keepNeighborTabsAwake": 0}}, json.loads(args.config))
    bundle = os.path.realpath(args.app)
    signal.signal(signal.SIGTERM, bm.interrupted)
    bp.wipe_state(bundle)
    if any("=" not in pair or not pair.split("=", 1)[0] for pair in args.env):
        raise SystemExit("bench-infinite-tabs: --env takes NAME=VALUE")
    extra_env = dict(pair.split("=", 1) for pair in args.env)
    pid, sock, scratch = bm.launch(bundle, config, extra_env=extra_env)
    app = bm.App(bundle, sock)
    report = {"app": bundle, "config": config, "phases": {}, "wakes": [],
              "asked": {"tabs": args.tabs, "workspaces": args.workspaces, "chats": args.chats, "heap_mb": args.heap_mb},
              "env": extra_env}
    made: list[dict] = []
    tally = {"workspace_refused": 0, "tab_asked": 0, "tab_refused": 0}
    status = 1
    pages_checked = False
    try:
        time.sleep(args.settle)  # test script: the launched app settles before its empty sample
        phase(pid, bundle, sock, "empty", 0, args.measure, report)
        chats = bm.FakeChats(app, bundle, args.fake_agent) if args.chats else None
        started = time.monotonic()
        for index in range(args.workspaces):
            # Tabs spread evenly: workspace i gets the pages whose number falls in its share.
            first, last = index * args.tabs // args.workspaces, (index + 1) * args.tabs // args.workspaces
            urls = [f"http://s{n}.localhost:{port}/?w={n}" for n in range(first, last)]
            entry = build_workspace(app, sock, chats if index < args.chats else None, index, urls)
            if entry:
                made.append(entry)
            # No page of the first ten asked opened: the app has no Chromium engine or refuses the open, and
            # the hour that follows would measure another mix. Stop here with the reason printed above.
            asked_pages = (index + 1) * args.tabs // args.workspaces
            if asked_pages >= 10 and not pages_checked:
                pages_checked = True
                if not any(e["pages"] for e in made):
                    print(f"bench-infinite-tabs: none of the first {asked_pages} pages opened; stopping", file=sys.stderr)
                    return 3
            if len(made) > args.lag and not made[-1 - args.lag].get("asked"):
                made[-1 - args.lag]["asked"] = True
                hibernate(app, sock, made[-1 - args.lag], tally)
            if (index + 1) % 20 == 0:
                now = bm.sample(pid, bundle, f"build-{index + 1}", index + 1)
                print(f"INFTABS-BUILD workspaces={index + 1} made={len(made)} pages={sum(len(e['pages']) for e in made)} "
                      f"elapsed_s={round(time.monotonic() - started)} total_rss_mb={now['total_rss_mb']} "
                      f"renderers={now['kinds'].get('cef-renderer', {}).get('count', 0)} counts={json.dumps(counts(sock))}", flush=True)
        front = new_workspace(app)
        if front:
            app.action("goToWorkspace", workspace=front)
        for entry in made:
            if not entry.get("asked"):
                entry["asked"] = True
                hibernate(app, sock, entry, tally)
        report["build_s"] = round(time.monotonic() - started)
        report["hibernate_tally"] = tally
        print(f"INFTABS-BUILT workspaces={len(made)} pages={sum(len(e['pages']) for e in made)} build_s={report['build_s']} "
              f"hibernate={json.dumps(tally)}", flush=True)
        time.sleep(args.settle)  # test script: renderers exit, idle agents hibernate, the app settles
        # Who runs in the idle window (the app's wakeup ledger, its threads' CPU, Chromium's pump counters, live
        # pages, a stack sample after it), and where the biggest kinds keep their memory: the numbers a fix starts from.
        attribution = bm.Attribution(app, pid, bundle, kinds=("app", "cef-gpu"))
        pump_before = (app.call("debug.cef", timeout=30) or {}).get("pump") or {}
        attribution.start()
        full = phase(pid, bundle, sock, "full", len(made) + sum(len(e["pages"]) for e in made), args.measure, report)
        found = attribution.finish()
        pump_after = (app.call("debug.cef", timeout=30) or {}).get("pump") or {}
        pump = {key: round(value - pump_before.get(key, 0), 3) for key, value in pump_after.items()
                if isinstance(value, (int, float)) and not isinstance(value, bool)}
        report["full_attribution"] = {**found, "pump_delta": pump}
        bm.print_attribution("full", found)
        print(f"PERF-ATTR full pump window_s={found['window_s']} delta={json.dumps(pump)}", flush=True)
        kinds_table(report["phases"]["empty"], full)
        bm.print_vmmap(full, "app,cef-renderer,tui-daemon")
        with_pages = [entry for entry in made if entry["pages"]]
        step = max(1, len(with_pages) // max(1, args.wake))
        for entry in with_pages[::step][: args.wake]:
            report["wakes"].append(wake(app, sock, entry))
            if front:
                app.action("goToWorkspace", workspace=front)
            time.sleep(1)  # test script: the woken workspace is hidden again before the next switch
        summary = summarize(args, report, made)
        report["summary"] = summary
        print("INFTABS-SUMMARY " + " ".join(f"{k}={json.dumps(v) if isinstance(v, dict) else v}" for k, v in summary.items()), flush=True)
        perf_row("memory_vs_empty", summary["memory_vs_empty"], "x")
        perf_row("footprint_vs_empty", summary["footprint_vs_empty"], "x")
        perf_row("rss_empty_mb", summary["rss_empty_mb"], "MB")
        perf_row("rss_full_mb", summary["rss_full_mb"], "MB")
        perf_row("idle_cpu_pct", summary["idle_cpu_pct"], "%")
        perf_row("idle_cpu_empty_pct", summary["idle_cpu_empty_pct"], "%")
        perf_row("wakeups_per_s", summary["wakeups_per_s"], "1/s")
        perf_row("wakeups_empty_per_s", summary["wakeups_empty_per_s"], "1/s")
        perf_row("renderer_mb_per_tab", summary["renderer_mb_per_tab"], "MB")
        if summary["switch_pictures"]:
            perf_row("switch_picture_ms", summary["switch_picture_p50_ms"], "ms", summary["switch_picture_p95_ms"])
        perf_row("switch_mounted_ms", summary["switch_mounted_p50_ms"], "ms", summary["switch_mounted_p95_ms"])
        perf_row("switch_live_ms", summary["switch_live_p50_ms"], "ms", summary["switch_live_p95_ms"])
        if summary["switches_hibernated"]:
            perf_row("snapshot_covered_pct", 100 * summary["snapshot_covered"] / summary["switches_hibernated"], "%")
        print("PERF_REPORT " + json.dumps({"rows": ROWS}), flush=True)
        # A run that built under 90 % of what was asked measured another mix: say so with the exit code.
        built = summary["tabs"] >= 0.9 * args.tabs and summary["workspaces"] >= 0.9 * args.workspaces and summary["chats"] >= 0.9 * args.chats
        status = 0 if built else 3
    finally:
        app.run("quit")
        bm.wait_gone(pid, 20)
        bm.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=1)
            print(f"bench-infinite-tabs: wrote {args.out}")
    return status


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
