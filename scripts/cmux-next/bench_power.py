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
acpmux). It needs no root. GPU and display energy are not in it. The package
power (CPU, GPU, both together) comes from powermetrics: the one command line
pool.json `privileged.powermetrics` names, under `sudo -n` (decision D3: a lab
host gets the right from `host-setup.sh --grant-privileged`), one sampler per
measured window that SIGINT ends. --powermetrics auto uses it when the right is
there, require refuses before the launch without it (exit 2, sudo's reason,
nothing written), off never runs it.

`typing` types letters into the terminal in view (debug.key, a bench build) at
TYPING_KEYS_PER_S, a person's pace, for the whole window.

Usage (a fleet mini, never a laptop; launches the app through BenchApp):
  bench_power.py --app BUNDLE [--settle 120] [--measure 60]
      [--scenarios terminal,typing,tab1,tab1-hidden,tabs20,tabs20-hidden,title,scroll,video,switch,neighbors,minimized]
      [--powermetrics auto|require|off] [--story power] [--out FILE.json | --out DIR]
Prints one PERF-POWER line per scenario and kind, plus a total line. An --out
that does not end in .json is the lab runner's folder: the report goes to
DIR/bench-power.json and each window's series to cmux-perf-result/v1 files
through BenchApp.record (stories.d/power.json, the T1 power story):
  power.<scenario>.package_mw, .cpu_mw, .gpu_mw   powermetrics, one sample a second
  power.<scenario>.processes_mw                    the owned processes' energy, one sample a window
  power.<scenario>.wakeups_per_s                   their wakeups, one sample a window

`neighbors` (browser.keepNeighborTabsAwake, plans/cmux-next/neighbor-tabs-DESIGN.md)
times switches among the 20 tabs: to the next tab (a neighbor) and to a tab 10
away (far), each after `--neighbor-gap` seconds so far pages are frozen again.
Run it with "browser": {"freezeHiddenTabs": 5} and once each with
"keepNeighborTabsAwake": 0 (before) and 1 (after). Prints PERF-NEIGHBOR lines:
the app's own switch time (debug.tab_switch) and the time until the page runs
script again (live_ms), plus the app's cold-show and prewarm counts.

--attribute (p14-energy-096) attributes each window's power as idle-budget.py's
power-visible session does (scripts/perf-bench/power_attribution.py): billed
energy per process (CPU + billed - serviced), owners per kind and thread that
sum to within 10% of the app's coalition total, WindowServer's own energy with
`sudo -n`. Prints POWER-BREAKDOWN, POWER-OWNER, POWER-UNNAMED and
POWER-WINDOWSERVER lines per scenario. The Chrome comparison (POWER-OVER) is
idle-budget.py --sessions power-visible,chrome-power-visible.
"""
from __future__ import annotations

import argparse
import ctypes
import http.server
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import threading
import time
from xml.parsers.expat import ExpatError

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(1, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf-bench"))
import bench_memory as bm  # noqa: E402  (App, owned, note_child_launch, interrupted)
import power_attribution  # noqa: E402  (--attribute: who spends the window's power, billed energy included)
from bench_launch import DEFAULT_CONFIG, PERF_LAB, BenchApp, RecordError, load_by_path, tag_of  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

# macOS only; elsewhere the module still loads, so --help and the tests work and main() refuses to run.
_libproc = ctypes.CDLL("/usr/lib/libproc.dylib") if sys.platform == "darwin" else None
MB = 1048576.0
# The lab's privileged commands (decision D3): its sudoers entry allows exactly these argv lists.
POOL = os.path.join(PERF_LAB, "pool.json")
# The sample interval of pool.json's powermetrics command line (-i 1000); a shorter sample is the one SIGINT cut.
POWERMETRICS_INTERVAL_NS = 1_000_000_000
COMPLETE_SAMPLE_FRACTION = 0.9
# The typing scenario: a person's pace, letters only (each one a key the terminal echoes).
TYPING_KEYS_PER_S = 8
TYPED = "cmuxkeepsidleworkatzero"
STORY = "power"

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


class Refused(Exception):
    """The run cannot measure what it was asked to (a missing right); it writes nothing."""


def sudo_reason(done) -> str:
    """What sudo said when it refused (stderr, else stdout), or its exit status."""
    return (done.stderr or done.stdout or "").strip() or f"exit {done.returncode}"


def powermetrics_command(pool: str = POOL) -> list[str]:
    """pool.json's one powermetrics argv (the sudoers entry allows no other) under `sudo -n`, which never prompts."""
    with open(pool, encoding="utf-8") as handle:
        return ["sudo", "-n", *json.load(handle)["privileged"]["powermetrics"]]


