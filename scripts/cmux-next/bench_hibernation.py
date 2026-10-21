#!/usr/bin/env python3
"""What browser tab hibernation frees, and how a hibernated tab wakes
(plans/cmux-next/tab-lifecycle.md section 3).

Opens --tabs Chromium and --tabs WebKit tabs on local pages, each its own
site (tN.localhost for Chromium, a port each for WebKit) with a long article,
a form, a 250 ms timer and a --heap-mb array that stands in for a real site's
heap. Each page is scrolled and its form filled by script. Then, with every
bench tab hidden behind one shown tab:

  awake      hidden pages, not yet frozen
  frozen     after browser.freezeHiddenTabs (Chromium only; WebKit throttles itself)
  hibernated after Hibernate Tab on each (the engine page is closed)

Each phase prints the footprint and CPU of every process the app owns, by
kind (cef-renderer, webkit-webcontent, app...), and the renderer count.
Then each tab is selected in turn and timed:

  mounted_ms  until the app reports the page restored (debug.surfaces restored_total)
  usable_ms   until the page answers script again (it has loaded)
  painted_ms  until the app reports the woken page painted (debug.surfaces
              wakes, builds that report it), and whether a snapshot covered it
  scroll/form whether its scroll position and form fields came back

With --pressure (and passwordless sudo) a second set of tabs is opened and
`memory_pressure -S -l critical` simulated: the time until every eligible
hidden page hibernated is printed.

Usage (a fleet or capture mini, never a laptop; DEV build, it reads debug.surfaces):
  bench_hibernation.py --app BUNDLE [--tabs 6] [--heap-mb 40] [--measure 20]
      [--config JSON] [--pressure] [--out FILE.json]
Prints PERF-HIBERNATE lines (one per phase and kind, one per wake, a summary).
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402  (launch, App, owned, sample, end_bundle)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)

ARTICLE = "<p>" + ("Hibernation frees a hidden page's renderer and brings it back on demand. " * 30) + "</p>"
PAGE = """<!doctype html><html><head><meta charset=utf-8><title>Hibernate {n}</title>
<style>body{{font:15px -apple-system,sans-serif;max-width:760px;margin:40px auto;line-height:1.5}}</style></head><body>
<h1>Hibernate bench page {n}</h1>
<form id=f><input name=name><textarea name=notes></textarea><input type=checkbox name=agree>
<select name=size><option>s</option><option>m</option><option>l</option></select></form>
<p id=t>0</p>{article}
<script>
// A real site's heap: --heap-mb of touched memory, so the page's footprint is not just its DOM.
window.heap=new Uint8Array({heap}*1048576);for(let i=0;i<heap.length;i+=4096)heap[i]=i&255;
let k=0;setInterval(()=>{{document.getElementById('t').textContent=++k}},250);
</script></body></html>"""

# The state each page gets, and what a woken page must show again.
SCROLL_Y = 4000
FORM = {"name": "Ada Lovelace", "notes": "first line\nsecond line", "agree": True, "size": "l"}
SET_STATE = ("(()=>{const f=document.getElementById('f');f.name.value=%s;f.notes.value=%s;f.agree.checked=true;"
             "f.size.value='l';scrollTo(0,%d);return scrollY})()") % (json.dumps(FORM["name"]), json.dumps(FORM["notes"]), SCROLL_Y)
READ_STATE = ("(()=>{const f=document.getElementById('f');return JSON.stringify({y:Math.round(scrollY),"
              "name:f.name.value,notes:f.notes.value,agree:f.agree.checked,size:f.size.value})})()")


class _Handler(http.server.BaseHTTPRequestHandler):
    heap_mb = 0

    def do_GET(self):  # noqa: N802
        url = urlparse(self.path)
        number = parse_qs(url.query).get("n", ["0"])[0]
        body = PAGE.format(n=number, article=ARTICLE * 60, heap=self.heap_mb).encode()
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


def page_url(engine: str, index: int, ports: list[int]) -> str:
    # Chromium: each tN.localhost is its own site (its own renderer under site isolation).
    # WebKit: a port each, so no two pages share an origin.
    if engine == "chromium":
        return f"http://t{index}.localhost:{ports[0]}/?n={index}"
    return f"http://127.0.0.1:{ports[index % len(ports)]}/?n={index}"


def surfaces(sock: str) -> dict:
    return bp.rpc(sock, "debug.surfaces") or {}


def hibernation(sock: str) -> dict:
    return surfaces(sock).get("hibernation") or {}


def evaluate(sock: str, tab: str, script: str, timeout: float = 30):
    answer = bp.rpc(sock, "browser.page.eval", {"tab": tab, "script": script}, timeout=timeout)
    return None if answer.get("error") else answer.get("value")


def wait_for(predicate, seconds: float, step: float = 0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test script: waiting on the app's reported state
    return None


def renderers(result: dict) -> dict:
    kinds = result["kinds"]
    return {"cef_renderers": kinds.get("cef-renderer", {}).get("count", 0),
            "webkit_webcontent": kinds.get("webkit-webcontent", {}).get("count", 0)}


def phase(app_pid: int, bundle: str, label: str, measure: float, report: dict):
    result = bm.sample(app_pid, bundle, label, 1, measure)
    result.update(renderers(result))
    report["phases"].append(result)
    for kind, entry in result["kinds"].items():
        print(f"PERF-HIBERNATE phase={label} kind={kind} n={entry['count']} footprint_mb={entry['footprint_mb']} "
              f"cpu_pct={entry.get('cpu_pct')} wakeups_per_s={entry.get('wakeups_per_s')}")
    print(f"PERF-HIBERNATE-TOTAL phase={label} footprint_mb={result['total_footprint_mb']} "
          f"cef_renderers={result['cef_renderers']} webkit_webcontent={result['webkit_webcontent']}", flush=True)
    return result


def wake(app: bm.App, sock: str, tab: str, engine: str) -> dict:
    """Selects a hibernated tab and times it back."""
    before = hibernation(sock)
    restored = before.get("restored_total") or 0
    wakes_before = len(before.get("wakes") or [])
    started = time.monotonic()
    app.run("tab.focus", target=tab)
    mounted = wait_for(lambda: (hibernation(sock).get("restored_total") or 0) > restored and time.monotonic(), 15, 0.01)
    state = evaluate(sock, tab, READ_STATE)
    usable = time.monotonic()
    row = {"tab": tab, "engine": engine, "mounted_ms": round((mounted - started) * 1000) if mounted else None,
           "usable_ms": round((usable - started) * 1000) if state is not None else None}
    try:
        got = json.loads(state) if isinstance(state, str) else {}
    except ValueError:
        got = {}
    row["scroll_ok"] = abs((got.get("y") or 0) - SCROLL_Y) <= 2
    row["form_ok"] = all(got.get(key) == value for key, value in FORM.items())
    row["got"] = got
    # The app's own record of the wake (builds that report it): show to first paint, and the cover.
    wakes = wait_for(lambda: (lambda w: w if len(w) > wakes_before else None)(hibernation(sock).get("wakes") or []), 3)
    if wakes:
        own = wakes[-1]
        row.update({"painted_ms": own.get("painted_ms"), "app_mounted_ms": own.get("mounted_ms"),
                    "snapshot": own.get("snapshot")})
    print(f"PERF-HIBERNATE-WAKE engine={engine} tab={tab} mounted_ms={row['mounted_ms']} usable_ms={row['usable_ms']} "
          f"painted_ms={row.get('painted_ms')} snapshot={row.get('snapshot')} scroll_ok={row['scroll_ok']} "
          f"form_ok={row['form_ok']}", flush=True)
    return row


def percentile(values, q):
    values = sorted(v for v in values if v is not None)
    return values[min(len(values) - 1, int(len(values) * q))] if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--tabs", type=int, default=6, help="tabs per engine")
    parser.add_argument("--engines", default="chromium,webkit")
    parser.add_argument("--heap-mb", type=int, default=40)
    parser.add_argument("--measure", type=float, default=20, help="seconds each phase's CPU is measured over")
    parser.add_argument("--freeze", type=float, default=10, help="browser.freezeHiddenTabs for the run")
    parser.add_argument("--config", default="{}", help="extra cmux.json settings (JSON)")
    parser.add_argument("--pressure", action="store_true", help="also simulate critical memory pressure (needs sudo -n)")
    parser.add_argument("--out")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("bench-hibernation: macOS only (run it on a fleet or capture mini)")
    _Handler.heap_mb = args.heap_mb
    engines = [e for e in args.engines.split(",") if e]
    ports = [serve() for _ in range(max(1, args.tabs))]
    # No neighbors: a tab beside the shown one would wake in the background before it is timed.
    config = bm.merged({"browser": {"hibernation": "moderate", "freezeHiddenTabs": args.freeze, "keepNeighborTabsAwake": 0}},
                       json.loads(args.config))
    bundle = os.path.realpath(args.app)
    signal.signal(signal.SIGTERM, bm.interrupted)
    bp.wipe_state(bundle)
    pid, sock, scratch = bm.launch(bundle, config)
    app = bm.App(bundle, sock)
    report = {"app": bundle, "tabs": args.tabs, "heap_mb": args.heap_mb, "config": config, "phases": [], "wakes": []}
    opened: dict[str, list[str]] = {}

    def open_tab(engine: str, url: str) -> str | None:
        response = app.run(f"openBrowser.{engine}", url=url)
        created = [item for item in response.get("created", []) if str(item).startswith("tab_")]
        if response.get("error") or not created:
            print(f"   open {engine} {url}: {response.get('error') or response}", file=sys.stderr)
            return None
        tab = created[0]
        app.run("tab.focus", target=tab)
        if evaluate(sock, tab, SET_STATE) is None:
            print(f"   {tab}: page did not answer", file=sys.stderr)
        return tab

    try:
        for engine in engines:
            opened[engine] = [t for t in (open_tab(engine, page_url(engine, i, ports)) for i in range(args.tabs)) if t]
        # One shown tab in front of them all (its page counts in every phase alike).
        front = open_tab("chromium", f"http://front.localhost:{ports[0]}/?n=front")
        tabs = [t for engine in engines for t in opened[engine]]
        report["opened"] = opened
        # Agent grace (30 s after the last script call) and the page's own load work pass first.
        time.sleep(35)  # test script: let the hidden pages settle
        phase(pid, bundle, "awake", args.measure, report)
        chromium = set(opened.get("chromium", []))
        if chromium:
            frozen = wait_for(lambda: chromium <= set(hibernation(sock).get("frozen") or []), 120, 1)
            print(f"PERF-HIBERNATE-FROZEN all={bool(frozen)} frozen={len(hibernation(sock).get('frozen') or [])}", flush=True)
            time.sleep(5)  # test script: settle after the freeze
            phase(pid, bundle, "frozen", args.measure, report)
        for tab in tabs:
            reply = app.run("hibernateTab", target=tab)
            if reply.get("error"):
                print(f"   hibernate {tab}: {reply['error']}", file=sys.stderr)
        asleep = wait_for(lambda: set(tabs) <= set(hibernation(sock).get("hibernated") or []), 60, 0.5)
        status = hibernation(sock)
        print(f"PERF-HIBERNATE-SLEPT all={bool(asleep)} hibernated={len(status.get('hibernated') or [])} "
              f"exemptions={json.dumps(status.get('exemptions') or {})}", flush=True)
        time.sleep(10)  # test script: renderers exit and the app settles
        phase(pid, bundle, "hibernated", args.measure, report)
        for engine in engines:
            for tab in opened[engine]:
                if tab in set(hibernation(sock).get("hibernated") or []):
                    report["wakes"].append(wake(app, sock, tab, engine))
                    app.run("tab.focus", target=front)
                    time.sleep(1)  # test script: the woken tab hides again before the next wake
        phases = {p["label"]: p for p in report["phases"]}
        summary = {}
        for engine, kind in (("chromium", "cef-renderer"), ("webkit", "webkit-webcontent")):
            count = len(opened.get(engine, []))
            if not count:
                continue
            awake = phases["awake"]["kinds"].get(kind, {})
            slept = phases["hibernated"]["kinds"].get(kind, {})
            rows = [w for w in report["wakes"] if w["engine"] == engine]
            summary[engine] = {
                "tabs": count,
                "freed_mb_per_tab": round((awake.get("footprint_mb", 0) - slept.get("footprint_mb", 0)) / count, 1),
                "awake_cpu_pct": awake.get("cpu_pct"), "hibernated_cpu_pct": slept.get("cpu_pct"),
                "frozen_cpu_pct": phases.get("frozen", {}).get("kinds", {}).get(kind, {}).get("cpu_pct"),
                "processes_awake": awake.get("count", 0), "processes_hibernated": slept.get("count", 0),
                "mounted_p50_ms": percentile([r["mounted_ms"] for r in rows], 0.5),
                "usable_p50_ms": percentile([r["usable_ms"] for r in rows], 0.5),
                "usable_p90_ms": percentile([r["usable_ms"] for r in rows], 0.9),
                "painted_p50_ms": percentile([r.get("painted_ms") for r in rows], 0.5),
                "snapshots": sum(1 for r in rows if r.get("snapshot")),
                "scroll_restored": sum(1 for r in rows if r["scroll_ok"]), "form_restored": sum(1 for r in rows if r["form_ok"]),
                "woken": len(rows),
            }
            s = summary[engine]
            print(f"PERF-HIBERNATE-SUMMARY engine={engine} tabs={count} freed_mb_per_tab={s['freed_mb_per_tab']} "
                  f"processes={s['processes_awake']}->{s['processes_hibernated']} cpu_pct awake={s['awake_cpu_pct']} "
                  f"frozen={s['frozen_cpu_pct']} hibernated={s['hibernated_cpu_pct']} mounted_p50_ms={s['mounted_p50_ms']} "
                  f"usable_p50_ms={s['usable_p50_ms']} usable_p90_ms={s['usable_p90_ms']} painted_p50_ms={s['painted_p50_ms']} "
                  f"snapshots={s['snapshots']}/{s['woken']} scroll={s['scroll_restored']}/{s['woken']} "
                  f"form={s['form_restored']}/{s['woken']}", flush=True)
        report["summary"] = summary
        if args.pressure:
            report["pressure"] = pressure(app, sock, engines, ports, args.tabs, open_tab, front)
    finally:
        app.run("quit")
        bm.wait_gone(pid, 20)
        bm.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=1)
            print(f"bench-hibernation: wrote {args.out}")


def pressure(app, sock, engines, ports, count, open_tab, front) -> dict:
    """Simulated critical memory pressure: the time until every new hidden page hibernated."""
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        print("PERF-HIBERNATE-PRESSURE skipped: no passwordless sudo", flush=True)
        return {"skipped": "no sudo"}
    tabs = [t for engine in engines for t in (open_tab(engine, page_url(engine, 100 + i, ports)) for i in range(count)) if t]
    app.run("tab.focus", target=front)
    time.sleep(35)  # test script: agent grace after the script calls
    before = hibernation(sock).get("hibernated_total") or 0
    started = time.monotonic()
    simulator = subprocess.Popen(["sudo", "-n", "memory_pressure", "-S", "-l", "critical", "-s", "20"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    slept = wait_for(lambda: set(tabs) <= set(hibernation(sock).get("hibernated") or []) and time.monotonic(), 30, 0.1)
    status = hibernation(sock)
    simulator.wait(timeout=60)
    result = {"tabs": len(tabs), "seconds": round(slept - started, 2) if slept else None,
              "hibernated": (status.get("hibernated_total") or 0) - before, "pressure_seen": status.get("pressure"),
              "exemptions": status.get("exemptions")}
    print(f"PERF-HIBERNATE-PRESSURE tabs={result['tabs']} all_hibernated_s={result['seconds']} "
          f"hibernated={result['hibernated']} exemptions={json.dumps(result['exemptions'] or {})}", flush=True)
    return result


if __name__ == "__main__":
    main()
