#!/usr/bin/env python3
"""Chromium renderer processes per site (plans/cmux-next/tab-lifecycle.md, "Renderer sharing"):
how many renderers N Chromium tabs over S sites use, how much memory they hold, and how long a
new tab takes.

Chrome desktop shares one renderer between at most 2 main frames of the same site
(kProcessPerSiteUpToMainFrameThreshold, threshold 2), and above its soft process limit
(physical memory / 2 / 85 MB, at least 3) reuses a renderer of the same site; it never puts two
sites in one renderer. Chromium 154 turns the below-limit sharing off for the whole browser once
any frame ever had a DevTools agent (render_frame_host_manager.cc, WasEverAttachedToAnyFrame);
from fork API 29 the app passes cmux-process-reuse-per-renderer-devtools (CEFSwitches), so only a
renderer with an agent is never shared. This bench prints what the build does: renderers, tabs
per renderer, same-site main frames per renderer, footprint (renderers, app, total) and the
shared split.

The sites are siteN.test on one local server. Chromium never shares a renderer for localhost or
an IP address (MainFrameProcessReuseAllowIPAndLocalhost is off), so the .test names are mapped
to 127.0.0.1 with --host-resolver-rules (CMUX_NEXT_BENCH_CEF_SWITCHES: Debug and bench builds of
development bundles only). Each page holds --heap-mb of touched memory, standing in for a site's
heap. Hibernation and freezing are off for the run, so every tab stays loaded.

--agent-cdp (scripts/measure/renderer-sharing.sh passes it) attaches an agent's CDP session to the
first tab once it shows, as an agent that drives the tab does: a named cef session of the app's
own browser host (`cmux-browser-host eval --session ... --engine cef`, `tabs.use(<tab>)`), kept
open until the run ends. The run then fails (exit 1) when the app did not pass
cmux-process-reuse-per-renderer-devtools (debug.cef windows.process_reuse_per_renderer_devtools),
when a site with 2 or more of the bench's tabs (the agent's apart) has no renderer that holds 2 of
them while the shared layout fits below the renderer limit, when a renderer holds more than 2 main
frames of one site or the agent's renderer holds another tab below the limit, and at any count when
a renderer holds two sites (plans/cmux-next/chrome-parity/p07-memory.md, task 046 and DC9). So a
build where the agent's session turns sharing off for the whole browser (no switch, fork API < 29)
fails: every tab in its own renderer is no sharing, not a pass.

Phases (each prints PERF-RENDERERS lines):
  open    tabs open one after another, round-robin over the sites, each in the foreground (one
           action.run with focus over the socket); new_tab_ms is from that call to the app reporting
           the page's title (the document is parsed; its heap script may still run)
  settled  --settle seconds after the last tab: renderers (all, and those that hold a tab: the
           spare renderer and extension renderers hold none), tabs per renderer, footprint

--memory-cap-mb MB (p07-memory task 111) starts Chromium with that cap as
cmux-shared-renderer-memory-limit (Chrome's kProcessPerSiteMainFrameTotalMemoryLimit, 2 GiB, which the app's
budget passes otherwise) through the bench switch list, and adds a phase before the open phase:
  grown    a tab of a site the open phase does not use holds a heap of the cap + --grow-margin-mb, so its
           renderer's footprint is past the cap (render_process_host_impl.cc HasEnoughMemoryForAnotherMainFrame:
           footprint plus 1.5 times the footprint per main frame must stay under it); after --settle-grown seconds
           a second tab of that site opens. It runs while the browser holds only these tabs, far below the
           renderer limit, where the second tab must get another renderer; in the same one the run fails. At or
           over the limit Chrome reuses the renderer whatever its footprint, so the rule is not tested and the run
           fails as inconclusive. Both tabs then close, and the open phase starts as it would without the cap.

The run stops (exit 1) when the first tab or 3 tabs in a row show no title in time (the .test
mapping is not active: not a Debug or bench dev build), and exits 1 when any tab was not timed.

The app starts through bench_launch.BenchApp (the lab's bench env, a scratch config, an empty
saved session for the tag) and ends with its tag. new_tab_ms percentiles (p50/p95/p99) are
scripts/perf-lab/perf_stats.py's (linear interpolation). --out FILE.json is the report; --out DIR
(the lab runner's folder) also gets one cmux-perf-result/v1 file per series through
BenchApp.record (browser_engine_bench_report.py, `renderer_sharing.*`, story renderer-sharing)
and the report as DIR/bench-renderer-sharing.json.

Usage (a fleet GUI mini, never a laptop; a tagged DEV build, Debug or bench config):
  bench_renderer_sharing.py --app BUNDLE [--tabs 100] [--sites 20] [--heap-mb 20] [--settle 30] [--agent-cdp]
      [--renderer-limit N] [--memory-cap-mb MB [--grow-margin-mb 64] [--settle-grown 10]] [--out FILE.json | --out DIR]
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import re
import resource
import signal
import statistics
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402  (App, sample, end_bundle, note_child_launch)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)
import browser_engine_bench_report as results  # noqa: E402
from bench_launch import BenchApp, tag_of  # noqa: E402

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
        url = urlsplit(self.path)
        tab = re.sub(r"\D", "", url.path) or "0"
        body = PAGE.format(site=site, tab=tab, article=ARTICLE * 20, heap=page_heap_mb(url.query, self.heap_mb)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def page_heap_mb(query: str, default: int) -> int:
    """The page's heap: `?heap=MB` (the grown phase's page past the cap), else the run's --heap-mb."""
    value = (parse_qs(query).get("heap") or [""])[0]
    return int(value) if value.isdigit() else default


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