def powermetrics_refusal(command: list[str], run=subprocess.run) -> str | None:
    """None when this account may run `command` with no password, else why not (`sudo -n -l` runs nothing)."""
    sampler = command[2:]
    try:
        done = run(["sudo", "-n", "-l", *sampler], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"cannot run `sudo -n -l {sampler[0]}` ({error})"
    if done.returncode == 0:
        return None
    return (f"this account may not run `{' '.join(sampler)}` without a password ({sudo_reason(done)}); a lab host "
            "gets the right from `host-setup.sh --grant-privileged` (decision D3)")


def package_sample(document) -> dict | None:
    """{cpu_power_mw, gpu_power_mw, ane_power_mw, combined_power_mw} of one powermetrics plist sample (the Apple
    silicon `processor` block, mW over the sample), or None for a sample SIGINT cut short or one with no power."""
    if not isinstance(document, dict):
        return None
    elapsed = document.get("elapsed_ns")
    if isinstance(elapsed, (int, float)) and elapsed < POWERMETRICS_INTERVAL_NS * COMPLETE_SAMPLE_FRACTION:
        return None
    processor = document.get("processor") if isinstance(document.get("processor"), dict) else {}
    gpu = document.get("gpu") if isinstance(document.get("gpu"), dict) else {}
    found = {"cpu_power_mw": processor.get("cpu_power"),
             "gpu_power_mw": processor.get("gpu_power", gpu.get("gpu_power")),
             "ane_power_mw": processor.get("ane_power")}
    found = {key: float(value) for key, value in found.items()
             if isinstance(value, (int, float)) and not isinstance(value, bool)}
    combined = processor.get("combined_power")
    if isinstance(combined, (int, float)) and not isinstance(combined, bool):
        found["combined_power_mw"] = float(combined)
    elif found:
        found["combined_power_mw"] = sum(found.values())
    return found or None


def package_samples(stream: bytes) -> list[dict]:
    """The complete samples of powermetrics' `-f plist` output: one plist document per sample, NUL-separated."""
    samples = []
    for chunk in stream.split(b"\0"):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            sample = package_sample(plistlib.loads(chunk))
        except (ValueError, ExpatError):  # plistlib.InvalidFileException is a ValueError
            continue  # the document SIGINT cut off mid-write
        if sample:
            samples.append(sample)
    return samples


class PackagePower:
    """Package power over one measured window: pool.json's powermetrics command (it samples every second and ends by
    itself after 600) runs from `start` until `stop`, which ends it with SIGINT and returns the window's complete
    samples. The bench may signal sudo but not the root sampler, so sudo must pass the signal on, and sudo passes on
    no signal from the command's own process group: the sampler starts in a session of its own. `popen` is the seam
    the tests replace."""

    def __init__(self, command: list[str], popen=subprocess.Popen):
        self.command = command
        self.popen = popen
        self.process = None
        self.reader = None
        self.output = bytearray()

    def start(self) -> None:
        self.output = bytearray()
        self.process = self.popen(self.command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, start_new_session=True)
        self.reader = threading.Thread(target=self._read, args=(self.process.stdout, self.output), daemon=True)
        self.reader.start()

    @staticmethod
    def _read(stdout, output: bytearray) -> None:
        for chunk in iter(lambda: stdout.read(65536), b""):
            output.extend(chunk)

    def stop(self) -> list[dict]:
        process, self.process = self.process, None
        if process is None:
            return []
        for signum in (signal.SIGINT, signal.SIGTERM):  # sudo passes both on to the sampler
            process.send_signal(signum)
            try:
                process.wait(timeout=15)
                break
            except subprocess.TimeoutExpired:
                continue
        else:
            process.kill()  # sudo only; the root sampler still ends by itself after its fixed -n count
            process.wait(timeout=15)
        self.reader.join(timeout=15)
        return package_samples(bytes(self.output))


def package_summary(samples: list[dict]) -> dict:
    """The window's median of each powermetrics series (perf_stats.pct) and its sample count; {} with no sample."""
    if not samples:
        return {}
    keys = sorted({key for sample in samples for key in sample})
    medians = {key: round(perf_stats.pct([sample[key] for sample in samples if key in sample], 0.5), 3)
               for key in keys}
    return {**medians, "samples": len(samples)}


def power_window(app_pid: int, bundle: str):
    """A power_attribution.PowerWindow over the app's owned processes, classified by bench_memory's kinds."""
    kinds: dict[str, str] = {}

    def pids():
        found = bm.owned(app_pid, bundle)
        kinds.update({cmd: kind for kind, cmd in found.values()})
        return {pid: cmd for pid, (_kind, cmd) in found.items()}

    return power_attribution.PowerWindow(app_pid, pids, lambda cmd, _pid=None: kinds.get(cmd, "other"))


def measure(app_pid: int, bundle: str, label: str, seconds: float, during=None, sample_idle: bool = False,
            attribute: bool = False, package: PackagePower | None = None):
    """Energy, CPU and wakeups of every owned process over `seconds`; with `attribute`, its power owners; with
    `package`, powermetrics' package power over the same window (result["package_samples"], one a second)."""
    # PowerWindow's subprocesses (ps, sudo) run before `start` and after the end counters, outside both brackets.
    window = power_window(app_pid, bundle) if attribute else None
    if window:
        window.prepare()
    start = {pid: (kind, counters(pid)) for pid, (kind, _cmd) in bm.owned(app_pid, bundle).items()}
    if window:
        window.begin()
    started = time.monotonic()
    # An attributed window runs no subprocess: an app launched by the bench shares its coalition, and a
    # subprocess that exits inside the window would add its energy to the total with no owner.
    pm = None if attribute else package
    if pm:
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
    if window:
        window.end()
    elapsed = time.monotonic() - started
    ends = {pid: counters(pid) for pid in start}
    window_samples = pm.stop() if pm else []  # after the end counters: stopping the sampler is not in the window
    pm_result = package_summary(window_samples)
    raw = window.finish() if window else None
    kinds: dict[str, dict] = {}
    for pid, (kind, first) in start.items():
        last = ends[pid]
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
              "kinds": dict(sorted(kinds.items(), key=lambda item: -item[1]["mw"])), "powermetrics": pm_result,
              "package_samples": window_samples}
    for kind, entry in result["kinds"].items():
        print(f"PERF-POWER {label} kind={kind} n={entry['count']} mw={entry['mw']} cpu_pct={entry['cpu_pct']} "
              f"wakeups_per_s={entry['wakeups_per_s']} footprint_mb={round(entry['footprint_mb'], 1)}")
    print(f"PERF-POWER-TOTAL {label} mw={total['mw']} cpu_pct={total['cpu_pct']} wakeups_per_s={total['wakeups_per_s']} "
          f"footprint_mb={round(total['footprint_mb'], 1)} powermetrics={json.dumps(pm_result)}", flush=True)
    if raw is not None:
        result["power"] = power_attribution.attribute(raw)
        for line in power_attribution.report_lines(label, result["power"]):
            print(line, flush=True)
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
    def quantile(values, q):
        value = perf_stats.pct(values, q)
        return None if value is None else round(value, 2)
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
        result[kind] = {"n": len(picked), "live_p50_ms": quantile(live, 0.5), "live_p90_ms": quantile(live, 0.9),
                        "switch_p50_ms": quantile(commit, 0.5), "switch_p90_ms": quantile(commit, 0.9)}
        print(f"PERF-NEIGHBOR {kind} radius={result['neighbor_radius']} n={len(picked)} live_p50_ms={result[kind]['live_p50_ms']} "
              f"live_p90_ms={result[kind]['live_p90_ms']} switch_p50_ms={result[kind]['switch_p50_ms']} "
              f"switch_p90_ms={result[kind]['switch_p90_ms']}", flush=True)
    print(f"PERF-NEIGHBOR-COUNTS cold_shows={result['cold_shows_total']} prewarmed={result['prewarmed_total']}", flush=True)
    result["rows"] = rows
    return result


