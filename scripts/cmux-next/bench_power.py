#!/usr/bin/env python3
"""Power, wakeups and CPU of a cmux-next app in browser-benchmark scenarios.

The scenarios follow the Ardia/Helium/Dia comparison (2026-10-19): idle with
the window in view, idle hidden and minimized, idle with 20 tabs, scrolling,
video, and switching tabs. Every page is served from a local HTTP server so
runs are repeatable and need no network:

  /static.html?n=K   an article page with no script (idle tabs)
  /long.html         a long page that scrolls itself on requestAnimationFrame
  /video.html        a looping VP8 video the page records from a canvas first

Power is the CPU energy macOS accounts to each process (proc_pid_rusage
RUSAGE_INFO_V6 ri_energy_nj), summed over the app and every process it owns
(Chromium helpers, WebKit processes, cmux-tui daemons and terminal hosts,
acpmux). It needs no root. GPU and display energy are not in it; with
`sudo -n` available the run also records powermetrics' package power.

Usage (a fleet mini, never a laptop; launches the app with a scratch HOME):
  bench_power.py --app BUNDLE [--settle 120] [--measure 60]
      [--scenarios terminal,tab1,tab1-hidden,tabs20,tabs20-hidden,title,scroll,video,switch,neighbors,minimized]
      [--out FILE.json]
Prints one PERF-POWER line per scenario and kind, plus a total line.

`neighbors` (browser.keepNeighborTabsAwake, plans/cmux-next/neighbor-tabs-DESIGN.md)
times switches among the 20 tabs: to the next tab (a neighbor) and to a tab 10
away (far), each after `--neighbor-gap` seconds so far pages are frozen again.
Run it with "browser": {"freezeHiddenTabs": 5} and once each with
"keepNeighborTabsAwake": 0 (before) and 1 (after). Prints PERF-NEIGHBOR lines:
the app's own switch time (debug.tab_switch) and the time until the page runs
script again (live_ms), plus the app's cold-show and prewarm counts.

`loaded` (run it alone) is the shared idle-cost bench: a heavy user's load
(idle_cost_load.py: 3000 chats in the daemon's list, 60% closed; 20 remote and
5 local open chats, 3 of them streaming; 10 Chromium tabs; Home and New Tab),
--settle seconds, then --measure idle seconds sampled once a second from
outside (proc_pid_rusage and proc_pidinfo, which wake nothing). Per process
and per role (app, each Chromium renderer by the page it hosts, from
`debug.cef_pages` on bench and DEV builds, cef-gpu, WebKit, acpmux
daemon): phys_footprint, CPU % average and p95 over the 1 s steps, idle and
interrupt wakeups/s, main-thread CPU %. Prints PERF-IDLE-COST lines and
Performance-table rows; the JSON goes to --out. Two runs side by side:
  bench_power.py --compare BEFORE.json AFTER.json
One command on the fleet:
  cmux-ci run --class exclusive --measurement --label measure \\
    --script scripts/measure/perf-idle-power.sh --ref SHA \\
    --arg=scenarios=loaded --arg=config=bench --artifact artifacts/perf-idle-power.json

`relaunch-reconnect` (run it alone) quits and relaunches the app with agent chats open, one
streaming, and times each phase from process start to the shown chat's first live event
(bench_relaunch_reconnect.py; --load-local sets its chats, 6 by default):
  cmux-ci run --class exclusive --measurement --display --label measure \\
    --script scripts/measure/perf-idle-power.sh --ref SHA --arg=scenarios=relaunch-reconnect \\
    --arg=config=bench --artifact artifacts/perf-idle-power.json

`idle-chats` (run it alone) is the same bench at the idle-CPU stop condition (Leo, 2026-11-03:
"im at 100% cpu rn"; done when every process idles under 5% CPU with about 40 chats open):
40 local chats on the app's own daemon, each answered once and shown once in its own workspace,
nothing streaming, no browser tabs, the same 3000-chat list; 60 s settle, then 120 s measured.
Every --load-*, --settle and --measure flag still overrides it. Besides the PERF-IDLE-COST lines
it prints one row per process (role, CPU % avg and p95, wakeups/s, main-thread CPU %, footprint,
and whether it is over --process-budget, 5% by default) between PERF-IDLE-CHATS-TABLE-BEGIN and
-END, and a `PERF-IDLE-CHATS verdict=PASS|OVER` line naming the busiest process. The verdict
reports; it never fails the step. The Markdown also goes into the JSON (`markdown`) and to --md.
  cmux-ci run --class exclusive --measurement --label measure \\
    --script scripts/measure/perf-idle-power.sh --ref SHA \\
    --arg=scenarios=idle-chats --arg=config=bench --artifact artifacts/perf-idle-power.json
"""
from __future__ import annotations

import argparse
import ctypes
import http.server
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402  (launch, App, owned, end_bundle)

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
_libproc.proc_pidinfo.restype = ctypes.c_int
MB = 1048576.0
# PROC_PIDLISTTHREADIDS (28) is XNU's private flavor (bsd/sys/proc_info_private.h, not in the public
# SDK header): proc_info.c lists the threads with thuniqueid = true, so it returns the 64-bit thread
# ids that PROC_PIDTHREADID64INFO (15, public) reads. PROC_PIDLISTTHREADS (6) lists thread handles,
# which pair with PROC_PIDTHREADINFO (5) instead. A kernel that refused 28 makes proc_pidinfo return 0,
# and main_thread_ns then returns None: the report shows main_thread_pct null, never a wrong number.
PROC_PIDLISTTHREADIDS = 28
PROC_PIDTHREADID64INFO = 15