def chrome_soft_limit(memory_gb: float) -> int:
    """Chrome's soft renderer limit on this Mac (render_process_host_impl.cc GetMaxRendererProcessCount):
    physical memory / 2 / 85 MB, clamped to [3, half the process limit] (82 when that is unknown)."""
    soft = resource.getrlimit(resource.RLIMIT_NPROC)[0]
    platform = soft // 2 if 0 < soft < resource.RLIM_INFINITY else 82
    return min(max(3, int(memory_gb * 1024 / 2 / 85)), max(3, platform))


# Chrome's main-frame threshold for one renderer below the process limit
# (content/public/common/content_features.cc kProcessPerSiteUpToMainFrameThreshold, threshold 2).
SAME_SITE_MAIN_FRAME_THRESHOLD = 2
# The fork API with cmux-process-reuse-per-renderer-devtools (CEFForkFeatures.rendererPathsForkAPI).
RENDERER_PATHS_FORK_API = 29
AGENT_SESSION = "rsharing-agent"


def host_socket(rows, bundle: str) -> str | None:
    """The agent socket of the bundle's browser host, from its `serve` command line: the daemon starts
    `<bundle>/Contents/Resources/bin/cmux-browser-host serve ... --socket PATH` with `--socket` last
    (cmux-tui-core browser_host.rs), so the path is the rest of the line, spaces included."""
    for _pid, _ppid, cmd in rows:
        relative = bm.in_bundle(cmd, bundle)
        if not relative or not relative.startswith("/Contents/Resources/bin/cmux-browser-host serve"):
            continue
        found = re.search(r" --socket (.+)$", relative)
        if found:
            return found.group(1)
    return None


def agent_script(tab: str, url: str) -> str:
    """REPL code that claims `tab` for the session (the app's relay then opens the tab's DevTools session,
    AppDevToolsRelay.prepareRelay) and reads its title over CDP; `url` finds the tab when the host lists it
    under another id. The first claim of a tab rebuilds its page for the agent, and neither the relay nor the
    CDP attach waits for the document, so the title is read once `url` committed and loaded again."""
    return "\n".join([
        "const all = await tabs.list({ all: true });",
        f"const hit = all.find((t) => t.id === {json.dumps(tab)}) || all.find((t) => t.url === {json.dumps(url)});",
        f"if (!hit) throw new Error('no tab ' + {json.dumps(tab)});",
        "const driven = await tabs.use(hit.id);",
        f"await driven.waitForURL({json.dumps(url)}, {{ waitUntil: 'load' }});",
        "console.log(JSON.stringify({ id: hit.id, title: await driven.title() }));",
    ])


