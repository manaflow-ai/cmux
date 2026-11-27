#!/usr/bin/env python3
"""Chromium renderer processes per site (plans/cmux-next/tab-lifecycle.md, "Renderer sharing"):
how many renderers N Chromium tabs over S sites use, how much memory they hold, and how long a
new tab takes.

Chrome desktop shares one renderer between at most 2 main frames of the same site
(kProcessPerSiteUpToMainFrameThreshold, threshold 2), and above its soft process limit
(physical memory / 2 / 85 MB, at least 3) reuses a renderer of the same site; it never puts two
sites in one renderer. In cmux the below-limit sharing is blocked while any tab has a DevTools
agent (render_frame_host_manager.cc, WasEverAttachedToAnyFrame), so this bench prints what the
build does: renderers, tabs per renderer, footprint (renderers, app, total) and the shared split.

The sites are siteN.test on one local server. Chromium never shares a renderer for localhost or
an IP address (MainFrameProcessReuseAllowIPAndLocalhost is off), so the .test names are mapped
to 127.0.0.1 with --host-resolver-rules (CMUX_NEXT_CEF_EXTRA_SWITCHES: DEBUG builds of
development bundles only). Each page holds --heap-mb of touched memory, standing in for a site's
heap. Hibernation and freezing are off for the run, so every tab stays loaded.

Phases (each prints PERF-RENDERERS lines):
  open     tabs open one after another, round-robin over the sites, each in the foreground (one
           action.run with focus over the socket); new_tab_ms is from that call to the app reporting
           the page's title (the document is parsed; its heap script may still run)
  settled  --settle seconds after the last tab: renderers (all, and those that hold a tab: the
           spare renderer and extension renderers hold none), tabs per renderer, footprint

The run stops (exit 1) when the first tab or 3 tabs in a row show no title in time (the .test
mapping is not active: not a DEBUG dev build), and exits 1 when any tab was not timed.

Usage (a fleet GUI mini, never a laptop; a tagged DEV build):
  bench_renderer_sharing.py --app BUNDLE [--tabs 100] [--sites 20] [--heap-mb 20] [--settle 30] [--out FILE.json]
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import re
import resource
import shutil
import signal
import statistics
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402  (launch, App, sample, end_bundle, wait_gone)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)

PAGE = """<!doctype html><html><head><meta charset=utf-8><title>site {site} tab {tab}</title></head><body>
<h1>Renderer sharing bench: site {site}, tab {tab}</h1>{article}
<script>window.heap=new Uint8Array({heap}*1048576);for(let i=0;i<heap.length;i+=4096)heap[i]=i&255;</script>
</body></html>"""
ARTICLE = "<p>" + ("Same-site pages share a renderer up to a limit; other sites never do. " * 40) + "</p>"


class _Handler(http.server.BaseHTTPRequestHandler):
    heap_mb = 0

    def do_GET(self):  # noqa: N802
        host = (self.headers.get("Host") or "site0.test").split(":")[0]
        site = re.sub(r"\D", "", host.split(".")[0]) or "0"
        tab = re.sub(r"\D", "", self.path) or "0"
        body = PAGE.format(site=site, tab=tab, article=ARTICLE * 20, heap=self.heap_mb).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def serve() -> int:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


def title(sock: str, tab: str) -> str | None:
    """The tab's title from the app's own tab state (no script runs in the page)."""
    answer = bp.rpc(sock, "browser.page.state", {"tab": tab}, timeout=10)
    return None if answer.get("error") else answer.get("title")


def wait_title(sock: str, tab: str, expected: str, seconds: float) -> float | None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if title(sock, tab) == expected:
            return time.monotonic()
        time.sleep(0.01)  # test script: waiting on the app's reported page state
    return None


def renderer_map(sock: str) -> dict:
    """{renderer pid: [tab ids]} from the app's `resources` report (the hover cards' numbers)."""
    report = bp.rpc(sock, "resources", {"interval_ms": 100}, timeout=20)
    if report.get("error"):
        return {"error": report["error"]}
    owners: dict[int, list[str]] = {}
    for tab in report.get("tabs") or []:
        if tab.get("kind") != "chromium":
            continue
        for process in tab.get("processes") or []:
            if process.get("role") in (None, "renderer"):
                owners.setdefault(int(process["pid"]), []).append(tab["id"])
    for process in (report.get("shared") or {}).get("processes") or []:
        owners.setdefault(int(process["pid"]), [])
    return {"owners": owners, "report": report}


def percentile(values, q):
    values = sorted(v for v in values if v is not None)
    return values[min(len(values) - 1, int(len(values) * q))] if values else None


def chrome_soft_limit(memory_gb: float) -> int:
    """Chrome's soft renderer limit on this Mac (render_process_host_impl.cc GetMaxRendererProcessCount):
    physical memory / 2 / 85 MB, clamped to [3, half the process limit] (82 when that is unknown)."""
    soft = resource.getrlimit(resource.RLIMIT_NPROC)[0]
    platform = soft // 2 if 0 < soft < resource.RLIM_INFINITY else 82
    return min(max(3, int(memory_gb * 1024 / 2 / 85)), max(3, platform))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--tabs", type=int, default=100)
    parser.add_argument("--sites", type=int, default=20)
    parser.add_argument("--heap-mb", type=int, default=20)
    parser.add_argument("--settle", type=float, default=30)
    parser.add_argument("--load-timeout", type=float, default=30, help="seconds a new tab may take to show its title")
    parser.add_argument("--cef-switches", default="", help="more Chromium switches, colon-separated")
    parser.add_argument("--out")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("bench-renderer-sharing: macOS only (run it on a fleet GUI mini)")
    memory_gb = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30
    # The stand-in heaps are touched memory: at most a quarter of this Mac's.
    if args.tabs * args.heap_mb > memory_gb * 1024 / 4:
        raise SystemExit(f"bench-renderer-sharing: {args.tabs} tabs x {args.heap_mb} MB is more than a quarter of {memory_gb:.0f} GB")
    stopping = {"signal": False}

    def terminate(_signum, _frame):
        stopping["signal"] = True
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    _Handler.heap_mb = args.heap_mb
    port = serve()
    # No colon inside a switch: CMUX_NEXT_CEF_EXTRA_SWITCHES is colon-separated, so the rule maps
    # the host only and each URL keeps its port.
    switches = ["host-resolver-rules=MAP *.test 127.0.0.1"] + [s for s in args.cef_switches.split(":") if s]
    config = {"browser": {"hibernation": "off", "freezeHiddenTabs": "off", "keepNeighborTabsAwake": 0}}
    bundle = os.path.realpath(args.app)
    bp.wipe_state(bundle)
    extra = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": ":".join(switches)}
    # The fleet worker finds every process of the step by this marker, also those the app starts.
    if os.environ.get("CI_JOB_DIR"):
        extra["CI_JOB_DIR"] = os.environ["CI_JOB_DIR"]
    pid, sock, scratch = bm.launch(bundle, config, extra)
    limit = chrome_soft_limit(memory_gb)
    report = {"app": bundle, "tabs": args.tabs, "sites": args.sites, "heap_mb": args.heap_mb, "memory_gb": round(memory_gb, 1),
              "chrome_soft_limit": limit, "switches": switches, "opened": [], "new_tab_ms": []}
    status = 0
    try:
        app = bm.App(bundle, sock)
        print(f"PERF-RENDERERS-MACHINE memory_gb={memory_gb:.1f} chrome_soft_limit={limit} tabs={args.tabs} sites={args.sites}", flush=True)
        cef = bp.rpc(sock, "debug.cef") or {}
        if cef.get("unavailable") or cef.get("fallback"):
            raise SystemExit(f"bench-renderer-sharing: Chromium is not available: {json.dumps(cef)[:400]}")
        missed = 0
        for index in range(args.tabs):
            site = index % args.sites
            url = f"http://site{site}.test:{port}/{index}"
            started = time.monotonic()
            response = app.action("openBrowser.chromium", focus=True, url=url)
            created = [item for item in response.get("created", []) if str(item).startswith("tab_")]
            if response.get("error") or not created:
                print(f"   open {url}: {response.get('error') or response}", file=sys.stderr)
                missed += 1
            else:
                tab = created[0]
                shown = wait_title(sock, tab, f"site {site} tab {index}", args.load_timeout)
                elapsed = round((shown - started) * 1000) if shown else None
                report["opened"].append({"tab": tab, "site": site, "new_tab_ms": elapsed})
                report["new_tab_ms"].append(elapsed)
                missed = missed + 1 if elapsed is None else 0
            if (index == 0 and missed) or missed >= 3:
                raise SystemExit(f"bench-renderer-sharing: tab {index} did not open or show its title within {args.load_timeout} s "
                                 "(is this a DEBUG dev build, so the .test mapping applies?)")
            if index % 10 == 9:
                print(f"PERF-RENDERERS-OPEN tabs={index + 1} last_new_tab_ms={report['new_tab_ms'][-1] if report['new_tab_ms'] else None}", flush=True)
        time.sleep(args.settle)  # test script: let the pages and their renderers settle
        sample = bm.sample(pid, bundle, "settled", 1)
        mapping = renderer_map(sock)
        renderers = [row for row in sample["processes"] if row["kind"] == "cef-renderer"]
        owners = mapping.get("owners") or {}
        sharing = [len(owners.get(row["pid"], [])) for row in renderers]
        times = [t for t in report["new_tab_ms"] if t is not None]
        kinds = sample["kinds"]
        shared = ((mapping.get("report") or {}).get("shared") or {}).get("processes") or []
        result = {
            "renderers": len(renderers),
            "tab_renderers": sum(1 for n in sharing if n),
            "renderer_footprint_mb": round(sum(r["footprint_mb"] for r in renderers), 1),
            "app_footprint_mb": kinds.get("app", {}).get("footprint_mb"),
            "total_footprint_mb": sample["total_footprint_mb"],
            "tabs_per_renderer": {str(n): sharing.count(n) for n in sorted(set(sharing))},
            "max_tabs_in_one_renderer": max(sharing) if sharing else 0,
            "shared_mb": round(sum(p.get("memory_bytes", 0) for p in shared) / 2**20, 1),
            "new_tab_ms": {"p50": percentile(times, 0.5), "p95": percentile(times, 0.95), "max": max(times) if times else None,
                           "mean": round(statistics.mean(times)) if times else None, "timed": len(times)},
            "kinds": {k: {"n": v["count"], "footprint_mb": v["footprint_mb"]} for k, v in kinds.items()},
        }
        report["settled"] = result
        report["sample"] = sample
        print(f"PERF-RENDERERS phase=settled tabs={len(report['opened'])} sites={args.sites} renderers={result['renderers']} "
              f"tab_renderers={result['tab_renderers']} renderer_footprint_mb={result['renderer_footprint_mb']} "
              f"app_footprint_mb={result['app_footprint_mb']} total_footprint_mb={result['total_footprint_mb']} "
              f"shared_mb={result['shared_mb']} tabs_per_renderer={json.dumps(result['tabs_per_renderer'])} "
              f"max_tabs_in_one_renderer={result['max_tabs_in_one_renderer']} new_tab_p50_ms={result['new_tab_ms']['p50']} "
              f"new_tab_p95_ms={result['new_tab_ms']['p95']} new_tab_max_ms={result['new_tab_ms']['max']}", flush=True)
        for kind, entry in result["kinds"].items():
            print(f"PERF-RENDERERS-KIND kind={kind} n={entry['n']} footprint_mb={entry['footprint_mb']}")
        if len(times) < args.tabs:
            print(f"bench-renderer-sharing: only {len(times)} of {args.tabs} tabs were timed", file=sys.stderr)
            status = 1
    finally:
        # A cancelled step has seconds before SIGKILL: end the bundle's processes at once.
        if not stopping["signal"]:
            try:
                bm.App(bundle, sock).run("quit")
                bm.wait_gone(pid, 20)
            except Exception as error:  # noqa: BLE001  the quit failed; the processes are ended below
                print(f"   quit: {error}", file=sys.stderr)
        bm.end_bundle(bundle)
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=1)
        shutil.rmtree(scratch, ignore_errors=True)
        bp.wipe_state(bundle)
    sys.exit(status)


if __name__ == "__main__":
    main()