ARTICLE = "<p>" + ("cmux keeps idle work at zero. " * 40) + "</p>"
PAGES = {
    "/static.html": "<!doctype html><title>Static {n}</title><style>body{{font:16px -apple-system;max-width:720px;margin:40px auto}}</style>"
                    "<h1>Static page {n}</h1>" + ARTICLE * 6,
    # A typical site's background work: a 250 ms poll and an animation loop
    # (analytics beacons, carousels, live counters).
    "/busy.html": "<!doctype html><title>Busy {n}</title><style>body{{font:16px -apple-system;max-width:720px;margin:40px auto}}</style>"
                  "<h1>Busy page {n}</h1><p id=t></p>" + ARTICLE * 6 +
                  "<script>let k=0;setInterval(()=>{{document.getElementById('t').textContent=++k}},250);"
                  "(function f(){{document.title='Busy {n} '+(k%10);requestAnimationFrame(f)}})()</script>",
    "/long.html": "<!doctype html><title>Scroll</title><style>body{font:16px -apple-system;max-width:720px;margin:40px auto}</style>"
                  "<h1>Long page</h1>" + ARTICLE * 400 +
                  "<script>let d=4;function s(){if(scrollY+innerHeight>=document.body.scrollHeight-2)d=-4;"
                  "else if(scrollY<=0)d=4;scrollBy(0,d);requestAnimationFrame(s)}requestAnimationFrame(s)</script>",
    "/video.html": "<!doctype html><title>Video</title><body style='margin:0;background:#000'>"
                   "<video id=v muted loop playsinline style='width:100%'></video><canvas id=c width=1280 height=720 hidden></canvas>"
                   "<script>const c=document.getElementById('c'),x=c.getContext('2d'),r=new MediaRecorder(c.captureStream(30),"
                   "{mimeType:'video/webm;codecs=vp8',videoBitsPerSecond:4e6}),parts=[];let f=0;"
                   "r.ondataavailable=e=>parts.push(e.data);r.onstop=()=>{const v=document.getElementById('v');"
                   "v.src=URL.createObjectURL(new Blob(parts,{type:'video/webm'}));v.play();document.title='Video ready'};"
                   "function draw(){x.fillStyle=`hsl(${f*3%360},70%,40%)`;x.fillRect(0,0,1280,720);x.fillStyle='#fff';"
                   "x.font='120px sans-serif';x.fillText('frame '+f,100,400);f++;if(f<300)requestAnimationFrame(draw);else r.stop()}"
                   "r.start();draw()</script>",
}


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        path, _, query = self.path.partition("?")
        n = query.split("n=", 1)[1].split("&")[0] if "n=" in query else "0"
        body = PAGES.get(path)
        if body is None:
            self.send_error(404)
            return
        data = body.replace("{n}", n).replace("{{", "{").replace("}}", "}").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        pass


def serve() -> str:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


def counters(pid: int):
    """(energy nJ, cpu ns, wakeups, footprint bytes) or None once the pid is gone."""
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(6), ctypes.byref(buf)) != 0:
        return None
    # RUSAGE_INFO_V6 in u64 words: user (2), system (3) in mach ticks, pkg idle
    # wakeups (4), interrupt wakeups (5), phys_footprint (9), ri_energy_nj (42).
    cpu_ns = (buf[2] + buf[3]) * bm._timebase.numer // bm._timebase.denom
    return buf[42], cpu_ns, buf[4] + buf[5], buf[9]


def powermetrics(seconds: float):
    """Package/CPU/GPU power in mW over `seconds`, or None without passwordless sudo."""
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        return None
    out = subprocess.run(["sudo", "-n", "powermetrics", "-i", str(int(seconds * 1000)), "-n", "1",
                          "--samplers", "cpu_power,gpu_power"], capture_output=True, text=True,
                         timeout=seconds + 30).stdout
    found = {}
    for line in out.splitlines():
        for key in ("CPU Power", "GPU Power", "ANE Power", "Combined Power (CPU + GPU + ANE)"):
            if line.startswith(key + ":"):
                found[key.split(" (")[0].lower().replace(" ", "_") + "_mw"] = float(line.split(":")[1].split()[0])
    return found