def host_cli_env(socket: str, daemon_socket: str) -> dict:
    """The environment of a daemon's terminal: the CLI starts no host of its own on a socket the daemon owns
    (cmux-browser-host.rs daemon_owns needs both variables) and waits for the daemon's host instead."""
    return dict(os.environ, CMUX_BROWSER_HOST_SOCKET=socket, CMUX_TUI_SOCKET=daemon_socket)


def host_cli(bundle: str, socket: str, daemon_socket: str, *argv: str, timeout: float = 60) -> subprocess.CompletedProcess:
    """The bundled browser host CLI against the app's host (`socket`, owned by the app's daemon at `daemon_socket`)."""
    cli = os.path.join(bundle, "Contents/Resources/bin/cmux-browser-host")
    return subprocess.run([cli, *argv, "--socket", socket], capture_output=True, text=True, timeout=timeout,
                          env=host_cli_env(socket, daemon_socket))


def attach_agent(bundle: str, daemon_socket: str, tab: str, url: str, expected_title: str, seconds: float = 60) -> dict:
    """Opens the agent's CDP session on `tab` and keeps it: {"socket", "session", "tab"} or {"error"}."""
    deadline = time.monotonic() + seconds
    socket = host_socket(bm.process_table(), bundle)
    while socket is None and time.monotonic() < deadline:
        time.sleep(0.5)  # test script: waiting for the daemon to start its browser host
        socket = host_socket(bm.process_table(), bundle)
    if socket is None:
        return {"error": f"no browser host of {bundle} runs"}
    out = host_cli(bundle, socket, daemon_socket, "eval", "--session", AGENT_SESSION, "--engine", "cef", agent_script(tab, url),
                   timeout=max(5.0, deadline - time.monotonic()))
    if out.returncode != 0 or expected_title not in out.stdout:
        return {"error": (out.stderr or out.stdout).strip()[:400] or f"exit {out.returncode}", "socket": socket}
    return {"socket": socket, "session": AGENT_SESSION, "tab": tab}


