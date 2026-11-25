#!/usr/bin/env python3
"""renderer-rest (split-spring-terminal.py --suite=renderer-rest): does a Chromium renderer grow while the app rests,
which one, what page it hosts, and does it level off (CMUX-571, goal ram-baseline).

Leo, 2026-11-12: "Infinite everything feels like nothing". The Settings-spare A/B (#43767) saw `cef-renderer` go from
288 to 345 MB in about 20 s with nothing happening, and 286-332 MB across launches at the 20 s point.

Each launch (--launches, default 3) starts the empty app (bench_memory.launch, the memory-agents launch) and, every
--every seconds for --seconds after the socket opens:
- each cef-renderer process's phys_footprint and CPU (proc_pid_rusage, bench_memory.sample), by pid;
- which pages each renderer hosts (`debug.cef_pages`, matched by `--renderer-client-id`, bench_power.renderer_roles);
- with page reads on (the default; --no-page-reads leaves only the process reads), each cmux page's
  `Performance.getMetrics` (JS heap used/total, Nodes, Documents, JSEventListeners, LayoutCount, RecalcStyleCount,
  TaskDuration, ScriptDuration), which costs the page a metrics read and nothing else.
At the start a V8 sampling heap profile starts on each cmux page (HeapProfiler.startSampling); at the end the run reads it
(the live sampled bytes by function and script), reads each page's state (`Runtime.evaluate`: running animations,
images, canvases, resource-timing entries, rAF callbacks in 1 s), then collects garbage (HeapProfiler.collectGarbage)
and samples again, then sends a critical memory-pressure notice and samples again. So the report says whether the
growth is uncollected V8 heap, something the page holds, or Chromium caches a purge gives back.
`vmmap --summary` of each renderer at the first and last sample says which region grew (when vmmap can read it).

report.json: `launches` (each: the timeline, the per-renderer summary, the end states), `summary` (per launch and role:
first, at 20 s, at the end, peak, growth after 60 s per minute: a plateau reads near 0) and report-only rows
memory.renderer_rest.* (never judged).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MB = 1024 * 1024
METRICS = ("JSHeapUsedSize", "JSHeapTotalSize", "Nodes", "Documents", "JSEventListeners", "LayoutCount",
           "RecalcStyleCount", "TaskDuration", "ScriptDuration", "LayoutObjects", "Frames")
STATE_JS = """(async () => {
  let raf = 0; const until = performance.now() + 1000;
  await new Promise(done => { const tick = () => { raf++; performance.now() < until ? requestAnimationFrame(tick) : done(); };
    requestAnimationFrame(tick); setTimeout(done, 1500); });
  const anims = document.getAnimations ? document.getAnimations() : [];
  return {path: location.pathname, visibility: document.visibilityState, focus: document.hasFocus(),
    nodes: document.getElementsByTagName('*').length, images: document.images.length,
    canvases: document.querySelectorAll('canvas').length, videos: document.querySelectorAll('video').length,
    iframes: document.querySelectorAll('iframe').length,
    animations_running: anims.filter(a => a.playState === 'running').length, animations: anims.length,
    animation_names: [...new Set(anims.filter(a => a.playState === 'running').map(a => a.animationName || (a.effect && a.effect.target && a.effect.target.className) || a.constructor.name))].slice(0, 12).map(String),
    resource_entries: performance.getEntriesByType('resource').length,
    raf_in_1s: raf};
})()"""


def role_of(page: dict) -> str:
    """A page's role: a cmux page by its path (`/home`, `/agent`, ...), else its scheme (pure)."""
    origin = str(page.get("origin") or "")
    if origin.startswith("cmux-page://"):
        name = origin[len("cmux-page://"):].strip("/") or "?"
        path = str(page.get("path") or "/")
        role = f"{name}{path if path != '/' else ''}"
    elif origin.startswith(("http://", "https://")):
        role = "browser-tab"
    else:
        role = origin.split(":", 1)[0] or "blank"
    return role + (" (hidden)" if page.get("hidden") else "")