def measure(app_pid: int, bundle: str, label: str, seconds: float, during=None, sample_idle: bool = False):
    """Energy, CPU and wakeups of every owned process over `seconds`."""
    start = {pid: (kind, counters(pid)) for pid, (kind, _cmd) in bm.owned(app_pid, bundle).items()}
    started = time.monotonic()
    pm_result = {}
    pm = threading.Thread(target=lambda: pm_result.update(powermetrics(seconds) or {}), daemon=True)
    pm.start()
    sampler = None
    if during:
        during(seconds)
    elif not sample_idle:
        time.sleep(seconds)  # test script: the measured window
    else:
        # --sample-idle (sampling interrupts the app, so normal runs leave it off): a stack sample
        # inside the window. The app's energy rises for a while, then drops, so a sample after the
        # window shows it idle. Kept only when the window ends above the guard.
        time.sleep(seconds / 2)  # test script: first half of the measured window
        sample_path = os.path.abspath(f"app-{label}.sample")
        sampler = subprocess.Popen(["sample", str(app_pid), str(int(min(10, seconds / 3))), "-mayDie", "-file", sample_path],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(seconds / 2)  # test script: second half of the measured window
    pm.join(timeout=seconds + 40)
    elapsed = time.monotonic() - started
    kinds: dict[str, dict] = {}
    for pid, (kind, first) in start.items():
        last = counters(pid)
        if first is None or last is None:
            continue
        entry = kinds.setdefault(kind, {"count": 0, "mw": 0.0, "cpu_pct": 0.0, "wakeups_per_s": 0.0, "footprint_mb": 0.0})
        entry["count"] += 1
        entry["mw"] += (last[0] - first[0]) / 1e6 / elapsed
        entry["cpu_pct"] += 100 * (last[1] - first[1]) / 1e9 / elapsed
        entry["wakeups_per_s"] += (last[2] - first[2]) / elapsed
        entry["footprint_mb"] += last[3] / MB
    for entry in kinds.values():
        for key in ("mw", "cpu_pct", "wakeups_per_s", "footprint_mb"):
            entry[key] = round(entry[key], 3)
    total = {key: round(sum(e[key] for e in kinds.values()), 3) for key in ("mw", "cpu_pct", "wakeups_per_s", "footprint_mb")}
    result = {"label": label, "seconds": round(elapsed, 1), "total": total,
              "kinds": dict(sorted(kinds.items(), key=lambda item: -item[1]["mw"])), "powermetrics": pm_result}
    for kind, entry in result["kinds"].items():
        print(f"PERF-POWER {label} kind={kind} n={entry['count']} mw={entry['mw']} cpu_pct={entry['cpu_pct']} "
              f"wakeups_per_s={entry['wakeups_per_s']} footprint_mb={round(entry['footprint_mb'], 1)}")
    print(f"PERF-POWER-TOTAL {label} mw={total['mw']} cpu_pct={total['cpu_pct']} wakeups_per_s={total['wakeups_per_s']} "
          f"footprint_mb={round(total['footprint_mb'], 1)} powermetrics={json.dumps(pm_result)}", flush=True)
    app_mw = result["kinds"].get("app", {}).get("mw", 0.0)
    if sampler:
        sampler.wait(timeout=60)
        if app_mw > IDLE_APP_MW_GUARD:
            # An idle app above the guard (20 hidden tabs once read 2.6 to 4.4 mW against 0.24): keep its stacks.
            print(f"PERF-POWER-GUARD {label} app_mw={app_mw} above {IDLE_APP_MW_GUARD}: sample {sample_path}", flush=True)
        else:
            os.remove(sample_path) if os.path.exists(sample_path) else None
    return result


# App energy (mW) above which an idle scenario samples the app's stacks (msg 2654).
IDLE_APP_MW_GUARD = 1.0


def wipe_state(bundle: str):
    """Removes the tagged app's saved state. The app keeps its session,
    Chromium profile and caches under the real ~/Library (not the scratch
    HOME), so without this a run restores the last run's workspaces and tabs."""
    import plistlib
    with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as handle:
        bundle_id = plistlib.load(handle)["CFBundleIdentifier"]
    if ".debug." not in bundle_id:
        raise SystemExit(f"bench-power: refusing to wipe state of non-DEV bundle {bundle_id}")
    tag = os.path.basename(bundle).removesuffix(".app").rsplit(" ", 1)[-1]
    library = os.path.expanduser("~/Library")
    for parent in ("Application Support", "Application Support/cmux", "Application Support/cmux-next",
                   "Caches", "WebKit", "HTTPStorages", "Saved Application State", "Preferences"):
        folder = os.path.join(library, parent)
        for name in os.listdir(folder) if os.path.isdir(folder) else []:
            # This bundle's own entries only: another tag can start with this one's name.
            if name == bundle_id or name.startswith(bundle_id + "."):
                path = os.path.join(folder, name)
                shutil.rmtree(path, ignore_errors=True) if os.path.isdir(path) else os.remove(path)
    shutil.rmtree(os.path.join(library, "Application Support/cmux/tags", tag), ignore_errors=True)


def rpc(sock: str, method: str, params: dict | None = None, timeout: float = 30):
    """One control-socket call; the result, or {"error": ...}."""
    import socket as socketlib
    reply = b""
    try:
        with socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM) as stream:
            stream.settimeout(timeout)
            stream.connect(sock)
            stream.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            while not reply.endswith(b"\n"):
                chunk = stream.recv(65536)
                if not chunk:
                    break
                reply += chunk
        answer = json.loads(reply or b"{}")
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return {"error": answer["error"]} if answer.get("error") else answer.get("result") or {}


def neighbor_switches(app, sock: str, tabs: list[str], start: int, gap: float, rounds: int):
    """Switch latency to a neighbor (next tab) and to a far tab (10 away), alternating."""
    def percentile(values, q):
        values = sorted(values)
        return round(values[min(len(values) - 1, int(len(values) * q))], 2) if values else None
    rpc(sock, "debug.tab_switch", {"action": "start"})
    rows, index = [], start
    for step in range(rounds * 2):
        kind = "neighbor" if step % 2 == 0 else "far"
        index = (index + (1 if kind == "neighbor" else len(tabs) // 2)) % len(tabs)
        time.sleep(gap)  # test script: let non-neighbors freeze again (freezeHiddenTabs)
        before = len((rpc(sock, "debug.tab_switch") or {}).get("switches") or [])
        started = time.monotonic()
        app.run("tab.focus", target=tabs[index])
        # The page answers script once it runs again (a frozen page thaws on show first).
        live = None
        while time.monotonic() - started < 10:
            if (rpc(sock, "browser.page.eval", {"tab": tabs[index], "script": "1"}) or {}).get("value") == 1:
                live = (time.monotonic() - started) * 1000
                break
        switches = (rpc(sock, "debug.tab_switch") or {}).get("switches") or []
        own = switches[before] if len(switches) > before else {}
        rows.append({"kind": kind, "live_ms": live, "own": own})
    rpc(sock, "debug.tab_switch", {"action": "stop"})
    hibernation = (rpc(sock, "debug.surfaces") or {}).get("hibernation") or {}
    result = {"cold_shows_total": hibernation.get("cold_shows_total"), "prewarmed_total": hibernation.get("prewarmed_total"),
              "neighbor_radius": hibernation.get("neighbor_radius")}
    for kind in ("neighbor", "far"):
        picked = [row for row in rows if row["kind"] == kind]
        live = [row["live_ms"] for row in picked if row["live_ms"] is not None]
        commit = [row["own"].get("commit_ms") or row["own"].get("total_ms") for row in picked if row["own"]]
        commit = [value for value in commit if value is not None]
        result[kind] = {"n": len(picked), "live_p50_ms": percentile(live, 0.5), "live_p90_ms": percentile(live, 0.9),
                        "switch_p50_ms": percentile(commit, 0.5), "switch_p90_ms": percentile(commit, 0.9)}
        print(f"PERF-NEIGHBOR {kind} radius={result['neighbor_radius']} n={len(picked)} live_p50_ms={result[kind]['live_p50_ms']} "
              f"live_p90_ms={result[kind]['live_p90_ms']} switch_p50_ms={result[kind]['switch_p50_ms']} "
              f"switch_p90_ms={result[kind]['switch_p90_ms']}", flush=True)
    print(f"PERF-NEIGHBOR-COUNTS cold_shows={result['cold_shows_total']} prewarmed={result['prewarmed_total']}", flush=True)
    result["rows"] = rows
    return result


def refused(response: dict) -> str | None:
    return response.get("error") or (response.get("message") if response.get("code") else None)


# ---------------------------------------------------------------- loaded: the shared idle-cost bench

def usage_v6(pid: int):
    """(energy nJ, cpu ns, idle wakeups, interrupt wakeups, footprint bytes) or None once the pid is gone."""
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(6), ctypes.byref(buf)) != 0:
        return None
    return buf[42], (buf[2] + buf[3]) * bm._timebase.numer // bm._timebase.denom, buf[4], buf[5], buf[9]


def main_thread_ns(pid: int):
    """CPU time (ns) of the process's main thread, its lowest thread id; None when it cannot be read."""
    ids = (ctypes.c_uint64 * 4096)()
    size = _libproc.proc_pidinfo(pid, PROC_PIDLISTTHREADIDS, 0, ids, ctypes.sizeof(ids))
    threads = [ids[i] for i in range(max(size, 0) // 8) if ids[i]]
    if not threads:
        return None
    info = (ctypes.c_uint64 * 14)()  # struct proc_threadinfo (112 bytes): user and system time in ns first
    if _libproc.proc_pidinfo(pid, PROC_PIDTHREADID64INFO, min(threads), info, ctypes.sizeof(info)) != ctypes.sizeof(info):
        return None
    return info[0] + info[1]


def page_role(origin: str) -> str:
    """A Chromium page's role from its origin: cmux's own pages by id, browser tabs as one role."""
    if origin.startswith("cmux-page://"):
        return origin[len("cmux-page://"):].removeprefix("cmux.") or "page"
    if origin.startswith(("http://", "https://")):
        return "browser-tab"
    return origin.split(":", 1)[0] or "blank"


def renderer_roles(pages: list[dict], processes: dict) -> dict[int, str]:
    """{pid: role} for the Chromium renderers that host `pages` (`debug.cef_pages`),
    matched by `--renderer-client-id`. A renderer hosting several pages names them all."""
    by_client = {}
    for pid, (kind, cmd) in processes.items():
        found = re.search(r"--renderer-client-id=(\d+)", cmd) if kind == "cef-renderer" else None
        if found:
            by_client[int(found.group(1))] = pid
    names: dict[int, set] = {}
    for page in pages:
        role = page_role(page.get("origin") or "") + (" (hidden)" if page.get("hidden") else "")
        for client in page.get("renderer_clients") or []:
            if int(client) in by_client:
                names.setdefault(by_client[int(client)], set()).add(role)
    return {pid: "cef-renderer: " + " + ".join(sorted(roles)) for pid, roles in names.items()}


def percentile(values: list[float], q: float) -> float:
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))] if values else 0.0


