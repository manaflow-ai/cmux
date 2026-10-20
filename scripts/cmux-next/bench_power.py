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
  bench_power.py --app BUNDLE [--settle 20] [--measure 60]
      [--scenarios terminal,tab1,tab1-hidden,tabs20,tabs20-hidden,scroll,video,switch,minimized]
      [--out FILE.json]
Prints one PERF-POWER line per scenario and kind, plus a total line.
"""
from __future__ import annotations

import argparse
import ctypes
import http.server
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402  (launch, App, owned, end_bundle)

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
MB = 1048576.0

ARTICLE = "<p>" + ("cmux keeps idle work at zero. " * 40) + "</p>"
PAGES = {
    "/static.html": "<!doctype html><title>Static {n}</title><style>body{{font:16px -apple-system;max-width:720px;margin:40px auto}}</style>"
                    "<h1>Static page {n}</h1>" + ARTICLE * 6,
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


def measure(app_pid: int, bundle: str, label: str, seconds: float, during=None):
    """Energy, CPU and wakeups of every owned process over `seconds`."""
    start = {pid: (kind, counters(pid)) for pid, (kind, _cmd) in bm.owned(app_pid, bundle).items()}
    started = time.monotonic()
    pm_result = {}
    pm = threading.Thread(target=lambda: pm_result.update(powermetrics(seconds) or {}), daemon=True)
    pm.start()
    if during:
        during(seconds)
    else:
        time.sleep(seconds)  # test script: the measured window
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
    return result


def refused(response: dict) -> str | None:
    return response.get("error") or (response.get("message") if response.get("code") else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--settle", type=float, default=20)
    parser.add_argument("--measure", type=float, default=60)
    parser.add_argument("--scenarios", default="terminal,tab1,tab1-hidden,tabs20,tabs20-hidden,scroll,video,switch,minimized")
    parser.add_argument("--config", default="{}", help="extra cmux.json settings (JSON)")
    parser.add_argument("--out")
    args = parser.parse_args()
    scenarios = args.scenarios.split(",")
    base = serve()
    signal.signal(signal.SIGTERM, bm.interrupted)
    pid, sock, scratch = bm.launch(args.app, json.loads(args.config))
    app = bm.App(args.app, sock)
    results = []
    tabs = 0

    def run(action: str, **kwargs):
        reason = refused(app.run(action, **kwargs))
        if reason:
            print(f"   {action}: {reason}", file=sys.stderr)
        return reason

    def open_tab(path: str):
        nonlocal tabs
        reason = run("openBrowser.chromium", url=base + path)
        tabs += 0 if reason else 1

    def settle_measure(label: str, during=None, settle: float | None = None):
        time.sleep(args.settle if settle is None else settle)  # test script: let the app settle
        results.append(measure(pid, args.app, label, args.measure, during))

    try:
        print(f"PERF-POWER-MACHINE sudo_powermetrics={powermetrics(1) is not None}", flush=True)
        run("workspace.newAtBottom")
        run("workspace.selectLast")
        if "terminal" in scenarios:
            settle_measure("terminal")
        open_tab("/static.html?n=1")
        if "tab1" in scenarios:
            settle_measure("tab1", settle=args.settle + 10)
        if "tab1-hidden" in scenarios:
            run("showHideAllWindows")
            settle_measure("tab1-hidden")
            run("showHideAllWindows")
        while tabs < 20:
            before = tabs
            open_tab(f"/static.html?n={tabs + 1}")
            if tabs == before:
                break
        if "tabs20" in scenarios:
            settle_measure("tabs20", settle=args.settle + 20)
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
            settle_measure("switch", during=switch)
        if "scroll" in scenarios:
            open_tab("/long.html")
            settle_measure("scroll", settle=5)
            run("closeTab")
        if "video" in scenarios:
            open_tab("/video.html")
            settle_measure("video", settle=20)  # 10 s to record the clip, then it loops
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
