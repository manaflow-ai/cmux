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
  app_mounted_ms, loaded_ms  the app's own times from the restore to the page being
              back and to its load ending (debug.surfaces wakes, builds that report it;
              mounted_ms and usable_ms above include the CLI's round trip), and
              whether a snapshot covered the pane
  scroll/form whether its scroll position and form fields came back

With --pressure a second set of tabs is opened (with --pressure-reuse, the
bench tabs themselves, woken by the wake phase), plus one page that plays
media and one an agent keeps calling, and critical memory pressure is fed in
(`debug.hibernation.pressure` when the build has it, else `sudo -n
memory_pressure -S -l critical`). Printed: the time until every eligible
hidden page hibernated, the footprint before and after, and whether the media
page or the driven page ever hibernated (they must not).

Usage (a fleet or capture mini, never a laptop; DEV build, it reads debug.surfaces):
  bench_hibernation.py --app BUNDLE [--tabs 6] [--heap-mb 40] [--measure 20]
      [--config JSON] [--pressure] [--out FILE.json]
  launch (default): starts the bundle's app with a scratch HOME and config, quits it at the end.
  attach (--socket PATH --app-pid PID): an app `capture-host launch` started in a capture
      slot; the run's settings are set over the socket (the slot's own cmux-next.json),
      and its tabs are closed at the end.
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

# One second of silence as a WAV data URI, looped: a page that plays media (it must never hibernate).
AUDIO = ("<audio id=a muted autoplay loop src='data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA='>"
         "</audio><script>document.getElementById('a').play().catch(()=>{})</script>")

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
        query = parse_qs(url.query)
        number = query.get("n", ["0"])[0]
        body = PAGE.format(n=number, article=ARTICLE * 60, heap=self.heap_mb)
        if query.get("audio") == ["1"]:
            # A muted looping element plays without a gesture; the probe counts muted media as playing.
            body = body.replace("</body>", AUDIO + "</body>")
        body = body.encode()
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


def evaluate(sock: str, tab: str, script: str, seconds: float = 30):
    """The script's value once the page runs it without an error (a WebKit page answers
    before its document loads, a woken page before it is back), or None after `seconds`."""
    deadline = time.monotonic() + seconds
    while True:
        answer = bp.rpc(sock, "browser.page.eval", {"tab": tab, "script": script}, timeout=seconds)
        if not answer.get("error"):
            return answer.get("value")
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.02)  # test script: the page is still loading


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
    started = time.monotonic()
    app.run("tab.focus", target=tab)
    mounted = wait_for(lambda: (hibernation(sock).get("restored_total") or 0) > restored and time.monotonic(), 15, 0.01)
    # Usable: the page runs script again. Restored: its scroll and form are back (WebKit
    # restores scroll after the load, so the first answer can still be at the top).
    state, usable, restored_at, got = evaluate(sock, tab, READ_STATE), time.monotonic(), None, {}
    deadline = usable + 5
    while state is not None:
        try:
            got = json.loads(state) if isinstance(state, str) else {}
        except ValueError:
            got = {}
        if matches(got) or time.monotonic() >= deadline:
            restored_at = time.monotonic() if matches(got) else None
            break
        time.sleep(0.02)  # test script: the page restores its scroll after it loads
        state = evaluate(sock, tab, READ_STATE, 5)
    row = {"tab": tab, "engine": engine, "mounted_ms": round((mounted - started) * 1000) if mounted else None,
           "usable_ms": round((usable - started) * 1000) if state is not None else None,
           "restored_ms": round((restored_at - started) * 1000) if restored_at else None}
    row["scroll_ok"] = abs((got.get("y") or 0) - SCROLL_Y) <= 2
    row["form_ok"] = all(got.get(key) == value for key, value in FORM.items())
    row["got"] = got
    # The app's own record of the wake (builds that report it): back, loaded, and the snapshot.
    own = wait_for(lambda: next((w for w in reversed(hibernation(sock).get("wakes") or [])
                                 if w.get("tab") == tab and w.get("loaded_ms") is not None), None), 3)
    if own:
        row.update({"loaded_ms": own.get("loaded_ms"), "app_mounted_ms": own.get("mounted_ms"), "snapshot": own.get("snapshot")})
    print(f"PERF-HIBERNATE-WAKE engine={engine} tab={tab} mounted_ms={row['mounted_ms']} usable_ms={row['usable_ms']} "
          f"restored_ms={row['restored_ms']} app_mounted_ms={row.get('app_mounted_ms')} loaded_ms={row.get('loaded_ms')} snapshot={row.get('snapshot')} scroll_ok={row['scroll_ok']} "
          f"form_ok={row['form_ok']}", flush=True)
    return row