def measure_processes(app_pid: int, bundle: str, label: str, seconds: float, roles: dict[int, str], exclude: set[int]):
    """Every owned process (but `exclude`) sampled once a second for `seconds`: per process and per role."""
    processes = {pid: entry for pid, entry in bm.owned(app_pid, bundle).items() if pid not in exclude}
    series: dict[int, list] = {pid: [] for pid in processes}
    deadline = time.monotonic() + seconds
    while True:
        now = time.monotonic()
        for pid in processes:
            series[pid].append((now, usage_v6(pid), main_thread_ns(pid)))
        if now >= deadline:
            break
        time.sleep(min(1.0, deadline - now))  # test script: one sample a second
    rows, steps_by_role = [], {}
    for pid, (kind, cmd) in processes.items():
        samples = [sample for sample in series[pid] if sample[1] is not None]
        if len(samples) < 2 or samples[-1][0] <= samples[0][0]:
            continue  # gone during the window
        (t0, u0, m0), (t1, u1, m1) = samples[0], samples[-1]
        span = t1 - t0
        steps = [100 * (b[1][1] - a[1][1]) / 1e9 / (b[0] - a[0]) for a, b in zip(samples, samples[1:]) if b[0] > a[0]]
        role = "app" if kind == "app" else roles.get(pid, kind)
        # The largest footprint the window read. A live process never has none: a 0 is a read that
        # failed (24 of 46 renderers in one display run), so it counts as unread, not as 0 MB.
        footprint = max(sample[1][4] for sample in samples)
        rows.append({"pid": pid, "kind": kind, "role": role, "footprint_mb": round(footprint / MB, 1) if footprint else None,
                     "cpu_pct": round(100 * (u1[1] - u0[1]) / 1e9 / span, 3), "cpu_p95_pct": round(percentile(steps, 0.95), 3),
                     "idle_wakeups_per_s": round((u1[2] - u0[2]) / span, 2),
                     "interrupt_wakeups_per_s": round((u1[3] - u0[3]) / span, 2),
                     # Idle plus interrupt wakeups, as bench_memory counts them: Apple silicon reports
                     # package idle wakeups as 0, so the interrupt count carries the signal there.
                     "wakeups_per_s": round((u1[2] - u0[2] + u1[3] - u0[3]) / span, 2),
                     "mw": round((u1[0] - u0[0]) / 1e6 / span, 3),
                     "main_thread_pct": round(100 * (m1 - m0) / 1e9 / span, 3) if m0 is not None and m1 is not None else None,
                     "command": cmd[:160],
                     # The renderer flags that say which renderer it is, kept whole: a long bundle path
                     # pushes them past the truncated command.
                     "flags": " ".join(arg for arg in cmd.split() if arg.startswith(RENDERER_FLAGS))})
        steps_by_role.setdefault(role, []).append(steps)
        steps_by_role.setdefault("total", []).append(steps)
    rows.sort(key=lambda row: -row["cpu_pct"])
    totals = {}
    for role in ["total"] + sorted({row["role"] for row in rows}):
        members = [row for row in rows if role == "total" or row["role"] == role]
        lists = steps_by_role.get(role) or [[]]
        summed = [sum(values) for values in zip(*lists)]  # the role's CPU per 1 s step
        main = [row["main_thread_pct"] for row in members if row["main_thread_pct"] is not None]
        totals[role] = {"count": len(members), "footprint_mb": round(sum(r["footprint_mb"] or 0 for r in members), 1),
                        "footprint_unread": sum(1 for r in members if r["footprint_mb"] is None),
                        "cpu_pct": round(sum(r["cpu_pct"] for r in members), 3), "cpu_p95_pct": round(percentile(summed, 0.95), 3),
                        "idle_wakeups_per_s": round(sum(r["idle_wakeups_per_s"] for r in members), 2),
                        "interrupt_wakeups_per_s": round(sum(r["interrupt_wakeups_per_s"] for r in members), 2),
                        "wakeups_per_s": round(sum(r["wakeups_per_s"] for r in members), 2),
                        "main_thread_pct": round(sum(main), 3) if main else None}
    for role, entry in totals.items():
        print(f"PERF-IDLE-COST {label} role={role!r} n={entry['count']} footprint_mb={entry['footprint_mb']} "
              f"footprint_unread={entry['footprint_unread']} "
              f"cpu_pct={entry['cpu_pct']} cpu_p95_pct={entry['cpu_p95_pct']} idle_wakeups_per_s={entry['idle_wakeups_per_s']} "
              f"interrupt_wakeups_per_s={entry['interrupt_wakeups_per_s']} wakeups_per_s={entry['wakeups_per_s']} main_thread_pct={entry['main_thread_pct']}", flush=True)
    return {"label": label, "seconds": round(seconds, 1), "roles": totals, "processes": rows}