def refused(response: dict) -> str | None:
    return response.get("error") or (response.get("message") if response.get("code") else None)


SCENARIOS = ("terminal", "typing", "tab1", "tab1-hidden", "tabs20", "tabs20-hidden", "switch", "neighbors", "title",
             "scroll", "video", "minimized")
# The scenarios that run with 20 tabs open; a run without any of them never opens the 20.
TWENTY_TAB_SCENARIOS = {"tabs20", "tabs20-hidden", "switch", "neighbors"}
# result-v1 metric suffix -> package_sample key: powermetrics' series, one sample a second.
PACKAGE_SERIES = (("package_mw", "combined_power_mw"), ("cpu_mw", "cpu_power_mw"), ("gpu_mw", "gpu_power_mw"))
# The tabs are Chromium pages (openBrowser.chromium): every window is the Chromium arm.
ENGINE = "chromium"


def out_paths(out: str | None) -> tuple[str | None, str | None]:
    """(report file, result-v1 folder) of --out. A path ending in .json is the report file; any other path is the
    lab runner's folder, which gets bench-power.json and the result-v1 files."""
    if not out:
        return None, None
    if out.endswith(".json"):
        return out, None
    os.makedirs(out, exist_ok=True)
    return os.path.join(out, "bench-power.json"), out