def matches(got: dict) -> bool:
    return abs((got.get("y") or 0) - SCROLL_Y) <= 2 and all(got.get(key) == value for key, value in FORM.items())


def exited(before: dict, after: dict, kind: str) -> list[dict]:
    """The `kind` processes of `before` gone by `after`: the closed pages' own processes, apart
    from the app's other pages, which can start, reload or grow meanwhile."""
    left = {row["pid"] for row in after["processes"]}
    return [row for row in before["processes"] if row["kind"] == kind and row["pid"] not in left]


def total(rows: list[dict], key: str, phase: dict | None = None):
    """`key` summed over `rows`, read from `phase`'s sample of the same pids when given."""
    if phase is not None:
        pids = {row["pid"] for row in rows}
        rows = [row for row in phase["processes"] if row["pid"] in pids]
    values = [row[key] for row in rows if row.get(key) is not None]
    return round(sum(values), 3) if values else None


def percentile(values, q):
    values = sorted(v for v in values if v is not None)
    return values[min(len(values) - 1, int(len(values) * q))] if values else None


def main():
    # --workspaces N: workspace hibernation instead (bench_workspace_hibernation.py), so the reviewed
    # scripts/measure/tab-hibernation.sh runs it on the fleet: --arg=--workspaces=50.
    if any(arg == "--workspaces" or arg.startswith("--workspaces=") for arg in sys.argv[1:]):
        import bench_workspace_hibernation
        sys.exit(bench_workspace_hibernation.run(sys.argv[1:]))
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--tabs", type=int, default=6, help="tabs per engine")
    parser.add_argument("--engines", default="chromium,webkit")
    parser.add_argument("--heap-mb", type=int, default=40)
    parser.add_argument("--measure", type=float, default=20, help="seconds each phase's CPU is measured over")
    parser.add_argument("--freeze", type=float, default=10, help="browser.freezeHiddenTabs for the run")
    parser.add_argument("--config", default="{}", help="extra cmux.json settings (JSON)")
    parser.add_argument("--pressure", action="store_true", help="also simulate critical memory pressure")
    parser.add_argument("--pressure-reuse", action="store_true", help="pressure the bench tabs instead of opening new ones")
    parser.add_argument("--pressure-wait", type=float, default=0, help="seconds to wait for the pages under pressure (0: 1.5 s per page, at least 30)")
    parser.add_argument("--socket", help="attach: the running app's control socket")
    parser.add_argument("--app-pid", type=int, help="attach: the running app's pid")
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
    if args.socket:
        if not args.app_pid:
            raise SystemExit("bench-hibernation: --socket needs --app-pid")
        pid, sock, scratch = args.app_pid, args.socket, None
        for path, value in flatten(config):
            answer = bp.rpc(sock, "settings.set", {"path": path, "value": value})
            if answer.get("error"):
                print(f"   settings.set {path}: {answer['error']}", file=sys.stderr)
    else:
        bp.wipe_state(bundle)
        pid, sock, scratch = bm.launch(bundle, config)
    app = bm.App(bundle, sock)
    report = {"app": bundle, "tabs": args.tabs, "heap_mb": args.heap_mb, "config": config, "phases": [], "wakes": []}
    opened: dict[str, list[str]] = {}
    opened_extra: list[str] = []

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
        opened_extra.append(front)
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
        report["snapshot_store"] = {"pictures": status.get("snapshots"), "bytes": status.get("snapshot_bytes")}
        print(f"PERF-HIBERNATE-SLEPT all={bool(asleep)} hibernated={len(status.get('hibernated') or [])} "
              f"snapshots={status.get('snapshots')} snapshot_bytes={status.get('snapshot_bytes')} "
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
            # The bench tabs' own processes: those that exited when they hibernated.
            gone = exited(phases["awake"], phases["hibernated"], kind)
            rows = [w for w in report["wakes"] if w["engine"] == engine]
            summary[engine] = {
                "tabs": count, "processes_exited": len(gone),
                "freed_mb_per_tab": round((total(gone, "footprint_mb") or 0) / count, 1),
                "kind_delta_mb": round(phases["awake"]["kinds"].get(kind, {}).get("footprint_mb", 0)
                                       - phases["hibernated"]["kinds"].get(kind, {}).get("footprint_mb", 0), 1),
                "app_delta_mb": round(phases["awake"]["total_footprint_mb"] - phases["hibernated"]["total_footprint_mb"], 1),
                "hidden_cpu_pct": total(gone, "cpu_pct"), "hidden_wakeups_per_s": total(gone, "wakeups_per_s"),
                "frozen_cpu_pct": total(gone, "cpu_pct", phases["frozen"]) if "frozen" in phases else None,
                "frozen_wakeups_per_s": total(gone, "wakeups_per_s", phases["frozen"]) if "frozen" in phases else None,
                "mounted_p50_ms": percentile([r["mounted_ms"] for r in rows], 0.5),
                "usable_p50_ms": percentile([r["usable_ms"] for r in rows], 0.5),
                "usable_p90_ms": percentile([r["usable_ms"] for r in rows], 0.9),
                "usable_p95_ms": percentile([r["usable_ms"] for r in rows], 0.95),
                "mounted_p95_ms": percentile([r["mounted_ms"] for r in rows], 0.95),
                "app_mounted_p95_ms": percentile([r.get("app_mounted_ms") for r in rows], 0.95),
                "restored_p50_ms": percentile([r["restored_ms"] for r in rows], 0.5),
                "app_mounted_p50_ms": percentile([r.get("app_mounted_ms") for r in rows], 0.5),
                "loaded_p50_ms": percentile([r.get("loaded_ms") for r in rows], 0.5),
                "loaded_p90_ms": percentile([r.get("loaded_ms") for r in rows], 0.9),
                "snapshots": sum(1 for r in rows if r.get("snapshot")),
                "scroll_restored": sum(1 for r in rows if r["scroll_ok"]), "form_restored": sum(1 for r in rows if r["form_ok"]),
                "woken": len(rows),
            }
            s = summary[engine]
            print(f"PERF-HIBERNATE-SUMMARY engine={engine} tabs={count} freed_mb_per_tab={s['freed_mb_per_tab']} "
                  f"processes_exited={s['processes_exited']} app_delta_mb={s['app_delta_mb']} "
                  f"hidden_cpu_pct={s['hidden_cpu_pct']} frozen_cpu_pct={s['frozen_cpu_pct']} "
                  f"hidden_wakeups_per_s={s['hidden_wakeups_per_s']} frozen_wakeups_per_s={s['frozen_wakeups_per_s']} "
                  f"mounted_p50_ms={s['mounted_p50_ms']} mounted_p95_ms={s['mounted_p95_ms']} usable_p50_ms={s['usable_p50_ms']} "
                  f"usable_p90_ms={s['usable_p90_ms']} usable_p95_ms={s['usable_p95_ms']} app_mounted_p95_ms={s['app_mounted_p95_ms']} "
                  f"restored_p50_ms={s['restored_p50_ms']} app_mounted_p50_ms={s['app_mounted_p50_ms']} "
                  f"loaded_p50_ms={s['loaded_p50_ms']} loaded_p90_ms={s['loaded_p90_ms']} "
                  f"snapshots={s['snapshots']}/{s['woken']} scroll={s['scroll_restored']}/{s['woken']} "
                  f"form={s['form_restored']}/{s['woken']}", flush=True)
        report["summary"] = summary
        if args.pressure:
            reuse = [t for e in engines for t in opened[e]] if args.pressure_reuse else None
            report["pressure"] = pressure(app, sock, engines, ports, args.tabs, open_tab, front, opened_extra,
                                          reuse=reuse, wait=args.pressure_wait, pid=pid, bundle=bundle,
                                          measure=args.measure, report=report)
    finally:
        if scratch is None:
            for tab in [t for tabs in opened.values() for t in tabs] + opened_extra:
                app.run("tab.close", target=tab)
        else:
            app.run("quit")
            bm.wait_gone(pid, 20)
            bm.end_bundle(bundle)
            shutil.rmtree(scratch, ignore_errors=True)
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=1)
            print(f"bench-hibernation: wrote {args.out}")