METRICS = (("cpu_pct", "CPU % (avg)"), ("cpu_p95_pct", "CPU % (p95 of 1 s)"), ("footprint_mb", "footprint MB"),
           ("wakeups_per_s", "wakeups/s (idle + interrupt)"), ("main_thread_pct", "main thread CPU %"))


def perf_rows(before: dict, after: dict | None, harness: str) -> list[str]:
    """Performance-table rows (metric | before | after | delta | harness) for two `loaded` results
    (or one: after and delta empty). Roles in `before` order, the total first."""
    def cell(value):
        return "" if value is None else f"{value:g}"
    rows = ["| metric | before | after | delta | harness |", "| --- | --- | --- | --- | --- |"]
    roles = list(before["roles"]) + [role for role in (after or {}).get("roles", {}) if role not in before["roles"]]
    for role in roles:
        for key, title in METRICS:
            old = before["roles"].get(role, {}).get(key)
            new = after["roles"].get(role, {}).get(key) if after else None
            if old is None and new is None:
                continue
            delta = ""
            if old is not None and new is not None:
                delta = f"{new - old:+.3g}" + (f" ({100 * (new - old) / old:+.0f}%)" if old else "")
            rows.append(f"| {role}: {title} | {cell(old)} | {cell(new)} | {delta} | {harness} |")
    return rows


def loaded_result(path: str) -> dict:
    with open(path) as handle:
        data = json.load(handle)
    found = [result for result in data.get("results", []) if result.get("label") in IDLE_COST_LABELS]
    if not found:
        raise SystemExit(f"bench-power: {path} has no `loaded` or `idle-chats` result")
    return found[-1]


# The idle-cost scenarios: `loaded` (a heavy user's mixed load) and `idle-chats` (the idle-CPU stop
# condition). Each is a preset of the --load-*, --settle and --measure flags; a flag given wins.
IDLE_COST_PRESETS = {
    "loaded": {"load_remote": 20, "load_local": 5, "load_streaming": 3, "load_tabs": 10, "settle": 120, "measure": 60},
    "idle-chats": {"load_remote": 0, "load_local": 40, "load_streaming": 0, "load_tabs": 0, "settle": 60, "measure": 120},
}
IDLE_COST_LABELS = tuple(IDLE_COST_PRESETS)
# Command-line flags that name a Chromium renderer when no page map does (process_rows).
RENDERER_FLAGS = ("--renderer-client-id", "--extension-process", "--type=")
# Leo's budget for an idle app: no process above this CPU % (the idle-chats verdict).
PROCESS_BUDGET_PCT = 5.0


def apply_preset(args, scenario: str):
    """Fills each preset flag the command line left unset (None) from the scenario's preset."""
    for key, value in IDLE_COST_PRESETS.get(scenario, IDLE_COST_PRESETS["loaded"]).items():
        if getattr(args, key, None) is None:
            setattr(args, key, value)
    return args