def client_of(cmd: str) -> int | None:
    found = re.search(r"--renderer-client-id=(\d+)", cmd)
    return int(found.group(1)) if found else None


def roles_by_pid(pages: list, renderers: dict) -> dict[int, str]:
    """{renderer pid: the roles of the pages it hosts} (pure). `renderers` maps pid to its command; a renderer that
    hosts no listed page reads `no page` (a spare process Chromium keeps ready, or one between pages)."""
    by_client = {client_of(cmd): pid for pid, cmd in renderers.items() if client_of(cmd) is not None}
    names: dict[int, set] = {pid: set() for pid in renderers}
    for page in pages or []:
        for client in page.get("renderer_clients") or []:
            pid = by_client.get(int(client))
            if pid is not None:
                names[pid].add(role_of(page))
    return {pid: " + ".join(sorted(roles)) or "no page" for pid, roles in names.items()}


def growth_per_min(points: list[tuple[float, float]], after: float = 60.0) -> float | None:
    """Least-squares slope (MB per minute) of (seconds, MB) points at or after `after` s (pure). None with fewer
    than 3 such points. A plateau reads near 0; a steady leak keeps a positive slope."""
    tail = [(t, v) for t, v in points if t >= after]
    if len(tail) < 3:
        return None
    n = len(tail)
    mt = sum(t for t, _ in tail) / n
    mv = sum(v for _, v in tail) / n
    den = sum((t - mt) ** 2 for t, _ in tail)
    if den == 0:
        return None
    return round(60 * sum((t - mt) * (v - mv) for t, v in tail) / den, 2)


def at(points: list[tuple[float, float]], seconds: float) -> float | None:
    """The value of the first point at or after `seconds` (pure)."""
    return next((v for t, v in points if t >= seconds), None)


def summarize(timeline: list[dict]) -> dict:
    """Per renderer pid (pure): its role(s), footprint first, at 20 s, at the end, peak, growth after 60 s, and the
    JS heap of the pages it hosts at the same points (the largest page read: pages of one renderer share an isolate)."""
    out: dict[str, dict] = {}
    for point in timeline:
        t = point["t"]
        for row in point.get("renderers") or []:
            entry = out.setdefault(str(row["pid"]), {"pid": row["pid"], "roles": set(), "mb": [], "js_heap_mb": [],
                                                     "nodes": []})
            entry["roles"].add(row.get("role") or "no page")
            entry["mb"].append((t, row["footprint_mb"]))
            heaps = [m.get("JSHeapUsedSize") for m in row.get("page_metrics") or [] if isinstance(m.get("JSHeapUsedSize"), (int, float))]
            if heaps:
                entry["js_heap_mb"].append((t, round(max(heaps) / MB, 1)))
            nodes = [m.get("Nodes") for m in row.get("page_metrics") or [] if isinstance(m.get("Nodes"), (int, float))]
            if nodes:
                entry["nodes"].append((t, sum(nodes)))
    result = {}
    for pid, entry in out.items():
        mb = entry["mb"]
        last_t = mb[-1][0] if mb else 0
        row = {"pid": entry["pid"], "roles": sorted(entry["roles"]), "first_mb": mb[0][1] if mb else None,
               "first_t": mb[0][0] if mb else None, "at20_mb": at(mb, 20), "at60_mb": at(mb, 60), "end_mb": mb[-1][1] if mb else None,
               "end_t": last_t, "peak_mb": max(v for _, v in mb) if mb else None,
               "growth_after_60s_mb_per_min": growth_per_min(mb)}
        for key in ("js_heap_mb", "nodes"):
            series = entry[key]
            if series:
                row[key] = {"first": series[0][1], "at20": at(series, 20), "end": series[-1][1],
                            "growth_after_60s_per_min": growth_per_min(series)}
        result[pid] = row
    return result