def flatten(config: dict, prefix: str = ""):
    """(dotted path, value) for every leaf of a cmux.json fragment."""
    for key, value in config.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            yield from flatten(value, path)
        else:
            yield path, value


def feed_pressure(sock: str, level: str) -> str | None:
    """Feeds `level` through the DEBUG hook; returns how, or None when neither way works."""
    answer = bp.rpc(sock, "debug.hibernation.pressure", {"level": level}) or {}
    if isinstance(answer, dict) and answer.get("pressure") == level:
        return "debug"
    return None


def pressure(app, sock, engines, ports, count, open_tab, front, opened_extra, reuse=None, wait=0,
             pid=None, bundle=None, measure=20, report=None) -> dict:
    """Critical memory pressure: the time until every hidden page hibernated, the footprint
    before and after, and that the media page and the agent-driven page never did."""
    if reuse is None:
        tabs = [t for engine in engines for t in (open_tab(engine, page_url(engine, 100 + i, ports)) for i in range(count)) if t]
        opened_extra.extend(tabs)
    else:
        tabs = list(reuse)
    # Pages that play media, or that an agent keeps calling, must outlive any pressure (msg 9103).
    playing = [t for engine in engines[:1] for t in [open_tab(engine, page_url(engine, 900, ports) + "&audio=1")] if t]
    driven = [t for engine in engines[:1] for t in [open_tab(engine, page_url(engine, 901, ports))] if t]
    opened_extra.extend(playing + driven)
    app.run("tab.focus", target=front)
    time.sleep(35)  # test script: agent grace after the script calls
    for tab in driven:
        evaluate(sock, tab, "1")
    if pid is not None and report is not None:
        phase(pid, bundle, "pressure-before", measure, report)
    before = hibernation(sock).get("hibernated_total") or 0
    how = feed_pressure(sock, "critical")
    simulator = None
    if how is None:
        if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
            print("PERF-HIBERNATE-PRESSURE skipped: no debug.hibernation.pressure and no passwordless sudo", flush=True)
            return {"skipped": "no pressure source"}
        simulator = subprocess.Popen(["sudo", "-n", "memory_pressure", "-S", "-l", "critical", "-s", "20"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        how = "memory_pressure"
    started = time.monotonic()
    ever_slept: set[str] = set()
    kept = set(playing + driven)
    last_drive = [time.monotonic()]
    timeline: list[tuple[float, int]] = []

    def all_asleep():
        if time.monotonic() - last_drive[0] > 5:
            for tab in driven:
                evaluate(sock, tab, "1", 5)  # an agent keeps driving it
            last_drive[0] = time.monotonic()
        asleep = set(hibernation(sock).get("hibernated") or [])
        ever_slept.update(asleep & kept)
        timeline.append((round(time.monotonic() - started, 2), len(asleep & set(tabs))))
        return set(tabs) <= asleep and time.monotonic()

    slept = wait_for(all_asleep, wait or max(30, 1.5 * len(tabs)), 0.1)
    status = hibernation(sock)
    if simulator is not None:
        simulator.wait(timeout=60)
    else:
        feed_pressure(sock, "normal")
    # Pacing: the most pages that went within any one second.
    burst, j = 0, 0
    for i in range(len(timeline)):
        while timeline[i][0] - timeline[j][0] > 1.0:
            j += 1
        burst = max(burst, timeline[i][1] - timeline[j][1])
    result = {"tabs": len(tabs), "source": how, "seconds": round(slept - started, 2) if slept else None,
              "hibernated": (status.get("hibernated_total") or 0) - before, "asleep_at_end": len(set(status.get("hibernated") or []) & set(tabs)),
              "pressure_seen": status.get("pressure"), "max_per_second": burst,
              "playing_tabs": len(playing), "playing_hibernated": sorted(ever_slept & set(playing)),
              "driven_tabs": len(driven), "driven_hibernated": sorted(ever_slept & set(driven)),
              "exemptions": status.get("exemptions")}
    if pid is not None and report is not None:
        time.sleep(10)  # test script: renderers exit and the app settles
        phase(pid, bundle, "pressure-after", measure, report)
        phases = {p["label"]: p for p in report["phases"]}
        result["footprint_before_mb"] = phases["pressure-before"]["total_footprint_mb"]
        result["footprint_after_mb"] = phases["pressure-after"]["total_footprint_mb"]
    print(f"PERF-HIBERNATE-PRESSURE source={how} tabs={result['tabs']} all_hibernated_s={result['seconds']} "
          f"hibernated={result['hibernated']} asleep_at_end={result['asleep_at_end']} max_per_second={burst} "
          f"footprint_before_mb={result.get('footprint_before_mb')} footprint_after_mb={result.get('footprint_after_mb')} "
          f"playing_hibernated={len(result['playing_hibernated'])}/{len(playing)} "
          f"driven_hibernated={len(result['driven_hibernated'])}/{len(driven)} "
          f"exemptions={json.dumps(result['exemptions'] or {})}", flush=True)
    return result

if __name__ == "__main__":
    main()