def window_series(result: dict) -> list[tuple[str, str, list[float]]]:
    """(metric, unit, samples) of one measured window: powermetrics' series, one sample a second, then the owned
    processes' energy and wakeups, one sample a window."""
    label = result["label"]
    series = []
    for name, key in PACKAGE_SERIES:
        values = [sample[key] for sample in result.get("package_samples", []) if key in sample]
        if values:
            series.append((f"power.{label}.{name}", "mW", values))
    series.append((f"power.{label}.processes_mw", "mW", [result["total"]["mw"]]))
    series.append((f"power.{label}.wakeups_per_s", "per_s", [result["total"]["wakeups_per_s"]]))
    return series


def record_window(bench, story: str, result: dict, package_required: bool) -> dict[str, str]:
    """Writes one window's series as result-v1 through `bench`.record (a BenchApp). Returns {metric: path or
    "not recorded: <reason>"}; with `package_required`, a window powermetrics gave no complete sample of is one."""
    written = {}
    if package_required and not result.get("package_samples"):
        written[f"power.{result['label']}.package_mw"] = "not recorded: powermetrics gave no complete sample"
    for metric, unit, samples in window_series(result):
        try:
            written[metric] = str(bench.record(story, metric, unit, samples, better="lower", engine=ENGINE))
        except (RecordError, perf_result.ResultError) as error:
            written[metric] = f"not recorded: {error}"
    return written