def process_rows(result: dict, budget: float) -> tuple[list[str], dict]:
    """The per-process Markdown table of one idle-cost result, busiest first, and the verdict:
    PASS when no process averages above `budget` CPU %, else OVER with every process above it."""
    def num(value, digits=2):
        return "" if value is None else f"{value:.{digits}f}"
    rows = ["| process | pid | CPU % avg | CPU % p95 | wakeups/s | main thread CPU % | footprint MB | over budget |",
            "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    over = []
    for proc in sorted(result["processes"], key=lambda row: -row["cpu_pct"]):
        role = proc["role"]
        if proc["kind"] == "cef-renderer" and not role.startswith("cef-renderer:"):
            # No page map for this renderer (a build without debug.cef_pages): its command line says
            # which kind it is (--extension-process, --renderer-client-id).
            flags = proc.get("flags") or " ".join(arg for arg in proc.get("command", "").split()
                                                  if arg.startswith(RENDERER_FLAGS))
            role += f" `{flags[:80]}`" if flags else ""
        flag = proc["cpu_pct"] > budget
        if flag:
            over.append({"pid": proc["pid"], "role": proc["role"], "cpu_pct": proc["cpu_pct"]})
        rows.append(f"| {role} | {proc['pid']} | {num(proc['cpu_pct'])} | {num(proc.get('cpu_p95_pct'))} | "
                    f"{num(proc.get('wakeups_per_s'), 1)} | {num(proc.get('main_thread_pct'))} | "
                    f"{num(proc.get('footprint_mb'), 1)} | {'OVER' if flag else ''} |")
    busiest = max(result["processes"], key=lambda row: row["cpu_pct"], default=None)
    # No process measured (a zero-second window, or every process gone) is no evidence: never PASS.
    verdict = {"budget_pct": budget, "verdict": "OVER" if over else "PASS" if busiest else "UNMEASURED", "over": over,
               "max_cpu_pct": busiest["cpu_pct"] if busiest else None,
               "max_role": busiest["role"] if busiest else None, "max_pid": busiest["pid"] if busiest else None}
    return rows, verdict


def idle_cost_markdown(result: dict, budget: float) -> tuple[str, dict]:
    """The Markdown a PR or issue pastes for one idle-cost run: the load, the per-process table with
    the verdict, and the per-role Performance rows (before only; --compare gives before and after)."""
    rows, verdict = process_rows(result, budget)
    load_line = ", ".join(f"{key} {value}" for key, value in (result.get("load") or {}).items())
    lines = [f"**{result['label']}**: {result.get('harness', '')}", "", f"Load reached: {load_line}", "",
             f"Verdict: **{verdict['verdict']}** (budget {budget:g}% CPU per process; busiest "
             f"{verdict['max_role']} at {verdict['max_cpu_pct']}%)", ""] + rows + ["", "Per role:", ""]
    lines += perf_rows(result, None, result.get("harness", ""))
    return "\n".join(lines) + "\n", verdict


def devtools(sock: str, browser: int, method: str, params: dict | None = None):
    """A DevTools method on cmux's own Chromium page `browser` (`debug.cef_page_devtools`): its reply, parsed."""
    reply = rpc(sock, "debug.cef_page_devtools", {"browser": browser, "method": method, "params": params or {}}, timeout=60)
    if reply.get("error") or not isinstance(reply.get("result"), str):
        return {"error": reply.get("error") or "no reply"}
    try:
        return json.loads(reply["result"])
    except ValueError as error:
        return {"error": str(error)}


def profile_summary(profile: dict, top: int = 25) -> dict:
    """A V8 CPU profile's self time by function (name, script, line), busiest first, in ms."""
    nodes = {node["id"]: node for node in profile.get("nodes", [])}
    samples, deltas = profile.get("samples", []), profile.get("timeDeltas", [])
    self_us: dict[int, float] = {}
    for index, node_id in enumerate(samples):
        # A sample's time is the gap to the next one (Chrome DevTools' own attribution).
        gap = deltas[index + 1] if index + 1 < len(deltas) else 0
        self_us[node_id] = self_us.get(node_id, 0) + max(gap, 0)
    by_function: dict[str, float] = {}
    for node_id, micros in self_us.items():
        frame = nodes.get(node_id, {}).get("callFrame", {})
        url = (frame.get("url") or "").rsplit("/", 1)[-1]
        key = f"{frame.get('functionName') or '(anonymous)'} {url}:{frame.get('lineNumber', -1) + 1}:{frame.get('columnNumber', -1) + 1}"
        by_function[key] = by_function.get(key, 0) + micros
    total = sum(by_function.values())
    busiest = sorted(by_function.items(), key=lambda item: -item[1])[:top]
    return {"total_ms": round(total / 1000, 1), "self_ms": [[key, round(micros / 1000, 1)] for key, micros in busiest]}


def native_sample(pid: int, role: str, seconds: int) -> dict:
    """`sample PID seconds` (macOS): the main thread's call tree, its first 200 lines, and the
    heaviest frames of the whole process (the tool's "Sort by top of stack" section)."""
    out_path = os.path.join(tempfile.gettempdir(), f"idle-sample-{pid}.txt")
    try:
        subprocess.run(["/usr/bin/sample", str(pid), str(seconds), "1", "-mayDie", "-file", out_path],
                       capture_output=True, timeout=seconds + 60, check=False)
        text = open(out_path, errors="replace").read()
    except (OSError, subprocess.SubprocessError) as error:
        return {"pid": pid, "role": role, "error": str(error)}
    finally:
        if os.path.exists(out_path):
            os.remove(out_path)
    lines = text.splitlines()
    main, inside = [], False
    for line in lines:
        if "Thread_" in line and ("main-thread" in line or "DispatchQueue_1" in line or "CrRendererMain" in line):
            inside = True
        elif inside and re.match(r"\s*\d+ Thread_", line):
            break
        if inside:
            main.append(line[:220])
        if len(main) >= 200:
            break
    top = []
    if "Sort by top of stack" in text:
        top = text.split("Sort by top of stack", 1)[1].splitlines()[1:40]
    return {"pid": pid, "role": role, "seconds": seconds, "main": "\n".join(main), "top": "\n".join(line[:200] for line in top)}


def idle_profile(sock: str, pages: list[dict], seconds: float) -> list[dict]:
    """What each shown cmux page's renderer main thread runs while nobody touches it, all in one
    window of `seconds`: Chromium's page metrics (task, script, style and layout time, counts) per
    second, and a V8 CPU profile by function. The profilers and the metrics are off again after."""
    shown = [page for page in pages if not page.get("hidden") and str(page.get("origin", "")).startswith("cmux-page://")]
    def metrics(browser):
        reply = devtools(sock, browser, "Performance.getMetrics")
        return {m["name"]: m["value"] for m in reply.get("metrics", [])} if "metrics" in reply else reply
    for page in shown:
        for method, params in (("Performance.enable", None), ("Profiler.enable", None),
                               ("Profiler.setSamplingInterval", {"interval": 500}), ("Profiler.start", None)):
            devtools(sock, page["browser"], method, params)
    before = {page["browser"]: metrics(page["browser"]) for page in shown}
    time.sleep(seconds)  # test script: the profiled idle window
    after = {page["browser"]: metrics(page["browser"]) for page in shown}
    out = []
    for page in shown:
        browser = page["browser"]
        stopped = devtools(sock, browser, "Profiler.stop")
        devtools(sock, browser, "Profiler.disable")
        devtools(sock, browser, "Performance.disable")
        entry = {"browser": browser, "origin": page.get("origin"), "path": page.get("path"),
                 "renderer_clients": page.get("renderer_clients"), "seconds": seconds}
        first, last = before[browser], after[browser]
        if "error" not in first and "error" not in last:
            keys = ("TaskDuration", "ScriptDuration", "LayoutDuration", "RecalcStyleDuration", "LayoutCount", "RecalcStyleCount")
            entry["metrics_per_s"] = {key: round((last.get(key, 0) - first.get(key, 0)) / seconds, 4) for key in keys if key in last}
            entry["heap_mb"] = round(last.get("JSHeapUsedSize", 0) / MB, 1)
            entry["nodes"] = last.get("Nodes")
        else:
            entry["metrics_error"] = [first, last]
        entry["profile"] = profile_summary(stopped["profile"]) if "profile" in stopped else stopped
        out.append(entry)
    return out


def run_loaded(args):
    """An idle-cost scenario (`loaded` or `idle-chats`, see the module): load, settle, measure, report."""
    label = getattr(args, "scenario", "loaded")
    import idle_cost_load as load
    base = serve()
    signal.signal(signal.SIGTERM, bm.interrupted)
    wipe_state(args.app)
    root = tempfile.mkdtemp(prefix="idle-cost-")
    agent = os.path.join(HERE, "idle_cost_agent.py")  # fake_agent.py plus the `stream:` prompt
    peer, results, scratch = load.PeerDaemon(args.app, root, agent), [], None
    counts = {"remote": args.load_remote, "local": args.load_local, "streaming": args.load_streaming,
              "tabs": args.load_tabs, "rate": args.stream_rate}
    stream_s = args.settle + args.measure + 900  # the replies stream through the whole window
    try:
        # The remote machine first: it writes the chats the app's store is seeded with.
        peer.start()
        seeded = load.seed_store(os.path.join(root, "acpmux"), args.load_sessions, args.load_closed, *peer.templates())
        env = dict(item.split("=", 1) for item in args.env)
        env["ACPMUX_HOME"] = os.path.join(root, "acpmux")
        pid, sock, scratch = bm.launch(args.app, json.loads(args.config), env)
        app = bm.App(args.app, sock)
        reached = load.open_load(app, args.app, agent, peer,
                                 lambda i: base.replace("127.0.0.1", f"t{i}.localhost") + f"/static.html?n={i}",
                                 counts, stream_s)
        reached.update(seeded)
        print(f"PERF-IDLE-COST-LOAD {json.dumps(reached)}", flush=True)
        time.sleep(args.settle)  # test script: let the app settle
        pages = (rpc(sock, "debug.cef_pages") or {}).get("pages")
        roles = renderer_roles(pages or [], bm.owned(pid, args.app))
        time.sleep(5)  # test script: the debug read's own work ends before the window
        result = measure_processes(pid, args.app, label, args.measure, roles, peer.pids())
        result["load"] = reached
        if label == "idle-chats":
            # After the window, so it costs the measurement nothing: what the shown chat's page asks
            # for while nobody touches it, by call site (idleProbe.ts), for the idle loop's source.
            # A 3.5 s window: a Chromium page's script call ends at 5 s (Runtime.evaluate).
            probe = rpc(sock, "debug.agent_pane", {"action": "idle_probe", "ms": 3500}, timeout=20)
            result["idle_probe"] = probe
            print(f"PERF-IDLE-PROBE {json.dumps(probe)[:20000]}", flush=True)
            pages_now = (rpc(sock, "debug.cef_pages") or {}).get("pages") or []
            result["pages"] = pages_now
            result["idle_profile"] = idle_profile(sock, pages_now, 10)
            print(f"PERF-IDLE-PROFILE {json.dumps(result['idle_profile'])[:20000]}", flush=True)
            # A page's script and tasks can read 0 while its renderer's main thread still burns: a native
            # sample of each renderer over 1% names that work.
            busy = [row for row in result["processes"] if row["kind"] == "cef-renderer" and row["cpu_pct"] > 1][:3]
            result["native_samples"] = [native_sample(row["pid"], row["role"], 8) for row in busy]
            for entry in result["native_samples"]:
                print(f"PERF-IDLE-SAMPLE pid={entry['pid']} role={entry['role']!r}\n{entry.get('main', entry.get('error'))}", flush=True)
        result["renderer_roles"] = "debug.cef_pages" if pages is not None else "none (a build without debug.* methods)"
        sha = subprocess.run(["git", "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True).stdout.strip()
        model = subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip()
        result["harness"] = f"bench_power.py {label} @{sha or '?'} {model}, {int(args.measure)} s"
        result["markdown"], result["budget"] = idle_cost_markdown(result, args.process_budget)
        results.append(result)
        print("PERF-IDLE-COST-TABLE-BEGIN")
        print("\n".join(perf_rows(result, None, result["harness"])))
        print("PERF-IDLE-COST-TABLE-END", flush=True)
        if label == "idle-chats":
            verdict = result["budget"]
            print("PERF-IDLE-CHATS-TABLE-BEGIN")
            print(result["markdown"], end="")
            print("PERF-IDLE-CHATS-TABLE-END")
            print(f"PERF-IDLE-CHATS verdict={verdict['verdict']} budget_pct={verdict['budget_pct']} "
                  f"max_cpu_pct={verdict['max_cpu_pct']} max_role={verdict['max_role']!r} over={len(verdict['over'])}",
                  flush=True)
        if args.md:
            with open(args.md, "w") as handle:
                handle.write(result["markdown"])
    finally:
        peer.stop()
        bm.end_bundle(args.app)
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    if args.out:
        with open(args.out, "w") as handle:
            json.dump({"app": args.app, "measure_s": args.measure, "results": results}, handle, indent=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app")
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"),
                        help="print the Performance-table rows of two `loaded` runs' JSON (no app)")
    parser.add_argument("--harness", help="--compare: the harness cell (default: the before run's)")
    parser.add_argument("--load-sessions", type=int, default=3000, help="loaded: chats in the daemon's list")
    parser.add_argument("--load-closed", type=float, default=0.6, help="loaded: share of them closed")
    parser.add_argument("--load-remote", type=int, help="loaded: open chats on the peer (20; idle-chats 0)")
    parser.add_argument("--load-local", type=int, help="loaded: open chats on this Mac (5; idle-chats 40)")
    parser.add_argument("--load-streaming", type=int, help="loaded: open chats streaming a reply (3; idle-chats 0)")
    parser.add_argument("--load-tabs", type=int, help="loaded: Chromium tabs (10; idle-chats 0)")
    parser.add_argument("--stream-rate", type=float, default=10, help="loaded: streamed chunks a second per chat")
    # Chromium does post-load work (code caching, GC, tile purges) for about two
    # minutes after tabs open or hide; shorter settles measure that, not idle.
    # Unset: 120 and 60, or the idle-cost scenario's preset (idle-chats: 60 and 120).
    parser.add_argument("--settle", type=float)
    parser.add_argument("--measure", type=float)
    parser.add_argument("--process-budget", type=float, default=PROCESS_BUDGET_PCT,
                        help="idle-cost: the CPU %% per process the verdict holds each process to")
    parser.add_argument("--md", help="idle-cost: write the per-process Markdown table here")
    parser.add_argument("--scenarios", default="terminal,tab1,tab1-hidden,tabs20,tabs20-hidden,title,scroll,video,switch,minimized")
    parser.add_argument("--config", default="{}", help="extra cmux.json settings (JSON)")
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                        help="extra app environment, e.g. CMUX_NEXT_CEF_EXTRA_SWITCHES=... (repeatable)")
    parser.add_argument("--neighbor-gap", type=float, default=7, help="seconds before each neighbors-scenario switch")
    parser.add_argument("--neighbor-rounds", type=int, default=10)
    parser.add_argument("--sample-idle", action="store_true",
                        help="sample the app's stacks inside each idle window; keep the sample when the app is above 1 mW")
    parser.add_argument("--out")
    args = parser.parse_args()
    if args.compare:
        before, after = (loaded_result(path) for path in args.compare)
        print("\n".join(perf_rows(before, after, args.harness or before.get("harness", "bench_power.py loaded"))))
        return
    if not args.app:
        parser.error("--app is required")
    scenarios = args.scenarios.split(",")
    if "relaunch-reconnect" in scenarios:
        # Relaunch to the first live chat event (bench_relaunch_reconnect.py), through this
        # script's one fleet entry (perf-idle-power.sh); --load-local sets its chats.
        if scenarios != ["relaunch-reconnect"]:
            raise SystemExit("bench-power: the relaunch-reconnect scenario runs alone (--scenarios relaunch-reconnect)")
        import bench_relaunch_reconnect as relaunch
        argv = ["--app", args.app, "--config", args.config]
        argv += ["--chats", str(args.load_local)] if args.load_local is not None else []
        argv += ["--out", args.out] if args.out else []
        argv += ["--md", args.md] if args.md else []
        relaunch.main(argv)
        return
    for scenario in IDLE_COST_LABELS:
        if scenario in scenarios:
            if scenarios != [scenario]:
                raise SystemExit(f"bench-power: the {scenario} scenario runs alone (--scenarios {scenario})")
            args.scenario = scenario
            run_loaded(apply_preset(args, scenario))
            return
    apply_preset(args, "loaded")  # the browser scenarios' settle and measure defaults (120 s, 60 s)
    base = serve()
    signal.signal(signal.SIGTERM, bm.interrupted)
    wipe_state(args.app)
    pid, sock, scratch = bm.launch(args.app, json.loads(args.config),
                                   dict(item.split("=", 1) for item in args.env))
    app = bm.App(args.app, sock)
    results = []
    tabs = 0

    opened: list[str] = []

    def run(action: str, **kwargs):
        response = app.run(action, **kwargs)
        reason = refused(response)
        if reason:
            print(f"   {action}: {reason}", file=sys.stderr)
        opened.extend(item for item in response.get("created", []) if str(item).startswith("tab_"))
        return reason

    def open_tab(path: str):
        # tN.localhost: Chromium resolves *.localhost to loopback, and each
        # host is its own site, so tabs get their own renderers as distinct
        # real sites would (one 127.0.0.1 site shares a few renderers).
        nonlocal tabs
        reason = run("openBrowser.chromium", url=base.replace("127.0.0.1", f"t{tabs}.localhost") + path)
        tabs += 0 if reason else 1

    def settle_measure(label: str, during=None, settle: float | None = None):
        time.sleep(args.settle if settle is None else settle)  # test script: let the app settle
        results.append(measure(pid, args.app, label, args.measure, during, sample_idle=args.sample_idle))

    try:
        print(f"PERF-POWER-MACHINE sudo_powermetrics={powermetrics(1) is not None}", flush=True)
        run("workspace.newAtBottom")
        run("workspace.selectLast")
        if "terminal" in scenarios:
            settle_measure("terminal")
        open_tab("/static.html?n=1")
        if "tab1" in scenarios:
            settle_measure("tab1")
        if "tab1-hidden" in scenarios:
            run("showHideAllWindows")
            settle_measure("tab1-hidden")
            run("showHideAllWindows")
        while tabs < 20:
            before = tabs
            open_tab(f"/static.html?n={tabs + 1}")
            if tabs == before:
                break
        # A tab's Chromium page loads when the tab is first shown: show each
        # once, as a person who opened 20 tabs and read them, then come back
        # to the last one.
        for tab in opened[1:] + opened[-1:]:
            app.run("tab.focus", target=tab)
            time.sleep(1)  # test script: let the shown page load
        if "tabs20" in scenarios:
            settle_measure("tabs20")
        if "tabs20-hidden" in scenarios:
            run("showHideAllWindows")
            settle_measure("tabs20-hidden")
            run("showHideAllWindows")
        if "switch" in scenarios:
            def switch(seconds: float):
                deadline, index = time.monotonic() + seconds, 0
                while time.monotonic() < deadline:
                    run("selectSurfaceByNumber", index=index % 9 + 1)
                    index += 1
                    time.sleep(0.5)  # test script: two tab switches a second
            settle_measure("switch", during=switch, settle=10)
        if "neighbors" in scenarios and len(opened) >= 4:
            time.sleep(args.settle)  # test script: hidden pages freeze before the first switch
            results.append({"label": "neighbors", **neighbor_switches(app, sock, opened, len(opened) - 1,
                                                                    args.neighbor_gap, args.neighbor_rounds)})
        if "title" in scenarios:
            # A page in view that changes its title every frame (a timer, a counter).
            open_tab("/busy.html?n=0")
            settle_measure("title", settle=10)
            run("closeTab")
        if "scroll" in scenarios:
            open_tab("/long.html")
            settle_measure("scroll", settle=10)
            run("closeTab")
        if "video" in scenarios:
            open_tab("/video.html")
            settle_measure("video", settle=30)  # 10 s to record the clip, then it loops
            run("closeTab")
        if "minimized" in scenarios:
            run("minimizeWindow")
            settle_measure("minimized")
    finally:
        bm.end_bundle(args.app)
        shutil.rmtree(scratch, ignore_errors=True)
    if args.out:
        with open(args.out, "w") as handle:
            json.dump({"app": args.app, "measure_s": args.measure, "results": results}, handle, indent=1)


if __name__ == "__main__":
    main()
