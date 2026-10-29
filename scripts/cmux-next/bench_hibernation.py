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

With --background-timeline 0,30,300,600 the bench runs only this phase
(Chromium, hibernation off): for each mode of --background-freeze (off, then on
at --freeze seconds) it opens --tabs new pages, each its own site, hides them all
behind the shown tab, and at each point (seconds after the hide) reads, for each
hidden page, the footprint (PMF) of the renderer that hosts only that page and
that renderer's task role. Chrome backgrounds a renderer whose pages are all
hidden and purges its memory 1 to 4 minutes later, at once when frozen; the
phase shows whether cmux's hidden pages get the same
(plans/cmux-next/memory-DESIGN.md, "Hidden Chromium pages: backgrounded and purged").
Its --heap-mb defaults to 0: a live array is memory no purge can free, so it
would hide the purge's fall.

Usage (a fleet or capture mini, never a laptop; a tagged DEV build, Debug or bench config:
debug.surfaces answers in both):
  bench_hibernation.py --app BUNDLE [--tabs 6] [--heap-mb 40] [--measure 20]
      [--config JSON] [--pressure] [--out FILE.json | --out DIR]
  bench_hibernation.py --app BUNDLE --background-timeline 0,30,300,600 [--background-freeze off,on]
      [--feature chromiumTabVisibility=on] [--freeze 10] [--tabs 6] [--heap-mb 0] [--out FILE.json]
  launch (default): starts the bundle's app through bench_launch.BenchApp (the lab's bench env,
      a scratch config, an empty saved session for the tag) and ends it and its tag at the end.
  attach (--socket PATH --app-pid PID): an app `capture-host launch` started in a capture
      slot; the run's settings are set over the socket (the slot's own cmux-next.json),
      and its tabs are closed at the end.
Prints PERF-HIBERNATE lines (one per phase and kind, one per wake, a summary); the timeline
prints PERF-HIBERNATE-BACKGROUND lines (one per mode and point, a summary per mode, a verdict)
and writes no result-v1 series. The wake
percentiles (p50/p90/p95/p99) are scripts/perf-lab/perf_stats.py's (linear interpolation).