def site_sharing(owners: dict, site_of: dict, agent_tab: str | None, limit: int, renderers: int,
                 require_sharing: bool = False) -> dict:
    """Per renderer, how many main frames of each site it holds, and which of Chrome's rules the build breaks:
    a renderer never holds two sites (render_process_host_impl.cc IsSuitableHost, site isolation); below the
    limit at most SAME_SITE_MAIN_FRAME_THRESHOLD main frames of one site share one; a renderer with a DevTools
    agent takes no other main frame (the fork's per-renderer check). Tabs the bench did not open do not count.

    `renderers` is every Chromium renderer of the run (extension, internal and spare ones too): Chrome's limit
    check counts them all (RenderProcessHostImpl::IsProcessLimitReached), so the over-sharing rules apply only
    below that count. With `require_sharing` (an agent's session is open) every site with 2 or more of the
    bench's tabs, the agent's apart, needs a renderer that holds 2 of them whenever the shared layout fits below
    the limit. That uses the layout's renderer count, not the observed one, which a build that never shares
    inflates past the limit."""
    per_renderer: dict = {}
    for renderer, tabs in owners.items():
        counts: dict = {}
        for tab in tabs:
            if tab in site_of:
                counts[site_of[tab]] = counts.get(site_of[tab], 0) + 1
        if counts:
            per_renderer[renderer] = counts
    below_limit = renderers < limit
    max_same_site = max((max(counts.values()) for counts in per_renderer.values()), default=0)
    mixed = sum(1 for counts in per_renderer.values() if len(counts) > 1)
    agent_renderer = next((r for r, tabs in owners.items() if agent_tab and agent_tab in tabs), None)
    agent_renderer_tabs = sum(per_renderer.get(agent_renderer, {}).values()) if agent_renderer is not None else None
    # The tabs Chrome's sharing applies to: every bench tab with a renderer, the agent's apart.
    tabs_per_site: dict = {}
    for tab in {tab for tabs in owners.values() for tab in tabs if tab in site_of and tab != agent_tab}:
        tabs_per_site[site_of[tab]] = tabs_per_site.get(site_of[tab], 0) + 1
    shared_layout = (renderers - len(per_renderer) + (1 if agent_renderer is not None else 0)
                     + sum(-(-n // SAME_SITE_MAIN_FRAME_THRESHOLD) for n in tabs_per_site.values()))
    sharing_sites = {site for renderer, counts in per_renderer.items() if renderer != agent_renderer
                     for site, n in counts.items() if n >= SAME_SITE_MAIN_FRAME_THRESHOLD}
    multi_tab_sites = [site for site, n in tabs_per_site.items() if n >= SAME_SITE_MAIN_FRAME_THRESHOLD]
    unshared = sorted(site for site in multi_tab_sites if site not in sharing_sites)
    violations = []
    if require_sharing and shared_layout < limit and unshared:
        violations.append(f"{len(unshared)} of {len(multi_tab_sites)} sites with 2 or more tabs share no renderer with the "
                          f"agent's session open (sharing needs {shared_layout} renderers, below the limit of {limit})")
    if mixed:
        violations.append(f"{mixed} renderers hold main frames of two sites")
    if below_limit and max_same_site > SAME_SITE_MAIN_FRAME_THRESHOLD:
        violations.append(f"a renderer holds {max_same_site} main frames of one site below the limit of {limit}")
    if below_limit and agent_renderer_tabs is not None and agent_renderer_tabs > 1:
        violations.append(f"the agent's renderer holds {agent_renderer_tabs} tabs")
    return {
        "tab_renderers": len(per_renderer),
        "renderers": renderers,
        "renderer_limit": limit,
        "below_limit": below_limit,
        "shared_layout_renderers": shared_layout,
        "max_same_site_main_frames": max_same_site,
        "shared_renderers": sum(1 for counts in per_renderer.values() if sum(counts.values()) > 1),
        "mixed_site_renderers": mixed,
        "unshared_sites": unshared,
        "agent_renderer_tabs": agent_renderer_tabs,
        "violations": violations,
    }


# The fork's main-frame cap switch (CEFSharedRendererMemoryCaps.mainFrameSwitch), in bytes.
MEMORY_CAP_SWITCH = "cmux-shared-renderer-memory-limit"


def memory_cap_switch(cap_mb: int) -> str:
    """The bench switch that sets the fork's main-frame cap to `cap_mb` MiB."""
    return f"{MEMORY_CAP_SWITCH}={cap_mb << 20}"


def grown_check(owners: dict, grown_tab: str, next_tab: str, renderers: int, limit: int) -> dict:
    """The grown phase: `grown_tab`'s renderer is past the cap, so `next_tab` (its site) must be in another
    renderer (render_process_host_impl.cc HasEnoughMemoryForAnotherMainFrame). Chrome reuses a same-site
    renderer at the limit whatever its footprint (IsProcessLimitReached, GetExistingProcessHost), so the rule
    holds only below it."""
    renderer_of = {tab: renderer for renderer, tabs in owners.items() for tab in tabs}
    grown, after = renderer_of.get(grown_tab), renderer_of.get(next_tab)
    below_limit = renderers < limit
    violations = []
    if grown is None or after is None:
        violations.append(f"the grown phase's tabs have no renderer (grown {grown}, next {after})")
    elif not below_limit:
        violations.append(f"the grown phase is inconclusive: {renderers} renderers are at or over the limit of {limit}, "
                          "where Chrome reuses a same-site renderer whatever its footprint")
    elif grown == after:
        violations.append(f"the next tab of the site joined renderer {grown}, which is past the memory cap, "
                          f"below the limit of {limit}")
    return {"grown_renderer": grown, "next_renderer": after, "same_renderer": grown is not None and grown == after,
            "renderers": renderers, "renderer_limit": limit, "below_limit": below_limit, "violations": violations}


def fork_api(cef) -> int | None:
    """The running fork's API, which `debug.cef` names under `windows.fork_api`."""
    value = (cef.get("windows") or {}).get("fork_api") if isinstance(cef, dict) else None
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def reuse_switch(cef) -> bool | None:
    """Whether Chromium started with cmux-process-reuse-per-renderer-devtools (`debug.cef`
    `windows.process_reuse_per_renderer_devtools`); None when the build does not report it."""
    value = (cef.get("windows") or {}).get("process_reuse_per_renderer_devtools") if isinstance(cef, dict) else None
    return value if isinstance(value, bool) else None


def switch_limit(switches) -> int | None:
    """N from a renderer-process-limit=N switch the run passes the app (Chrome then uses N as its limit)."""
    for switch in switches:
        name, _, value = switch.partition("=")
        if name.lstrip("-") == "renderer-process-limit" and value.isdigit() and int(value) > 0:
            return int(value)
    return None


def renderer_limit(memory_report, chrome_limit: int, forced: int | None, switches=()) -> int:
    """The renderer count the sharing rules are checked below: --renderer-limit, else a renderer-process-limit
    switch the run passes, else the lower of Chrome's own limit and the app's budget
    (SubsystemBudget.chromiumRendererLimit, the renderer-process-limit switch once the app passes it), so the
    check holds whichever of the two the build runs with."""
    if forced:
        return forced
    passed = switch_limit(switches)
    if passed:
        return passed
    budget = ((memory_report.raw.get("budget") or {}) if memory_report else {}).get("chromium_renderer_limit")
    if isinstance(budget, (int, float)) and not isinstance(budget, bool) and budget > 0:
        return min(chrome_limit, int(budget))
    return chrome_limit


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--tabs", type=int, default=100)
    parser.add_argument("--sites", type=int, default=20)
    parser.add_argument("--heap-mb", type=int, default=20)
    parser.add_argument("--settle", type=float, default=30)
    parser.add_argument("--load-timeout", type=float, default=30, help="seconds a new tab may take to show its title")
    parser.add_argument("--cef-switches", default="", help="more Chromium switches, colon-separated (Debug builds only)")
    parser.add_argument("--agent-cdp", action=argparse.BooleanOptionalAction, default=False,
                        help="keep an agent's CDP session on the first tab (sharing with DevTools attached)")
    parser.add_argument("--renderer-limit", type=int, help="check the sharing rules below this renderer count")
    parser.add_argument("--memory-cap-mb", type=int, help="the shared-renderer memory cap Chromium starts with, and "
                                                          "the grown phase that checks it")
    parser.add_argument("--grow-margin-mb", type=int, default=64, help="the grown page's heap above the cap")
    parser.add_argument("--settle-grown", type=float, default=10,
                        help="seconds after the grown page before the next tab of its site (its footprint is read)")
    parser.add_argument("--out", help="the report file (.json), or the lab runner's folder for the result-v1 files "
                                      "and bench-renderer-sharing.json")
    parser.add_argument("--tag", help="the lab runner's tag of --app (checked against the bundle's name)")
    parser.add_argument("--session", choices=["light"], default="light", help="result-v1 session")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    args = parser.parse_args(argv)
    if args.tag is not None and tag_of(f"cmux DEV {args.tag}.app") != tag_of(args.app):
        parser.error(f"--tag {args.tag!r} is not the tag of --app {args.app!r}")
    if args.memory_cap_mb is not None and args.memory_cap_mb <= 0:
        parser.error("--memory-cap-mb must be positive")
    return args


def new_tab_summary(times):
    """The report's `new_tab_ms` row over the timed tabs: p50/p95/p99 (perf_stats.pct, whole ms), max, mean, timed."""
    return {"p50": results.pct(times, 0.5, None), "p95": results.pct(times, 0.95, None),
            "p99": results.pct(times, 0.99, None),
            "max": max(times) if times else None, "mean": round(statistics.mean(times)) if times else None,
            "timed": len(times)}


def grown_phase(app, sock: str, pid: int, bundle: str, port: int, args, limit: int) -> dict:
    """Opens a tab of a site the open phase does not use whose heap is past --memory-cap-mb, waits --settle-grown,
    opens a second tab of that site and checks where it went (``grown_check``), then closes both tabs."""
    site, tabs = args.sites, []
    try:
        for index, heap in ((args.tabs, args.memory_cap_mb + args.grow_margin_mb), (args.tabs + 1, None)):
            url = f"http://site{site}.test:{port}/{index}" + (f"?heap={heap}" if heap else "")
            response = app.action("openBrowser.chromium", focus=True, url=url)
            created = [item for item in response.get("created", []) if str(item).startswith("tab_")]
            tabs.extend(created[:1])
            if response.get("error") or not created or not wait_title(sock, created[0], f"site {site} tab {index}", args.load_timeout):
                return {"violations": [f"the grown phase's tab {url} did not open or show its title (is this a Debug or "
                                       f"bench dev build, so the .test mapping applies?): {response.get('error') or response}"]}
            if heap:
                time.sleep(args.settle_grown)  # test script: the grown page's heap is touched and its footprint read
        renderers = [row for row in bm.sample(pid, bundle, "grown", 1)["processes"] if row["kind"] == "cef-renderer"]
        return grown_check(renderer_map(sock).get("owners") or {}, tabs[0], tabs[1], len(renderers), limit)
    finally:
        for tab in tabs:
            closed = app.run("tab.close", target=tab)
            if closed.get("error"):
                print(f"   close {tab}: {closed['error']}", file=sys.stderr)


def main(argv=None):
    args = parse(argv)
    report_path, results_dir = results.out_paths(args.out, "bench-renderer-sharing.json")
    if sys.platform != "darwin":
        raise SystemExit("bench-renderer-sharing: macOS only (run it on a fleet GUI mini)")
    memory_gb = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30
    # The stand-in heaps are touched memory: at most a quarter of this Mac's.
    grown_heap_mb = args.memory_cap_mb + args.grow_margin_mb if args.memory_cap_mb else 0
    if args.tabs * args.heap_mb + grown_heap_mb > memory_gb * 1024 / 4:
        raise SystemExit(f"bench-renderer-sharing: {args.tabs} tabs x {args.heap_mb} MB and a grown page of {grown_heap_mb} MB "
                         f"is more than a quarter of {memory_gb:.0f} GB")
    stopping = {"signal": False}

    def terminate(_signum, _frame):
        stopping["signal"] = True
        raise KeyboardInterrupt

    _Handler.heap_mb = args.heap_mb
    port = serve()
    # No colon inside a switch: CMUX_NEXT_CEF_EXTRA_SWITCHES is colon-separated, so the rule maps
    # the host only and each URL keeps its port.
    rules = "host-resolver-rules=MAP *.test 127.0.0.1"
    switches = [rules] + [s for s in args.cef_switches.split(":") if s]
    config = {"browser": {"hibernation": "off", "freezeHiddenTabs": "off", "keepNeighborTabsAwake": 0}}
    bundle = os.path.realpath(args.app)
    bp.wipe_state(bundle)
    # The mapping goes through the bench list, which a bench build reads too; any other switch is
    # for diagnosis and only a Debug build takes it.
    bench_switches = [rules] + ([memory_cap_switch(args.memory_cap_mb)] if args.memory_cap_mb else [])
    extra = {"CMUX_NEXT_BENCH_CEF_SWITCHES": "\n".join(bench_switches)}
    if switches[1:]:
        extra["CMUX_NEXT_CEF_EXTRA_SWITCHES"] = ":".join(switches[1:])
    # The fleet worker finds every process of the step by this marker, also those the app starts.
    if os.environ.get("CI_JOB_DIR"):
        extra["CI_JOB_DIR"] = os.environ["CI_JOB_DIR"]
    bench = BenchApp(bundle, out=results_dir, env=extra, config=config, window=(40, 40, 1400, 900),
                     build_config=args.build_config, perf_session=args.session)
    bm.note_child_launch()  # the app is this script's child (bench_memory.webkit_is_apps)
    try:
        bench.launch()
    except BaseException:
        bench.stop()
        raise
    # After the launch: its teardown's SIGTERM handler would replace this one, and the finally below needs to know
    # a cancelled step (seconds before SIGKILL) to take the fast path.
    signal.signal(signal.SIGTERM, terminate)
    pid, sock = bench.process.pid, bench.socket
    limit = chrome_soft_limit(memory_gb)
    report = {"app": bundle, "tabs": args.tabs, "sites": args.sites, "heap_mb": args.heap_mb, "memory_gb": round(memory_gb, 1),
              "chrome_soft_limit": limit, "switches": switches, "bench_switches": bench_switches, "opened": [],
              "new_tab_ms": [], "agent": None}
    agent = None
    status = 0
    try:
        app = bm.App(bundle, sock)
        print(f"PERF-RENDERERS-MACHINE memory_gb={memory_gb:.1f} chrome_soft_limit={limit} tabs={args.tabs} sites={args.sites}", flush=True)
        cef = bp.rpc(sock, "debug.cef") or {}
        if cef.get("unavailable") or cef.get("fallback"):
            raise SystemExit(f"bench-renderer-sharing: Chromium is not available: {json.dumps(cef)[:400]}")
        report["fork_api"] = fork_api(cef)
        report["process_reuse_per_renderer_devtools"] = reuse_switch(cef)
        print(f"PERF-RENDERERS-FORK fork_api={report['fork_api']} "
              f"process_reuse_per_renderer_devtools={report['process_reuse_per_renderer_devtools']}", flush=True)
        checked_limit = renderer_limit(bm.MemoryReport.read(app), limit, args.renderer_limit, switches[1:])
        if args.memory_cap_mb:
            # Before the open phase, whose tabs bring the renderer count to the limit, where the cap is not tested.
            report["grown"] = grown = grown_phase(app, sock, pid, bundle, port, args, checked_limit)
            print(f"PERF-RENDERERS-GROWN memory_cap_mb={args.memory_cap_mb} grown_heap_mb={grown_heap_mb} "
                  f"same_renderer={grown.get('same_renderer')} renderers={grown.get('renderers')} "
                  f"below_limit={grown.get('below_limit')}", flush=True)
            for violation in grown["violations"]:
                print(f"bench-renderer-sharing: {violation}", file=sys.stderr)
                status = 1
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
                if args.agent_cdp and index == 0 and elapsed is not None:
                    agent = attach_agent(bundle, sock, tab, url, f"site {site} tab {index}")
                    report["agent"] = agent
                    if agent.get("error"):
                        raise SystemExit(f"bench-renderer-sharing: the agent's CDP session did not open: {agent['error']}")
                    print(f"PERF-RENDERERS-AGENT tab={tab} session={agent['session']}", flush=True)
            if (index == 0 and missed) or missed >= 3:
                raise SystemExit(f"bench-renderer-sharing: tab {index} did not open or show its title within {args.load_timeout} s "
                                 "(is this a Debug or bench dev build, so the .test mapping applies?)")
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
        site_of = {row["tab"]: row["site"] for row in report["opened"]}
        sites = site_sharing(owners, site_of, agent["tab"] if agent else None, checked_limit, len(renderers),
                             require_sharing=bool(agent))
        if agent and report["process_reuse_per_renderer_devtools"] is not True:
            sites["violations"].insert(0, "the app did not pass cmux-process-reuse-per-renderer-devtools "
                                          f"(fork API {report['fork_api']}; it needs {RENDERER_PATHS_FORK_API} and the shim's "
                                          "renderer paths): the agent's session turns same-site sharing off for every tab")
        result = {
            "renderers": len(renderers),
            "tab_renderers": sum(1 for n in sharing if n),
            "renderer_footprint_mb": round(sum(r["footprint_mb"] for r in renderers), 1),
            "app_footprint_mb": kinds.get("app", {}).get("footprint_mb"),
            "total_footprint_mb": sample["total_footprint_mb"],
            "tabs_per_renderer": {str(n): sharing.count(n) for n in sorted(set(sharing))},
            "max_tabs_in_one_renderer": max(sharing) if sharing else 0,
            "shared_mb": round(sum(p.get("memory_bytes", 0) for p in shared) / 2**20, 1),
            "new_tab_ms": new_tab_summary(times),
            "kinds": {k: {"n": v["count"], "footprint_mb": v["footprint_mb"]} for k, v in kinds.items()},
            "sites": sites,
        }
        report["settled"] = result
        report["sample"] = sample
        print(f"PERF-RENDERERS phase=settled tabs={len(report['opened'])} sites={args.sites} renderers={result['renderers']} "
              f"tab_renderers={result['tab_renderers']} renderer_footprint_mb={result['renderer_footprint_mb']} "
              f"app_footprint_mb={result['app_footprint_mb']} total_footprint_mb={result['total_footprint_mb']} "
              f"shared_mb={result['shared_mb']} tabs_per_renderer={json.dumps(result['tabs_per_renderer'])} "
              f"max_tabs_in_one_renderer={result['max_tabs_in_one_renderer']} new_tab_p50_ms={result['new_tab_ms']['p50']} "
              f"new_tab_p95_ms={result['new_tab_ms']['p95']} new_tab_p99_ms={result['new_tab_ms']['p99']} "
              f"new_tab_max_ms={result['new_tab_ms']['max']}", flush=True)
        for kind, entry in result["kinds"].items():
            print(f"PERF-RENDERERS-KIND kind={kind} n={entry['n']} footprint_mb={entry['footprint_mb']}")
        print(f"PERF-RENDERERS-SITES agent_cdp={bool(agent)} renderer_limit={sites['renderer_limit']} "
              f"renderers={sites['renderers']} below_limit={sites['below_limit']} "
              f"shared_layout_renderers={sites['shared_layout_renderers']} "
              f"max_same_site_main_frames={sites['max_same_site_main_frames']} shared_renderers={sites['shared_renderers']} "
              f"unshared_sites={len(sites['unshared_sites'])} mixed_site_renderers={sites['mixed_site_renderers']} "
              f"agent_renderer_tabs={sites['agent_renderer_tabs']}", flush=True)
        for violation in sites["violations"]:
            print(f"bench-renderer-sharing: {violation}", file=sys.stderr)
            status = 1
        if len(times) < args.tabs:
            print(f"bench-renderer-sharing: only {len(times)} of {args.tabs} tabs were timed", file=sys.stderr)
            status = 1
        if results_dir:  # a finished run; a tab that never opened is a missed one
            attempts = report["new_tab_ms"] + [None] * (args.tabs - len(report["new_tab_ms"]))
            report["results_v1"] = results.record_all(bench, results.renderer_sharing_series(
                attempts, result["renderers"], result["tab_renderers"], sample, session=args.session))
    finally:
        # A cancelled step has seconds before SIGKILL: end the bundle's processes at once.
        if agent and agent.get("socket") and not stopping["signal"]:
            try:
                host_cli(bundle, agent["socket"], sock, "close", "--session", AGENT_SESSION, timeout=20)
            except Exception as error:  # noqa: BLE001  the app's quit below ends the session too
                print(f"   agent close: {error}", file=sys.stderr)
        if stopping["signal"]:
            bm.end_bundle(bundle)
        bench.stop()  # quits the app (when it still runs) and ends its tag
        if report_path:
            with open(report_path, "w") as handle:
                json.dump(report, handle, indent=1)
        bp.wipe_state(bundle)
    sys.exit(status)


if __name__ == "__main__":
    main()
