#!/usr/bin/env python3
"""What workspace hibernation frees, and how a hibernated workspace comes back
(plans/cmux-next/workspace-hibernation-DESIGN.md).

Opens --workspaces workspaces, each with a terminal (a marker line printed
after 400 lines of output) and a Chromium page on its own local site with a
--heap-mb stand-in heap, scrolled by script. Every workspace is shown once, so
the window keeps it mounted, then a fresh workspace is shown in front:

  awake       every bench workspace mounted off screen (its pages frozen at most)
  hibernated  after Hibernate Workspace on each

Each phase prints the footprint and RSS of every process the app owns, by kind,
and the app's own counts (live terminals, renderers, parked and hibernated
workspaces). Then --wake workspaces are shown again, one by one, and timed:

  page_mounted_ms   until the page is restored (debug.surfaces restored_total)
  page_usable_ms    until the page answers script, with its scroll back
  terminal_ms       until the terminal shows its marker again (tab.focus to text)

A wake passes when the page has its URL and scroll and the terminal its marker.
macOS only: run it through scripts/measure/tab-hibernation.sh --arg=--workspaces=50
(bench_hibernation.py hands --workspaces to this file), never on a laptop.
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
import bench_memory as bm  # noqa: E402
import bench_power as bp  # noqa: E402

SCROLL_Y = 900
SET_SCROLL = f"(() => {{ window.scrollTo(0, {SCROLL_Y}); return String(window.scrollY); }})()"
READ_STATE = "JSON.stringify({y: Math.round(window.scrollY), href: location.href})"


def serve(heap_mb: int) -> int:
    article = "".join(f"<p>{'workspace hibernation bench ' * 30}</p>" for _ in range(200))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            body = (f"<!doctype html><title>{self.path}</title><body>{article}"
                    f"<script>window.heap = new Array({heap_mb} * 131072).fill(1.5);</script></body>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


def surfaces(sock: str, text: bool = False) -> dict:
    return bp.rpc(sock, "debug.surfaces", {"text": True} if text else {}) or {}


def wait_for(predicate, seconds: float, step: float = 0.05):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test script: waiting on the app's reported state
    return None


def evaluate(sock: str, tab: str, script: str, seconds: float = 20):
    deadline = time.monotonic() + seconds
    while True:
        answer = bp.rpc(sock, "browser.page.eval", {"tab": tab, "script": script}, timeout=seconds)
        if not answer.get("error"):
            return answer.get("value")
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.02)  # test script: the page is still loading


def created_tab(response: dict) -> str | None:
    return next((str(item) for item in response.get("created", []) if str(item).startswith("tab_")), None)


def phase(pid: int, bundle: str, sock: str, label: str, count: int, report: dict) -> dict:
    result = bm.sample(pid, bundle, label, count)
    status = surfaces(sock)
    result["app_counts"] = {key: status.get(key) for key in ("live_terminals", "parked_workspaces", "hibernated_workspaces", "workspace_pages",
                                                             "workspaces_hibernated_total")}
    kinds = result["kinds"]
    print(f"PERF-WSHIB-PHASE label={label} workspaces={count} total_footprint_mb={result['total_footprint_mb']} "
          f"total_rss_mb={result['total_rss_mb']} app_footprint_mb={kinds.get('app', {}).get('footprint_mb')} "
          f"renderers={kinds.get('cef-renderer', {}).get('count', 0)} "
          f"renderer_footprint_mb={kinds.get('cef-renderer', {}).get('footprint_mb', 0)} "
          f"counts={json.dumps(result['app_counts'])}", flush=True)
    report["phases"].append(result)
    return result


def percentile(values, q):
    values = sorted(v for v in values if v is not None)
    return values[min(len(values) - 1, int(q * len(values)))] if values else None


def wake(app: bm.App, sock: str, entry: dict, port: int) -> dict:
    before = surfaces(sock).get("hibernation") or {}
    restored = before.get("restored_total") or 0
    asleep = entry["page"] in (before.get("hibernated") or [])
    app.action("goToWorkspace", workspace=entry["workspace"])
    # The workspace shows the tab it showed last; the page is timed from its own show (its pane may
    # show the terminal, which the terminal timing below covers).
    started = time.monotonic()
    app.run("tab.focus", target=entry["page"])
    # A page that stayed awake has nothing to restore: waiting for a restore would time the wait, not the wake.
    mounted = wait_for(lambda: ((surfaces(sock).get("hibernation") or {}).get("restored_total") or 0) > restored and time.monotonic(), 15) if asleep else None
    usable, got = None, {}
    state = evaluate(sock, entry["page"], READ_STATE)
    while state is not None:
        got = json.loads(state) if isinstance(state, str) else {}
        if abs((got.get("y") or 0) - SCROLL_Y) <= 2 or time.monotonic() - started > 15:
            usable = time.monotonic()
            break
        time.sleep(0.02)  # test script: the page restores its scroll after it loads
        state = evaluate(sock, entry["page"], READ_STATE, 5)
    term_started = time.monotonic()
    app.run("tab.focus", target=entry["terminal"])

    def marker_shown():
        for window in surfaces(sock, text=True).get("windows") or []:
            for pane in window.get("panes") or []:
                if entry["marker"] in (pane.get("text") or ""):
                    return time.monotonic()
        return None

    shown = wait_for(marker_shown, 15)
    row = {"workspace": entry["workspace"],
           "page_mounted_ms": round((mounted - started) * 1000) if mounted else None,
           "page_usable_ms": round((usable - started) * 1000) if usable else None,
           "terminal_ms": round((shown - term_started) * 1000) if shown else None,
           "page_was_hibernated": asleep,
           "scroll_ok": abs((got.get("y") or 0) - SCROLL_Y) <= 2,
           "url_ok": got.get("href") == entry["url"],
           "terminal_ok": shown is not None}
    print(f"PERF-WSHIB-WAKE {json.dumps(row)}", flush=True)
    return row


def run(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--workspaces", type=int, default=50)
    parser.add_argument("--wake", type=int, default=12, help="workspaces shown again and timed")
    parser.add_argument("--heap-mb", type=int, default=40)
    parser.add_argument("--out")
    args, _ignored = parser.parse_known_args(argv)  # tab-hibernation.sh's own flags (--tabs, --pressure...) do not apply
    if sys.platform != "darwin":
        raise SystemExit("bench-workspace-hibernation: macOS only (a fleet or capture mini)")
    port = serve(args.heap_mb)
    # Nothing hibernates on its own during the run (the bench asks); pages freeze as usual.
    config = {"workspaces": {"hibernation": {"enabled": True, "idleMinutes": 10080}}, "browser": {"keepNeighborTabsAwake": 0}}
    bundle = os.path.realpath(args.app)
    signal.signal(signal.SIGTERM, bm.interrupted)
    bp.wipe_state(bundle)
    pid, sock, scratch = bm.launch(bundle, config)
    app = bm.App(bundle, sock)
    report = {"app": bundle, "workspaces": args.workspaces, "heap_mb": args.heap_mb, "config": config, "phases": [], "wakes": []}
    made: list[dict] = []
    try:
        for index in range(args.workspaces):
            created = app.run("workspace.newAtBottom")
            workspace = next((str(i) for i in created.get("created", []) if str(i).startswith("ws_")), None)
            if workspace is None:
                print(f"   workspace {index}: {created}", file=sys.stderr)
                continue
            app.action("goToWorkspace", workspace=workspace)
            terminal = created_tab(app.run("newSurface"))
            # The typed command does not contain the marker (printf builds it), so only its output shows it.
            marker = f"WSHIB-{index}-DONE"
            if terminal:
                bp.rpc(sock, "action.run", {"action": "terminal.sendText", "target": f"tab:{terminal}",
                                            "args": {"text": f"seq 1 400; printf 'WSHIB-%s-DONE\\n' {index}\r"}})
            url = f"http://s{index}.localhost:{port}/?w={index}"
            page = created_tab(app.run("openBrowser.chromium", url=url))
            if page is None or terminal is None:
                print(f"   workspace {index}: terminal={terminal} page={page}", file=sys.stderr)
                continue
            if evaluate(sock, page, SET_SCROLL) is None:
                print(f"   {page}: page did not answer", file=sys.stderr)
            made.append({"workspace": workspace, "terminal": terminal, "page": page, "url": url, "marker": marker})
        front = app.run("workspace.newAtBottom")
        front_ws = next((str(i) for i in front.get("created", []) if str(i).startswith("ws_")), None)
        if front_ws:
            app.action("goToWorkspace", workspace=front_ws)
        report["made"] = len(made)
        time.sleep(45)  # test script: pages load and freeze, the app settles
        awake = phase(pid, bundle, sock, "awake", len(made), report)
        phases = (surfaces(sock).get("hibernation") or {}).get("page_phases") or {}
        counted = {}
        for entry in made:
            name = phases.get(entry["page"], "gone")
            counted[name] = counted.get(name, 0) + 1
        report["page_phases_before"] = counted
        print(f"PERF-WSHIB-PAGE-PHASES before={json.dumps(counted)}", flush=True)
        started = time.monotonic()
        refused = 0
        for entry in made:
            reply = app.run("workspace.hibernate", target=entry["workspace"])
            refused += 1 if reply.get("error") else 0
        hibernated = wait_for(lambda: (surfaces(sock).get("hibernated_workspaces") or 0) >= len(made) - refused, 60, 0.25)
        report["hibernate_all_ms"] = round((time.monotonic() - started) * 1000)
        status = surfaces(sock)
        report["exemptions"] = (status.get("hibernation") or {}).get("exemptions")
        print(f"PERF-WSHIB-HIBERNATED all={bool(hibernated)} refused={refused} ms={report['hibernate_all_ms']} "
              f"exemptions={json.dumps(report['exemptions'] or {})}", flush=True)
        time.sleep(15)  # test script: renderers exit and the app settles
        asleep = phase(pid, bundle, sock, "hibernated", len(made), report)
        for entry in made[: args.wake]:
            report["wakes"].append(wake(app, sock, entry, port))
            if front_ws:
                app.action("goToWorkspace", workspace=front_ws)
            time.sleep(1)  # test script: the woken workspace is hidden again before the next wake
        rows = report["wakes"]
        summary = {
            "workspaces": len(made),
            "footprint_awake_mb": awake["total_footprint_mb"], "footprint_hibernated_mb": asleep["total_footprint_mb"],
            "freed_mb": round(awake["total_footprint_mb"] - asleep["total_footprint_mb"], 1),
            "freed_mb_per_workspace": round((awake["total_footprint_mb"] - asleep["total_footprint_mb"]) / max(1, len(made)), 1),
            "rss_awake_mb": awake["total_rss_mb"], "rss_hibernated_mb": asleep["total_rss_mb"],
            "app_footprint_awake_mb": awake["kinds"].get("app", {}).get("footprint_mb"),
            "app_footprint_hibernated_mb": asleep["kinds"].get("app", {}).get("footprint_mb"),
            "renderers_awake": awake["kinds"].get("cef-renderer", {}).get("count", 0),
            "renderers_hibernated": asleep["kinds"].get("cef-renderer", {}).get("count", 0),
            "page_mounted_p50_ms": percentile([r["page_mounted_ms"] for r in rows], 0.5),
            "page_usable_p50_ms": percentile([r["page_usable_ms"] for r in rows], 0.5),
            "page_usable_p95_ms": percentile([r["page_usable_ms"] for r in rows], 0.95),
            "terminal_p50_ms": percentile([r["terminal_ms"] for r in rows], 0.5),
            "terminal_p95_ms": percentile([r["terminal_ms"] for r in rows], 0.95),
            "pages_hibernated": sum(1 for r in rows if r["page_was_hibernated"]),
            "restored": sum(1 for r in rows if r["scroll_ok"] and r["url_ok"] and r["terminal_ok"]), "woken": len(rows),
        }
        report["summary"] = summary
        print("PERF-WSHIB-SUMMARY " + " ".join(f"{k}={v}" for k, v in summary.items()), flush=True)
    finally:
        app.run("quit")
        bm.wait_gone(pid, 20)
        bm.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=1)
            print(f"bench-workspace-hibernation: wrote {args.out}")
    summary = report.get("summary") or {}
    return 0 if summary and summary["restored"] == summary["woken"] else 1


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