def rows_from(launches: list[dict]) -> list[dict]:
    """Report-only rows (pure): the median over launches of the renderers' summed footprint at 20 s and at the end,
    and of its growth after 60 s per minute."""
    def median(values):
        values = sorted(v for v in values if isinstance(v, (int, float)))
        return values[len(values) // 2] if values else None

    def total(point):
        return round(sum(r["footprint_mb"] for r in point.get("renderers") or []), 1)

    at20, end, slope = [], [], []
    for launch in launches:
        series = [(p["t"], total(p)) for p in launch.get("timeline") or []]
        if not series:
            continue
        at20.append(at(series, 20))
        end.append(series[-1][1])
        slope.append(growth_per_min(series))
    rows = []
    for name, values, unit in (("cef_renderer_at20s_mb", at20, "MB"), ("cef_renderer_end_mb", end, "MB"),
                               ("cef_renderer_growth_after_60s_mb_per_min", slope, "MB/min")):
        value = median(values)
        if value is not None:
            rows.append({"name": f"memory.renderer_rest.{name}", "p50": value, "p95": value, "unit": unit,
                         "floor": 10.0, "launches": values})
    return rows


# ---- on the Mac -------------------------------------------------------------------------------------------------

def run_launch(bm, index: int, args) -> dict:
    bundle = os.path.realpath(args.app)
    started = time.monotonic()
    pid, sock, scratch = bm.launch(bundle, {})
    app = bm.App(bundle, sock)
    socket_s = round(time.monotonic() - started, 1)
    print(f"renderer-rest: launch {index}: app pid {pid}, socket after {socket_s} s", flush=True)
    timeline: list[dict] = []
    sampling: set = set()
    enabled: set = set()
    vmmaps: dict = {}

    def devtools(browser, method, params=None, timeout=20):
        reply = app.call("debug.cef_page_devtools", {"browser": browser, "method": method, "params": params or {}},
                         timeout=timeout)
        if reply.get("error") or not isinstance(reply.get("result"), str):
            return {"error": str(reply.get("error") or "no reply")[:200]}
        try:
            return json.loads(reply["result"])
        except ValueError as error:
            return {"error": str(error)}

    def cmux_pages(pages):
        return [p for p in pages if str(p.get("origin", "")).startswith("cmux-page://") and "browser" in p]

    def read_point(label: str, page_reads: bool) -> dict:
        t = round(time.monotonic() - started, 1)
        sample = bm.sample(pid, bundle, label, 1)
        pages = (app.call("debug.cef_pages", timeout=30) or {}).get("pages") or []
        renderers = {r["pid"]: r["command"] for r in sample["processes"] if r["kind"] == "cef-renderer"}
        # The 160-character command bench_memory keeps may cut the client id off: read the full one.
        full = {p: c for p, _pp, c in bm.process_table() if p in renderers}
        roles = roles_by_pid(pages, {p: full.get(p, c) for p, c in renderers.items()})
        metrics = {}
        if page_reads:
            for page in cmux_pages(pages):
                b = page["browser"]
                if b not in enabled:
                    devtools(b, "Performance.enable")
                    enabled.add(b)
                reply = devtools(b, "Performance.getMetrics")
                values = {m["name"]: m["value"] for m in reply.get("metrics", []) if m.get("name") in METRICS} if "metrics" in reply else reply
                values["role"] = role_of(page)
                metrics[b] = (values, page.get("renderer_clients") or [])
                if args.heap_sampling and b not in sampling:
                    devtools(b, "HeapProfiler.startSampling", {"samplingInterval": 16384})
                    sampling.add(b)
        rows = []
        for r in sample["processes"]:
            if r["kind"] != "cef-renderer":
                continue
            client = client_of(full.get(r["pid"], r["command"]))
            row = {"pid": r["pid"], "client": client, "role": roles.get(r["pid"]), "footprint_mb": r["footprint_mb"],
                   "rss_mb": r["rss_mb"], "max_footprint_mb": r["max_footprint_mb"]}
            row["page_metrics"] = [m for m, clients in metrics.values() if client is not None and client in [int(c) for c in clients]]
            rows.append(row)
        point = {"t": t, "label": label, "total_footprint_mb": sample["total_footprint_mb"],
                 "kinds": {k: v["footprint_mb"] for k, v in sample["kinds"].items()}, "renderers": rows,
                 "pages": [{"browser": p.get("browser"), "role": role_of(p), "clients": p.get("renderer_clients")} for p in pages]}
        print(f"renderer-rest: launch {index} t={t:6.1f}s total {sample['total_footprint_mb']:7.1f} MB  "
              + "  ".join(f"[{r['pid']} {r['role']}: {r['footprint_mb']} MB"
                          + (f", heap {round(max(m.get('JSHeapUsedSize', 0) for m in r['page_metrics']) / MB, 1)} MB"
                             f", nodes {sum(m.get('Nodes', 0) for m in r['page_metrics'])}" if r['page_metrics'] else "") + "]"
                          for r in rows), flush=True)
        return point

    def vmmap(label):
        for r in (timeline[-1]["renderers"] if timeline else []):
            out = subprocess.run(["vmmap", "--summary", str(r["pid"])], capture_output=True, text=True, timeout=60)
            text = out.stdout if out.returncode == 0 else (out.stderr or out.stdout)[:400]
            vmmaps.setdefault(str(r["pid"]), {})[label] = vmmap_regions(text) if out.returncode == 0 else {"error": text}

    try:
        deadline = started + socket_s + args.seconds
        next_at = time.monotonic()
        while time.monotonic() < deadline:
            timeline.append(read_point("rest", args.page_reads))
            if len(timeline) == 2 and args.vmmap:
                vmmap("first")
            next_at += args.every
            time.sleep(max(0.0, next_at - time.monotonic()))  # test script: the sampling interval at rest
        if args.vmmap:
            vmmap("end")
        end: dict = {}
        pages = cmux_pages((app.call("debug.cef_pages", timeout=30) or {}).get("pages") or [])
        for page in pages:
            b = page["browser"]
            state = devtools(b, "Runtime.evaluate", {"expression": STATE_JS, "awaitPromise": True, "returnByValue": True},
                             timeout=30)
            entry = {"role": role_of(page), "clients": page.get("renderer_clients"),
                     "state": (state.get("result") or {}).get("value", state)}
            if b in sampling:
                profile = devtools(b, "HeapProfiler.getSamplingProfile", timeout=60)
                devtools(b, "HeapProfiler.stopSampling", timeout=60)
                entry["heap_sampling_top"] = sampling_top(profile.get("profile") or {}) if "profile" in profile else profile
            entry["heap_usage"] = devtools(b, "Runtime.getHeapUsage")
            end[str(b)] = entry
        rest_point = read_point("end-rest", True)
        for page in pages:
            devtools(page["browser"], "HeapProfiler.collectGarbage", timeout=60)
        time.sleep(args.after_s)  # test script: let the renderers return what the collection freed
        gc_point = read_point("after-gc", True)
        for page in pages:
            devtools(page["browser"], "Memory.simulatePressureNotification", {"level": "critical"})
        time.sleep(args.after_s)  # test script: the same after the purge
        purge_point = read_point("after-purge", True)
        for page in pages:
            usage = devtools(page["browser"], "Runtime.getHeapUsage")
            end[str(page["browser"])]["heap_usage_after"] = usage
        return {"index": index, "app_pid": pid, "socket_s": socket_s, "timeline": timeline, "summary": summarize(timeline),
                "end_pages": end, "end_points": {"rest": rest_point, "after_gc": gc_point, "after_purge": purge_point},
                "vmmap": vmmaps}
    finally:
        bm.end_bundle(bundle)
        import shutil
        shutil.rmtree(scratch, ignore_errors=True)


def vmmap_regions(text: str, top: int = 14) -> dict:
    """`vmmap --summary`'s region table: {region: dirty MB (dirty + swapped)} for the largest (pure)."""
    sizes = {}
    unit = {"K": 1 / 1024, "M": 1.0, "G": 1024.0, "B": 1 / MB}
    for line in text.splitlines():
        found = re.match(r"^(\S.*?)\s{2,}(\d+(?:\.\d+)?)([KMGB])\s+(\d+(?:\.\d+)?)([KMGB])\s+(\d+(?:\.\d+)?)([KMGB])\s+(\d+(?:\.\d+)?)([KMGB])", line)
        if not found or found.group(1).startswith(("REGION", "===", "TOTAL")):
            continue
        dirty = float(found.group(6)) * unit[found.group(7)] + float(found.group(8)) * unit[found.group(9)]
        sizes[found.group(1).strip()] = round(dirty, 1)
    return dict(sorted(sizes.items(), key=lambda item: -item[1])[:top])


def sampling_top(profile: dict, top: int = 15) -> list[dict]:
    """A V8 sampling heap profile's live bytes by function and script, the largest first (pure)."""
    totals: dict = {}

    def walk(node):
        frame = node.get("callFrame") or {}
        key = f"{frame.get('functionName') or '(anonymous)'} {os.path.basename(str(frame.get('url') or ''))}:{frame.get('lineNumber', '')}"
        totals[key] = totals.get(key, 0) + int(node.get("selfSize") or 0)
        for child in node.get("children") or []:
            walk(child)

    if isinstance(profile.get("head"), dict):
        walk(profile["head"])
    return [{"frame": k, "mb": round(v / MB, 2)} for k, v in sorted(totals.items(), key=lambda item: -item[1])[:top] if v]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--out", default=None)
    parser.add_argument("--launches", type=int, default=3)
    parser.add_argument("--seconds", type=float, default=180)
    parser.add_argument("--every", type=float, default=5)
    parser.add_argument("--after-s", type=float, default=10)
    parser.add_argument("--no-page-reads", dest="page_reads", action="store_false")
    parser.add_argument("--no-heap-sampling", dest="heap_sampling", action="store_false")
    parser.add_argument("--no-vmmap", dest="vmmap", action="store_false")
    args, _rest = parser.parse_known_args(argv)  # split-spring's own args (--tag) are not this suite's
    sys.path.insert(0, HERE)
    import bench_memory as bm  # macOS only (libproc)
    launches, errors = [], []
    for index in range(1, args.launches + 1):
        try:
            launches.append(run_launch(bm, index, args))
        except (SystemExit, Exception) as error:  # one failed launch keeps the others
            errors.append(f"launch {index}: {error}"[:400])
            print(f"renderer-rest: {errors[-1]}", flush=True)
    rows = rows_from(launches)
    report = {"rows": rows, "launches": launches, "errors": errors,
              "args": {k: v for k, v in vars(args).items() if k not in ("app", "json", "out")}}
    if not launches:
        report["incomplete"] = errors or ["no launch"]
    with open(args.json, "w") as f:
        json.dump(report, f, indent=1)
    for launch in launches:
        for pid, row in launch["summary"].items():
            print(f"renderer-rest: launch {launch['index']} renderer {pid} {'/'.join(row['roles'])}: first {row['first_mb']} "
                  f"(t={row['first_t']}), 20 s {row['at20_mb']}, 60 s {row['at60_mb']}, end {row['end_mb']}, "
                  f"peak {row['peak_mb']}, after 60 s {row['growth_after_60s_mb_per_min']} MB/min; "
                  f"heap {row.get('js_heap_mb')}; nodes {row.get('nodes')}", flush=True)
        for name, point in launch["end_points"].items():
            print(f"renderer-rest: launch {launch['index']} {name}: " + ", ".join(
                f"{r['pid']} {r['footprint_mb']} MB" for r in point["renderers"]), flush=True)
        for b, page in launch["end_pages"].items():
            print(f"renderer-rest: launch {launch['index']} page {b} {page['role']}: {json.dumps(page.get('state'))[:600]}", flush=True)
            print(f"renderer-rest: launch {launch['index']} page {b} heap top: {json.dumps(page.get('heap_sampling_top'))[:900]}", flush=True)
        print(f"renderer-rest: launch {launch['index']} vmmap: {json.dumps(launch['vmmap'])[:1500]}", flush=True)
    for r in rows:
        print(f"renderer-rest: {r['name']} = {r['p50']} {r['unit']} (launches {r['launches']})", flush=True)
    return 0 if launches else 1


if __name__ == "__main__":
    raise SystemExit(main())