def unrecorded(recorded: dict[str, dict[str, str]]) -> list[str]:
    """"<metric>: <outcome>" of every series a window could not record."""
    return [f"{metric}: {outcome}" for written in recorded.values() for metric, outcome in written.items()
            if outcome.startswith("not recorded")]


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    # Chromium does post-load work (code caching, GC, tile purges) for about two
    # minutes after tabs open or hide; shorter settles measure that, not idle.
    parser.add_argument("--settle", type=float, default=120)
    parser.add_argument("--measure", type=float, default=60)
    parser.add_argument("--scenarios", default="terminal,tab1,tab1-hidden,tabs20,tabs20-hidden,title,scroll,video,switch,minimized")
    parser.add_argument("--config", default="{}", help="extra cmux.json settings (JSON)")
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                        help="extra app environment, e.g. CMUX_NEXT_CEF_EXTRA_SWITCHES=... (repeatable)")
    parser.add_argument("--neighbor-gap", type=float, default=7, help="seconds before each neighbors-scenario switch")
    parser.add_argument("--neighbor-rounds", type=int, default=10)
    parser.add_argument("--sample-idle", action="store_true",
                        help="sample the app's stacks inside each idle window; keep the sample when the app is above 1 mW")
    parser.add_argument("--attribute", action="store_true",
                        help="attribute each window's power to owners (billed energy, per thread, WindowServer); "
                        "no powermetrics or --sample-idle inside an attributed window")
    parser.add_argument("--powermetrics", choices=("auto", "require", "off"), default="auto",
                        help="package power from pool.json's powermetrics command under sudo -n (decision D3): auto "
                             "when this account has the right, require refuses without it (exit 2, nothing written)")
    parser.add_argument("--story", default=STORY, help="result-v1 story of the windows (with an --out folder)")
    parser.add_argument("--tag", help="the lab runner's tag of --app (checked against the bundle's name)")
    parser.add_argument("--build-config", choices=("bench", "bench-checks", "release", "debug"),
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    parser.add_argument("--out", help="the report file (FILE.json), or the lab runner's folder for bench-power.json "
                                      "and the result-v1 files")
    args = parser.parse_args(argv)
    if args.attribute and args.sample_idle:
        parser.error("--attribute and --sample-idle: a sample inside the window is an unowned subprocess in the app's coalition")
    if args.attribute and args.powermetrics == "require":
        parser.error("--attribute and --powermetrics require: an attributed window runs no powermetrics")
    unknown = sorted(set(args.scenarios.split(",")) - set(SCENARIOS))
    if unknown:
        parser.error(f"unknown scenarios {', '.join(unknown)} (known: {', '.join(SCENARIOS)})")
    return args


def package_power(mode: str, attribute: bool) -> tuple[PackagePower | None, str | None]:
    """(the run's package sampler or None, why there is none). Raises Refused when `mode` is require and this account
    may not run pool.json's powermetrics command."""
    if mode == "off":
        return None, "--powermetrics off"
    if attribute:
        return None, "--attribute runs no subprocess inside its windows"
    command = powermetrics_command()
    reason = powermetrics_refusal(command)
    if reason and mode == "require":
        raise Refused(f"power story refused: {reason}; without package power it writes nothing")
    return (None, reason) if reason else (PackagePower(command), None)


def main(argv=None) -> int:
    args = parse(argv)
    if sys.platform != "darwin":
        raise SystemExit("bench-power: macOS only (run it on a fleet or lab mini)")
    bundle = os.path.realpath(args.app)
    if args.tag and args.tag != tag_of(bundle):
        raise SystemExit(f"bench-power: --tag {args.tag} is not the tag of {bundle} ({tag_of(bundle)})")
    try:
        package, why_not = package_power(args.powermetrics, args.attribute)
    except Refused as error:
        print(f"bench-power: {error}", file=sys.stderr)
        return 2
    report_path, results_dir = out_paths(args.out)
    scenarios = args.scenarios.split(",")
    base = serve()
    signal.signal(signal.SIGTERM, bm.interrupted)
    wipe_state(bundle)
    bench = BenchApp(bundle, out=results_dir, env=dict(item.split("=", 1) for item in args.env),
                     config=bm.merged(DEFAULT_CONFIG, json.loads(args.config)), build_config=args.build_config)
    bm.note_child_launch()
    try:
        bench.launch()
    except BaseException:
        bench.stop()
        raise
    pid, sock = bench.process.pid, bench.socket
    app = bm.App(bundle, sock)
    results = []
    recorded: dict[str, dict[str, str]] = {}
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
        result = measure(pid, bundle, label, args.measure, during, sample_idle=args.sample_idle,
                         attribute=args.attribute, package=package)
        results.append(result)
        if results_dir:
            recorded[label] = record_window(bench, args.story, result, args.powermetrics == "require")

    try:
        print(f"PERF-POWER-MACHINE sudo_powermetrics={package is not None}"
              + (f" reason={json.dumps(why_not)}" if why_not else ""), flush=True)
        run("workspace.newAtBottom")
        run("workspace.selectLast")
        if "terminal" in scenarios:
            settle_measure("terminal")
        if "typing" in scenarios:
            def typing(seconds: float):
                deadline, index = time.monotonic() + seconds, 0
                while time.monotonic() < deadline:
                    app.call("debug.key", {"key": TYPED[index % len(TYPED)]}, timeout=10)
                    index += 1
                    time.sleep(1 / TYPING_KEYS_PER_S)  # test script: a person's typing pace
            settle_measure("typing", during=typing, settle=10)
        open_tab("/static.html?n=1")
        if "tab1" in scenarios:
            settle_measure("tab1")
        if "tab1-hidden" in scenarios:
            run("showHideAllWindows")
            settle_measure("tab1-hidden")
            run("showHideAllWindows")
        if TWENTY_TAB_SCENARIOS.intersection(scenarios):
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
        bench.stop()
    report = {"app": bundle, "measure_s": args.measure, "results": results}
    if results_dir:
        report["recorded"] = recorded
    if report_path:
        with open(report_path, "w") as handle:
            json.dump(report, handle, indent=1)
    failures = unrecorded(recorded)
    for failure in failures:
        print(f"bench-power: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