--out FILE.json is the report. --out DIR (the lab runner's folder) also gets one
cmux-perf-result/v1 file per series through BenchApp.record (browser_engine_bench_report.py):
`hibernation.*` in story browser-hibernation (the Chromium tabs) or browser-hibernation-webkit,
and the report as DIR/bench-hibernation.json. The pressure phase writes no result-v1 series.
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
import bench_memory as bm  # noqa: E402  (App, owned, sample, note_child_launch)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)
import browser_engine_bench_report as results  # noqa: E402
import bench_renderer_sharing as brs  # noqa: E402  (renderer_map)
from bench_launch import BenchApp, features_snapshot, load_by_path, tag_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf-bench"))
import procs  # noqa: E402  (priorities: a task's base priority and darwinbg bit)

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


def wake_q(rows: list[dict], key: str, q: float):
    """The q-quantile of the wakes' `key` in ms, one decimal (perf_stats.pct); None when no wake gave one."""
    return results.pct([r.get(key) for r in rows], q, 1)


# --- Hidden renderers: backgrounded and purged (--background-timeline) ---

# The share of a hidden page's 0 s PMF that a purge must give back by the last point.
PMF_FALL_PCT = 10.0
# --heap-mb of the hidden-renderer phase: a live array is memory MemoryPurgeManager cannot free, so a pinned heap
# lowers the share a correct purge gives back.
TIMELINE_HEAP_MB = 0
# --heap-mb of the other phases: a real site's heap, which hibernation frees with the page.
HIBERNATION_HEAP_MB = 40
# The default-off feature that sends a tab's hide to Chromium (fork API 37, CEFTabNodeVisibility.swift); the
# timeline prints its state, and runs with --feature chromiumTabVisibility=on and =off.
TAB_VISIBILITY_FEATURE = "chromiumTabVisibility"
# CEFForkFeatures.tabVisibilityForkAPI: below it the feature makes no call.
TAB_VISIBILITY_FORK_API = 37


def idle_budget():
    """idle-budget.py, loaded by path once: its observed_role and ROLE_EXPECTATIONS read a task's role the way
    the idle audit does."""
    return load_by_path("idle_budget", os.path.join(os.path.dirname(os.path.abspath(__file__)), "idle-budget.py"))


def backgrounded_roles() -> set[str]:
    """The observed roles of a renderer Chrome runs at Priority::kBestEffort: Process::SetPriority
    (base/process/process_mac.cc) sets TASK_BACKGROUND_APPLICATION with a TASK_SUPPRESSION_POLICY, which lowers
    the task's base priority (suppressed) or sets darwin background (darwinbg)."""
    return set(idle_budget().ROLE_EXPECTATIONS["best-effort"])


def task_roles(pids, priorities_of=None) -> dict[int, dict]:
    """{pid: {role, base}} of `pids` now; a pid that is gone is left out. `role` is idle-budget's observed_role
    (darwinbg, suppressed or default), `base` the task's base priority. Tests pass `priorities_of`."""
    observed = idle_budget().observed_role
    found = (priorities_of or procs.priorities)(pids)
    return {pid: {"role": observed(priority), "base": priority.get("base")} for pid, priority in found.items()}


def footprint_bytes(pid: int):
    """phys_footprint of `pid` now (Chrome's private memory footprint on macOS:
    process_memory_metrics_emitter.cc), or None once it is gone."""
    got = bm.usage(pid)
    return got[1] if got else None


def own_renderers(sock: str) -> dict[str, list[int]]:
    """{tab: renderer pids that host that tab and no other} from the app's `resources` report."""
    mapping = brs.renderer_map(sock)
    if "error" in mapping:
        print(f"   resources: {mapping['error']}", file=sys.stderr)
        return {}
    found: dict[str, list[int]] = {}
    for pid, tabs in mapping["owners"].items():
        if len(tabs) == 1:
            found.setdefault(tabs[0], []).append(pid)
    return found


def counts_text(counts: dict[str, int]) -> str:
    return ",".join(f"{key}:{value}" for key, value in sorted(counts.items())) or "none"


def hidden_point(mode: str, point: float, hidden_at: float, tabs: list[str], renderers: dict[str, list[int]],
                 front: str, frozen: set[str], footprint_of=footprint_bytes, roles_of=task_roles) -> dict:
    """One sample of the hidden pages' own renderers: PMF per page and each renderer's task role."""
    hidden_pids = [pid for tab in tabs for pid in renderers.get(tab, [])]
    roles_now = roles_of(hidden_pids + renderers.get(front, []))
    per_tab, roles, bases = [], {}, []
    for tab in tabs:
        footprint, seen = 0, False
        for pid in renderers.get(tab, []):
            got, role = footprint_of(pid), roles_now.get(pid)
            if got is None or role is None:
                continue
            seen = True
            footprint += got
            name = role["role"] or "unread"
            roles[name] = roles.get(name, 0) + 1
            if role["base"] is not None:
                bases.append(role["base"])
        if seen:
            per_tab.append(footprint / bm.MB)
    front_roles = sorted({roles_now[pid]["role"] or "unread" for pid in renderers.get(front, []) if pid in roles_now})
    row = {"freeze": mode, "at_s": point, "measured_at_s": round(time.monotonic() - hidden_at, 1),
           "tabs": len(tabs), "measured_tabs": len(per_tab),
           "per_hidden_tab_pmf_mb": round(sum(per_tab) / len(per_tab), 1) if per_tab else None,
           "max_hidden_tab_pmf_mb": round(max(per_tab), 1) if per_tab else None,
           "renderer_task_role": roles, "renderer_base_priority": sorted(bases),
           "front_task_role": ",".join(front_roles) or None, "frozen": len(frozen & set(tabs))}
    print(f"PERF-HIBERNATE-BACKGROUND freeze={mode} at_s={point:g} measured_at_s={row['measured_at_s']} "
          f"per_hidden_tab_pmf_mb={row['per_hidden_tab_pmf_mb']} max_hidden_tab_pmf_mb={row['max_hidden_tab_pmf_mb']} "
          f"renderer_task_role={counts_text(roles)} "
          f"renderer_base_priority={','.join(map(str, row['renderer_base_priority'])) or None} "
          f"front_task_role={row['front_task_role']} frozen={row['frozen']}/{len(tabs)} "
          f"measured={len(per_tab)}/{len(tabs)}", flush=True)
    return row


def timeline_summary(mode: str, rows: list[dict], background: set[str] | None = None) -> dict:
    """Whether the hidden renderers were backgrounded and their PMF fell between the first and last point."""
    background = backgrounded_roles() if background is None else background
    pmf = [row["per_hidden_tab_pmf_mb"] for row in rows]
    first, last = pmf[0], pmf[-1]
    fell_mb = round(first - last, 1) if first is not None and last is not None else None
    fell_pct = round(100 * fell_mb / first, 1) if fell_mb is not None and first else None
    # Backgrounded: every measured hidden renderer has a background role at the second point (30 s).
    settled = rows[min(1, len(rows) - 1)]
    roles = settled["renderer_task_role"]
    backgrounded = bool(roles) and set(roles) <= background
    # Measured: a role read for every hidden renderer at the role point and a PMF at the first and last point.
    # Without them (resources error, shared renderers, unread priorities) the mode says nothing about Chromium.
    measured = bool(roles) and "unread" not in roles and first is not None and last is not None
    summary = {"freeze": mode, "pmf_mb": {f"{row['at_s']:g}s": row["per_hidden_tab_pmf_mb"] for row in rows},
               "fell_mb": fell_mb, "fell_pct": fell_pct, "pmf_falls": fell_pct is not None and fell_pct >= PMF_FALL_PCT,
               "backgrounded": backgrounded, "measured": measured, "roles_at": f"{settled['at_s']:g}s",
               "roles": roles, "frozen_at_end": rows[-1]["frozen"], "tabs": rows[-1]["tabs"]}
    print(f"PERF-HIBERNATE-BACKGROUND-SUMMARY freeze={mode} measured={measured} "
          f"pmf_mb={','.join(f'{key}:{value}' for key, value in summary['pmf_mb'].items())} "
          f"fell_mb={fell_mb} fell_pct={fell_pct} pmf_falls={summary['pmf_falls']} "
          f"backgrounded={backgrounded} roles_at_{summary['roles_at']}={counts_text(roles)} "
          f"frozen_at_end={summary['frozen_at_end']}/{summary['tabs']}", flush=True)
    return summary


def background_verdict(summaries: list[dict]) -> str:
    """`unmeasured` when no mode ran or a mode measured no hidden renderer (rerun; file nothing); `none` when
    every mode backgrounded its hidden renderers and their PMF fell; else `shim-visibility`, the follow-up."""
    if not summaries or not all(s["measured"] for s in summaries):
        return "unmeasured"
    if all(s["backgrounded"] and s["pmf_falls"] for s in summaries):
        return "none"
    return "shim-visibility"


def background_timeline(app: bm.App, sock: str, ports: list[int], count: int, open_tab, front: str,
                        opened_extra: list[str], points: list[float], modes: list[str], freeze: float,
                        heap_mb: int, features: dict | None = None) -> dict:
    """Per freeze mode: new hidden pages' own renderer PMF and task role at each point after the hide.
    The bench's last script call starts the agent grace (30 s), so a page freezes at the later of
    --freeze and that grace; each point prints how many were frozen."""
    visibility = ((features or {}).get(TAB_VISIBILITY_FEATURE) or {}).get("state")
    fork = brs.fork_api(bp.rpc(sock, "debug.cef") or {})
    result: dict = {"points_s": points, "modes": {}, "tab_visibility": visibility, "fork_api": fork,
                    "tab_visibility_fork_api": TAB_VISIBILITY_FORK_API, "heap_mb": heap_mb}
    print(f"PERF-HIBERNATE-BACKGROUND-START {TAB_VISIBILITY_FEATURE}={visibility} fork_api={fork} heap_mb={heap_mb} "
          f"modes={','.join(modes)} points_s={','.join(f'{point:g}' for point in points)}", flush=True)
    for number, mode in enumerate(modes):
        value = freeze if mode == "on" else "off"
        answer = bp.rpc(sock, "settings.set", {"path": "browser.freezeHiddenTabs", "value": value})
        if answer.get("error"):
            print(f"   settings.set browser.freezeHiddenTabs {value}: {answer['error']}", file=sys.stderr)
        # New sites each mode, so each mode starts with new renderers.
        tabs = []
        for index in range(200 + 100 * number, 200 + 100 * number + count):
            tab = open_tab("chromium", page_url("chromium", index, ports))
            if tab:
                tabs.append(tab)
                opened_extra.append(tab)
        app.run("tab.focus", target=front)
        hidden_at = time.monotonic()

        def mapped():
            found = own_renderers(sock)
            return found if front in found and all(tab in found for tab in tabs) else None

        renderers = wait_for(mapped, 10, 0.5) or own_renderers(sock)
        missing = [tab for tab in tabs if tab not in renderers]
        if missing:
            print(f"   {len(missing)} hidden tabs share a renderer or have none; they are not measured", file=sys.stderr)
        rows = []
        for point in points:
            left = hidden_at + point - time.monotonic()
            if left > 0:
                time.sleep(left)  # test script: the next sample point after the hide
            frozen = set(hibernation(sock).get("frozen") or [])
            rows.append(hidden_point(mode, point, hidden_at, tabs, renderers, front, frozen))
        result["modes"][mode] = {"tabs": tabs, "renderers": {tab: renderers.get(tab, []) for tab in tabs},
                                 "points": rows, "summary": timeline_summary(mode, rows)}
        for tab in tabs:
            app.run("tab.close", target=tab)
            opened_extra.remove(tab)
    result["follow_up"] = background_verdict([entry["summary"] for entry in result["modes"].values()])
    print(f"PERF-HIBERNATE-BACKGROUND-VERDICT follow_up={result['follow_up']} {TAB_VISIBILITY_FEATURE}={visibility} "
          f"(memory-DESIGN.md, \"Hidden Chromium pages: backgrounded and purged\")", flush=True)
    return result


def launched_features(bench, sock: str) -> dict | None:
    """{name: {state, source}} of the app's features.list: the launch's snapshot, else an attached app's answer;
    None when the app gave none."""
    snapshot = bench.features if bench is not None and bench.features else features_snapshot(bp.rpc(sock, "features.list"))
    return snapshot[0] if snapshot else None


def feature_choice(text: str) -> tuple[str, bool]:
    """NAME=on|off: one Labs local feature choice for the launch (BenchApp local_features)."""
    name, _, value = text.partition("=")
    if not name or value not in ("on", "off"):
        raise argparse.ArgumentTypeError("NAME=on or NAME=off, for example chromiumTabVisibility=on")
    return name, value == "on"


def seconds_list(text: str) -> list[float]:
    try:
        points = sorted({float(item) for item in text.split(",") if item.strip()})
    except ValueError:
        points = []
    if not points or points[0] < 0:
        raise argparse.ArgumentTypeError("seconds after the hide, for example 0,30,300,600")
    return points


def freeze_modes(text: str) -> list[str]:
    modes = [item.strip() for item in text.split(",") if item.strip()]
    if not modes or any(mode not in ("off", "on") for mode in modes) or len(set(modes)) != len(modes):
        raise argparse.ArgumentTypeError("off, on or off,on")
    return modes


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--tabs", type=int, default=6, help="tabs per engine")
    parser.add_argument("--engines", default="chromium,webkit")
    parser.add_argument("--heap-mb", type=int, help=f"MB of live array per page (default {HIBERNATION_HEAP_MB}; "
                                                    f"{TIMELINE_HEAP_MB} with --background-timeline)")
    parser.add_argument("--measure", type=float, default=20, help="seconds each phase's CPU is measured over")
    parser.add_argument("--freeze", type=float, default=10, help="browser.freezeHiddenTabs for the run")
    parser.add_argument("--config", default="{}", help="extra cmux.json settings (JSON)")
    parser.add_argument("--pressure", action="store_true", help="also simulate critical memory pressure")
    parser.add_argument("--pressure-reuse", action="store_true", help="pressure the bench tabs instead of opening new ones")
    parser.add_argument("--pressure-wait", type=float, default=0, help="seconds to wait for the pages under pressure (0: 1.5 s per page, at least 30)")
    parser.add_argument("--background-timeline", type=seconds_list, metavar="S,S,...",
                        help="only the hidden-renderer phase: sample at these seconds after the hide (0,30,300,600)")
    parser.add_argument("--background-freeze", type=freeze_modes, default=["off", "on"], metavar="off,on",
                        help="freeze modes of the hidden-renderer phase, in order (on: --freeze seconds)")
    parser.add_argument("--feature", type=feature_choice, action="append", default=[], metavar="NAME=on|off",
                        help="launch: a Labs local feature choice (for example chromiumTabVisibility=on); repeatable")
    parser.add_argument("--socket", help="attach: the running app's control socket")
    parser.add_argument("--app-pid", type=int, help="attach: the running app's pid")
    parser.add_argument("--out", help="the report file (.json), or the lab runner's folder for the result-v1 files "
                                      "and bench-hibernation.json")
    parser.add_argument("--tag", help="the lab runner's tag of --app (checked against the bundle's name)")
    parser.add_argument("--session", choices=["light"], default="light", help="result-v1 session")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    args = parser.parse_args(argv)
    if args.tag is not None and tag_of(f"cmux DEV {args.tag}.app") != tag_of(args.app):
        parser.error(f"--tag {args.tag!r} is not the tag of --app {args.app!r}")
    if args.feature and args.socket:
        parser.error("--feature sets a launch's Labs choices; an attached app keeps its own")
    if args.heap_mb is None:
        args.heap_mb = TIMELINE_HEAP_MB if args.background_timeline else HIBERNATION_HEAP_MB
    if args.heap_mb < 0:
        parser.error("--heap-mb is 0 or more")
    return args


def main(argv=None):
    # --workspaces N: workspace hibernation instead (bench_workspace_hibernation.py), so the reviewed
    # scripts/measure/tab-hibernation.sh runs it on the fleet: --arg=--workspaces=50.
    argv_list = sys.argv[1:] if argv is None else list(argv)
    if any(arg == "--workspaces" or arg.startswith("--workspaces=") for arg in argv_list):
        import bench_workspace_hibernation
        sys.exit(bench_workspace_hibernation.run(argv_list))
    args = parse(argv)
    report_path, results_dir = results.out_paths(args.out, "bench-hibernation.json")
    if sys.platform != "darwin":
        raise SystemExit("bench-hibernation: macOS only (run it on a fleet or capture mini)")
    _Handler.heap_mb = args.heap_mb
    engines = [e for e in args.engines.split(",") if e]
    ports = [serve() for _ in range(max(1, args.tabs))]
    # No neighbors: a tab beside the shown one would wake in the background before it is timed.
    # The hidden-renderer phase keeps every page loaded (hibernation off) for its whole timeline.
    timeline = args.background_timeline
    config = bm.merged({"browser": {"hibernation": "off" if timeline else "moderate", "freezeHiddenTabs": args.freeze,
                                    "keepNeighborTabsAwake": 0}},
                       json.loads(args.config))
    bundle = os.path.realpath(args.app)
    signal.signal(signal.SIGTERM, bm.interrupted)
    if args.socket:
        if not args.app_pid:
            raise SystemExit("bench-hibernation: --socket needs --app-pid")
        pid, sock, launched = args.app_pid, args.socket, False
        bench = None  # an attached app is any app a capture slot started; only result-v1 needs a tagged DEV bundle
        if results_dir:
            # result-v1 for an attached app: its build, this host, and the features it answers now.
            bench = BenchApp(bundle, out=results_dir, teardown=False, build_config=args.build_config,
                             perf_session=args.session)
            bench.socket = sock
            bench.features = bench.read_features()
        for path, value in flatten(config):
            answer = bp.rpc(sock, "settings.set", {"path": path, "value": value})
            if answer.get("error"):
                print(f"   settings.set {path}: {answer['error']}", file=sys.stderr)
    else:
        bp.wipe_state(bundle)  # also the bundle's Chromium profile and caches, which BenchApp's fresh state keeps
        bench = BenchApp(bundle, out=results_dir, config=config, window=(40, 40, 1400, 900),
                         build_config=args.build_config, perf_session=args.session, local_features=dict(args.feature))
        bm.note_child_launch()  # the app is this script's child (bench_memory.webkit_is_apps)
        try:
            bench.launch()
        except BaseException:
            bench.stop()
            raise
        pid, sock, launched = bench.process.pid, bench.socket, True
    app = bm.App(bundle, sock)
    report = {"app": bundle, "tabs": args.tabs, "heap_mb": args.heap_mb, "config": config, "phases": [], "wakes": [],
              "features": launched_features(bench, sock)}
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
        if timeline:
            front = open_tab("chromium", f"http://front.localhost:{ports[0]}/?n=front")
            opened_extra.append(front)
            report["background"] = background_timeline(app, sock, ports, args.tabs, open_tab, front, opened_extra,
                                                       timeline, args.background_freeze, args.freeze,
                                                       args.heap_mb, features=report["features"])
            return
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
        series = []
        for engine, kind in (("chromium", "cef-renderer"), ("webkit", "webkit-webcontent")):
            count = len(opened.get(engine, []))
            if not count:
                continue
            # The bench tabs' own processes: those that exited when they hibernated.
            gone = exited(phases["awake"], phases["hibernated"], kind)
            rows = [w for w in report["wakes"] if w["engine"] == engine]
            frozen_rows = None
            if "frozen" in phases:
                pids = {row["pid"] for row in gone}
                frozen_rows = [row for row in phases["frozen"]["processes"] if row["pid"] in pids]
            series += results.hibernation_series(engine, count, gone, rows, frozen_rows, session=args.session)
            summary[engine] = {
                "tabs": count, "processes_exited": len(gone),
                "freed_mb_per_tab": round((total(gone, "footprint_mb") or 0) / count, 1),
                "kind_delta_mb": round(phases["awake"]["kinds"].get(kind, {}).get("footprint_mb", 0)
                                       - phases["hibernated"]["kinds"].get(kind, {}).get("footprint_mb", 0), 1),
                "app_delta_mb": round(phases["awake"]["total_footprint_mb"] - phases["hibernated"]["total_footprint_mb"], 1),
                "hidden_cpu_pct": total(gone, "cpu_pct"), "hidden_wakeups_per_s": total(gone, "wakeups_per_s"),
                "frozen_cpu_pct": total(gone, "cpu_pct", phases["frozen"]) if "frozen" in phases else None,
                "frozen_wakeups_per_s": total(gone, "wakeups_per_s", phases["frozen"]) if "frozen" in phases else None,
                "mounted_p50_ms": wake_q(rows, "mounted_ms", 0.5),
                "usable_p50_ms": wake_q(rows, "usable_ms", 0.5),
                "usable_p90_ms": wake_q(rows, "usable_ms", 0.9),
                "usable_p95_ms": wake_q(rows, "usable_ms", 0.95),
                "usable_p99_ms": wake_q(rows, "usable_ms", 0.99),
                "mounted_p95_ms": wake_q(rows, "mounted_ms", 0.95),
                "mounted_p99_ms": wake_q(rows, "mounted_ms", 0.99),
                "app_mounted_p95_ms": wake_q(rows, "app_mounted_ms", 0.95),
                "app_mounted_p99_ms": wake_q(rows, "app_mounted_ms", 0.99),
                "restored_p50_ms": wake_q(rows, "restored_ms", 0.5),
                "app_mounted_p50_ms": wake_q(rows, "app_mounted_ms", 0.5),
                "loaded_p50_ms": wake_q(rows, "loaded_ms", 0.5),
                "loaded_p90_ms": wake_q(rows, "loaded_ms", 0.9),
                "loaded_p99_ms": wake_q(rows, "loaded_ms", 0.99),
                "snapshots": sum(1 for r in rows if r.get("snapshot")),
                "scroll_restored": sum(1 for r in rows if r["scroll_ok"]), "form_restored": sum(1 for r in rows if r["form_ok"]),
                "woken": len(rows),
            }
            s = summary[engine]
            print(f"PERF-HIBERNATE-SUMMARY engine={engine} tabs={count} freed_mb_per_tab={s['freed_mb_per_tab']} "
                  f"processes_exited={s['processes_exited']} app_delta_mb={s['app_delta_mb']} "
                  f"hidden_cpu_pct={s['hidden_cpu_pct']} frozen_cpu_pct={s['frozen_cpu_pct']} "
                  f"hidden_wakeups_per_s={s['hidden_wakeups_per_s']} frozen_wakeups_per_s={s['frozen_wakeups_per_s']} "
                  f"mounted_p50_ms={s['mounted_p50_ms']} mounted_p95_ms={s['mounted_p95_ms']} mounted_p99_ms={s['mounted_p99_ms']} "
                  f"usable_p50_ms={s['usable_p50_ms']} usable_p90_ms={s['usable_p90_ms']} usable_p95_ms={s['usable_p95_ms']} "
                  f"usable_p99_ms={s['usable_p99_ms']} app_mounted_p95_ms={s['app_mounted_p95_ms']} "
                  f"app_mounted_p99_ms={s['app_mounted_p99_ms']} "
                  f"restored_p50_ms={s['restored_p50_ms']} app_mounted_p50_ms={s['app_mounted_p50_ms']} "
                  f"loaded_p50_ms={s['loaded_p50_ms']} loaded_p90_ms={s['loaded_p90_ms']} loaded_p99_ms={s['loaded_p99_ms']} "
                  f"snapshots={s['snapshots']}/{s['woken']} scroll={s['scroll_restored']}/{s['woken']} "
                  f"form={s['form_restored']}/{s['woken']}", flush=True)
        report["summary"] = summary
        if results_dir:  # a finished run: its phases and wakes are complete
            report["results_v1"] = results.record_all(bench, series)
        if args.pressure:
            reuse = [t for e in engines for t in opened[e]] if args.pressure_reuse else None
            report["pressure"] = pressure(app, sock, engines, ports, args.tabs, open_tab, front, opened_extra,
                                          reuse=reuse, wait=args.pressure_wait, pid=pid, bundle=bundle,
                                          measure=args.measure, report=report)
    finally:
        if launched:
            bench.stop()
        else:
            for tab in [t for tabs in opened.values() for t in tabs] + opened_extra:
                app.run("tab.close", target=tab)
            if bench is not None:  # it launched nothing: its scratch folder holds no app state
                shutil.rmtree(bench.scratch, ignore_errors=True)
        if report_path:
            with open(report_path, "w") as handle:
                json.dump(report, handle, indent=1)
            print(f"bench-hibernation: wrote {report_path}")


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
        feed_pressure(sock, "none")  # clears the override; "normal" would hold it
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
