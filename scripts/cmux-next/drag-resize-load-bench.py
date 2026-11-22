#!/usr/bin/env python3
"""Pane drags, split resizes and the live window resize under a many-chats load, with a main-thread sample.

Leo, 2026-11-21: "can u also help improve the fps and responsivenss of my computer pls its beenlagging for very very
long today" and "oh that's... fine i guess but i meant the windows andresizing anddragging panes around".

One launch of the tagged app per scenario run (bench_launch.BenchApp). After each launch, before the scenario, the load:
a workspace of its own with --chats mock agent chats (palette.newAgentChat, each seeded with --rows rows), all hidden
once the first workspace is shown again, each streamed every 3 s (`debug.agent_pane` `stream`, as stress-bench.py's
chats angle) for the whole run. Then the scenario, the harness's own code:

  golden_resize   golden.py's live window resize (the corner out by 300 x 150 points and back), judged by judge_resize
  split_chat      split_resize.drive on an agent chat beside a terminal: divider and window-edge gestures
  split_browser   the same with the Chromium probe page
  pane_drag       scripts/ci/frame-pacing/pane_drag.py at --counts (tab and pane-header drags)

Each scenario runs --runs times, plus one more run (run 0, not in the stats) in which `sample PID SECONDS` takes the
app's main thread during its gesture: golden_resize's first drag; split_*'s first divider and first window-edge drag;
pane_drag's first drop at the largest count (pane_drag run 0 measures that count only). The report keeps each
sample's main-thread top frames by self weight and its raw text (first 400 KB).

Run through the allowlisted fleet entry, which builds the app at the commit:
  cmux-ci run --class exclusive --measurement --label gui-session-v1 --script scripts/measure/split-spring.sh \
    --ref SHA --arg=--suite=drag-resize-load --arg=--vdisplay=120 --artifact artifacts/split-spring/report.json

Usage: drag-resize-load-bench.py --app APP --out DIR --json PATH [--runs 3] [--chats 20] [--rows 5000]
       [--scenarios golden_resize,split_chat,split_browser,pane_drag] [--counts 2,8,30] [--no-load]
Report only: exits 0 whenever the report was written.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "ci", "frame-pacing"))
import bench_launch  # noqa: E402
import golden  # noqa: E402
import pane_drag  # noqa: E402
import split_resize  # noqa: E402

SCENARIOS = ("golden_resize", "split_chat", "split_browser", "pane_drag")

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json", required=True)
parser.add_argument("--tag")
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--chats", type=int, default=20)
parser.add_argument("--rows", type=int, default=5000)
parser.add_argument("--scenarios", default=",".join(SCENARIOS))
parser.add_argument("--counts", default="2,8,30")
parser.add_argument("--drops", type=int, default=4)
parser.add_argument("--pane-deadline", type=float, default=900)
parser.add_argument("--sample-seconds", type=int, default=3)
parser.add_argument("--no-load", action="store_true")
parser.add_argument("--no-sample", action="store_true")
opts, _unknown = parser.parse_known_args()



def fact(*command) -> str:
    try:
        return subprocess.run(list(command), capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


OUT = Path(opts.out).resolve() / "drag-resize-load"
OUT.mkdir(parents=True, exist_ok=True)
REPORT: dict = {"tool": "scripts/cmux-next/drag-resize-load-bench.py", "runs_asked": opts.runs,
                "load_asked": None if opts.no_load else {"chats": opts.chats, "rows": opts.rows, "stream_every_s": 3},
                "host": fact("/usr/sbin/scutil", "--get", "ComputerName"), "model": fact("/usr/sbin/sysctl", "-n", "hw.model"),
                "chip": fact("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"),
                "scenarios": {}}


def log(line: str) -> None:
    print(f"DRAG-RESIZE-LOAD {line}"[:4000], flush=True)


def write() -> None:
    tmp = opts.json + ".tmp"
    with open(tmp, "w") as f:
        json.dump(REPORT, f, indent=1)
    os.replace(tmp, opts.json)


def wait(predicate, seconds, step=0.25):
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bounded wait for the live app
        try:
            value = predicate()
        except Exception:  # noqa: BLE001  the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


# ------------------------------------------------------------------ the main-thread sample

def main_thread_top(text: str, top: int = 10) -> list:
    """Self weight per frame on the main thread of a `sample` call graph: a node's count less its children's."""
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if "com.apple.main-thread" in l and re.match(r"^\s+\d+ Thread_", l)), None)
    if start is None:
        return []
    total = int(re.match(r"^\s+(\d+)", lines[start]).group(1))
    base = re.match(r"^(\s+)", lines[start]).end()
    nodes = []  # [depth, count, label]
    for line in lines[start + 1:]:
        m = re.match(r"^([ +!:|]*)(\d+) (.*)$", line)
        if not m or len(m.group(1)) <= base:
            break
        nodes.append([len(m.group(1)), int(m.group(2)), m.group(3)])
    own = [n[1] for n in nodes]
    stack = []  # indexes of open ancestors
    for i, (depth, count, _label) in enumerate(nodes):
        while stack and nodes[stack[-1]][0] >= depth:
            stack.pop()
        if stack:
            own[stack[-1]] -= count
        stack.append(i)
    selfw: dict = {}
    for (_depth, _count, label), weight in zip(nodes, own):
        if weight > 0:
            key = re.sub(r"\s+\[0x[0-9a-f,]+\].*$", "", label)
            key = re.sub(r"\)\s+\+\s+\d+$", ")", key).strip()
            selfw[key] = selfw.get(key, 0) + weight
    ranked = sorted(selfw.items(), key=lambda kv: -kv[1])[:top]
    return [{"frame": k[:240], "samples": v, "share": round(v / total, 3) if total else None} for k, v in ranked]


class Sampler:
    """`sample PID SECONDS` on its own thread, started once per name."""

    def __init__(self, folder: Path):
        self.folder, self.taken, self.threads, self.pid = folder, {}, [], None

    def take(self, name: str) -> None:
        if opts.no_sample or self.pid is None or name in self.taken:
            return
        path = self.folder / f"sample-{name}.txt"
        self.taken[name] = {"path": str(path), "started_at": time.time()}

        def run():
            done = subprocess.run(["/usr/bin/sample", str(self.pid), str(opts.sample_seconds), "-mayDie", "-file", str(path)],
                                  capture_output=True, text=True, timeout=opts.sample_seconds + 60)
            entry = self.taken[name]
            entry["exit"] = done.returncode
            entry["stderr"] = done.stderr[-400:]
            try:
                text = path.read_text(errors="replace")
            except OSError as error:
                entry["error"] = str(error)
                return
            entry["main_thread_top"] = main_thread_top(text)
            entry["raw"] = text[:400_000]
            log(f"sample {name}: " + json.dumps(entry["main_thread_top"][:5])[:1500])

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        self.threads.append(thread)

    def join(self) -> dict:
        for thread in self.threads:
            thread.join(timeout=opts.sample_seconds + 90)
        return self.taken


SAMPLER: Sampler | None = None


# ------------------------------------------------------------------ the load

class Load:
    """--chats mock chats in a workspace of their own, streamed every 3 s until stopped."""

    def __init__(self, app):
        self.app, self.panes, self.flag, self.threads = app, [], threading.Event(), []
        self.calls = self.errors = 0
        self.notes: list = []
        self.first_error = None

    def rpc(self, method, params=None, timeout=30):
        return bench_launch.rpc_at(self.app.socket, method, params, timeout)

    def action(self, name, args=None, target=None, timeout=60):
        params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
        if target:
            params["target"] = target
        return self.rpc("action.run", params, timeout=timeout)

    def workspaces(self):
        topo = (self.rpc("snapshot.get") or {}).get("topology") or {}
        return [w.get("id") for w in topo.get("workspaces") or [] if w.get("id")]

    def setup(self) -> dict:
        t0 = time.monotonic()
        first = (self.workspaces() or [None])[0]
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        made = subprocess.run([self.app.cli, "--app-socket", self.app.socket, "workspace", "create", "--name", "chat load"],
                              env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        found = re.search(r"value\.workspace_id\s+(\S+)", made.stdout)
        ref = found.group(1) if found else None
        if ref:
            subprocess.run([self.app.cli, "--app-socket", self.app.socket, "workspace", ref, "focus"], env=env,
                           capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
            time.sleep(1.0)  # bench: the new workspace shows
        else:
            self.notes.append(f"workspace create: {made.returncode} {made.stderr[-300:]}")
        for index in range(opts.chats):
            self.action("palette.newAgentChat", timeout=120)
            time.sleep(0.5)  # bench: the chat tab opens
            wait(lambda: (self.rpc("debug.agent_pane", {"action": "readiness"}, timeout=5) or {}).get("document_ready"), 30, 0.5)
            engine = self.rpc("debug.agent_pane", {"action": "engine"}, timeout=10) or {}
            pane = engine.get("pane") if isinstance(engine, dict) else None
            if not pane:
                self.notes.append(f"chat {index}: no pane ({str(engine)[:200]})")
                continue
            self.rpc("debug.agent_pane", {"action": "select_session", "pane": pane, "session": "mock-session"}, timeout=30)
            seeded = self.rpc("debug.agent_pane", {"action": "seed_rows", "pane": pane, "count": opts.rows}, timeout=300)
            if isinstance(seeded, dict) and seeded.get("error"):
                self.notes.append(f"chat {pane}: seed_rows: {str(seeded.get('error'))[:200]}")
            self.panes.append(pane)
        if first:
            self.action("goToWorkspace", {"workspace": first})
            wait(lambda: ((self.rpc("snapshot.get") or {}).get("topology") or {}).get("focus", {}).get("workspace") == first, 20)
        for pane in self.panes:
            thread = threading.Thread(target=self.pump, args=(pane,), daemon=True)
            thread.start()
            self.threads.append(thread)
        time.sleep(2.0)  # bench: the streams run before the scenario
        return {"chats": len(self.panes), "rows": opts.rows, "setup_s": round(time.monotonic() - t0, 1),
                "workspace": ref or None, "notes": self.notes[:20]}

    def pump(self, pane):
        while not self.flag.is_set():
            t0 = time.monotonic()
            reply = self.rpc("debug.agent_pane", {"action": "stream", "pane": pane, "rows": 60, "seconds": 3,
                                                  "chunk_ms": 16, "chunk_chars": 48}, timeout=15)
            self.calls += 1
            if isinstance(reply, dict) and reply.get("error"):
                self.errors += 1
                self.first_error = self.first_error or str(reply.get("error"))[:300]
            self.flag.wait(max(0.1, 3.0 - (time.monotonic() - t0)))

    def stop(self) -> dict:
        self.flag.set()
        for thread in self.threads:
            thread.join(timeout=20)
        return {"stream_calls": self.calls, "stream_errors": self.errors, "first_error": self.first_error}


CURRENT: dict = {}  # the run's load and its record
_launch, _stop, _init = bench_launch.BenchApp.launch, bench_launch.BenchApp.stop, bench_launch.BenchApp.__init__


def init_main_screen(self, *args, **kwargs):
    kwargs["screen"] = "0"  # the step's 120 Hz virtual display is the main one; pane_drag asks for "last"
    return _init(self, *args, **kwargs)


bench_launch.BenchApp.__init__ = init_main_screen


def launch_with_load(self, *args, **kwargs):
    result = _launch(self, *args, **kwargs)
    if SAMPLER is not None and self.process is not None:
        SAMPLER.pid = self.process.pid
    CURRENT["app_pid"] = self.process.pid if self.process else None
    if not opts.no_load:
        load = Load(self)
        CURRENT["load_obj"] = load
        try:
            CURRENT["load"] = load.setup()
        except Exception as error:  # noqa: BLE001  the scenario still runs, unloaded, and says so
            CURRENT["load"] = {"error": repr(error)[:300]}
        log("load " + json.dumps(CURRENT["load"])[:1500])
    return result


def stop_with_load(self, *args, **kwargs):
    load = CURRENT.pop("load_obj", None)
    if load is not None:
        CURRENT.setdefault("load", {}).update(load.stop())
    return _stop(self, *args, **kwargs)


bench_launch.BenchApp.launch = launch_with_load
bench_launch.BenchApp.stop = stop_with_load

# Sample hooks: golden.Driver.trace (golden_resize, split_*), pane_drag.Driver.measure.
_trace = golden.Driver.trace
TRACE_COUNT = {"n": 0}
SAMPLE_AT_TRACE: dict = {}  # trace index -> sample name


def trace_with_sample(self, targets, act, seconds):
    index = TRACE_COUNT["n"]
    TRACE_COUNT["n"] += 1
    name = SAMPLE_AT_TRACE.get(index)
    if name and SAMPLER is not None:
        SAMPLER.take(name)
    return _trace(self, targets, act, seconds)


golden.Driver.trace = trace_with_sample
_measure = pane_drag.Driver.measure
PANE_SAMPLE_MIN = {"count": None}


def measure_with_sample(self, start, end, modifiers, meta, name):
    m = re.match(r"^(tab|pane)-(\d+)-", name)
    if SAMPLER is not None and PANE_SAMPLE_MIN["count"] and m and int(m.group(2)) >= PANE_SAMPLE_MIN["count"]:
        SAMPLER.take(f"{m.group(1)}-drop-{m.group(2)}-panes")
    return _measure(self, start, end, modifiers, meta, name)


pane_drag.Driver.measure = measure_with_sample


# ------------------------------------------------------------------ the scenarios

def run_golden_resize(folder: Path) -> dict:
    app = bench_launch.BenchApp(opts.app, out=str(folder), window=(80, 80, 1100, 720))
    result: dict = {}
    try:
        app.launch()
        driver = golden.Driver(app.socket, folder)
        time.sleep(3)  # bench: launch work settles
        driver.window_resize()
        data = golden.load(folder, "window_resize") or {}
        refresh = next((float(d.get("refresh_ms") or 0) for d in data.get("drags") or [] if float(d.get("refresh_ms") or 0) > 0), 1000 / 120)
        # Frame intervals of every drag, for dropped frames (an interval over 1.5 refresh periods).
        intervals = []
        for trace in data.get("drags") or []:
            times = golden.times_of([s for s in trace.get("samples") or [] if s.get("window")])
            intervals += [b - a for a, b in zip(times, times[1:])]
        verdict = golden.judge_resize(data, refresh)
        result = {"verdict": verdict, "refresh_ms": refresh, "intervals_ms": [round(i, 2) for i in intervals],
                  "log": driver.log[-20:]}
    except (Exception, SystemExit) as error:
        result["error"] = repr(error)[:500]
        result["traceback"] = traceback.format_exc()[-2000:]
    finally:
        app.stop()
    return result


def run_split(pane: str, folder: Path) -> dict:
    app = bench_launch.BenchApp(opts.app, out=str(folder), window=(80, 80, 1100, 720))
    result: dict = {"pane": pane}
    try:
        app.launch()
        driver = golden.Driver(app.socket, folder)
        driver.call("debug.motion", {"action": "speed", "value": "fast"})
        driver.call("debug.motion", {"action": "reduce", "value": False})
        split_resize.drive(driver, folder, strip=False, pane=pane, gestures=["divider", "window-edge"])
        data = json.loads((folder / "split_resize.json").read_text())
        refresh = next((float(d.get("refresh_ms") or 0) for d in data.get("drags") or [] if float(d.get("refresh_ms") or 0) > 0), 1000 / 60)
        result.update(split_resize.judge(data, refresh))
        result["refresh_ms"] = refresh
        result.pop("drags", None)
        result["log"] = driver.log[-20:]
    except (Exception, SystemExit) as error:
        result["error"] = repr(error)[:500]
        result["traceback"] = traceback.format_exc()[-2000:]
    finally:
        app.stop()
    return result


def run_pane_drag(folder: Path, counts: str) -> dict:
    path = folder / "pane-drag.json"
    try:
        code = pane_drag.main(["--app", opts.app, "--counts", counts, "--drops", str(opts.drops), "--json", str(path),
                               "--out", str(folder), "--deadline", str(opts.pane_deadline)])
    except (Exception, SystemExit) as error:
        return {"error": repr(error)[:500], "traceback": traceback.format_exc()[-2000:]}
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        return {"error": f"no report ({error}), exit {code}"}
    for entry in data.get("counts") or []:
        for gesture in ("tab", "pane"):
            if isinstance(entry.get(gesture), dict):
                entry[gesture]["each"] = [{k: v for k, v in d.items() if k not in ("trace", "frames", "samples_raw")}
                                          for d in entry[gesture].get("each") or []]
    return data


def one_run(scenario: str, run: int) -> dict:
    global SAMPLER
    folder = OUT / scenario / f"run-{run}"
    folder.mkdir(parents=True, exist_ok=True)
    sampled = run == 0
    SAMPLER = Sampler(folder) if sampled else None
    TRACE_COUNT["n"] = 0
    SAMPLE_AT_TRACE.clear()
    PANE_SAMPLE_MIN["count"] = None
    CURRENT.clear()
    max_count = max(int(c) for c in opts.counts.split(",") if c.strip())
    if sampled:
        if scenario == "golden_resize":
            SAMPLE_AT_TRACE[0] = "window-resize-out"
        elif scenario.startswith("split_"):
            SAMPLE_AT_TRACE[0] = "divider"
            SAMPLE_AT_TRACE[4] = "window-edge"
        else:
            PANE_SAMPLE_MIN["count"] = max(2, int(max_count * 0.8))
    t0 = time.monotonic()
    if scenario == "golden_resize":
        result = run_golden_resize(folder)
    elif scenario == "split_chat":
        result = run_split("chat", folder)
    elif scenario == "split_browser":
        result = run_split("browser", folder)
    else:
        result = run_pane_drag(folder, str(max_count) if sampled else opts.counts)
    result["seconds"] = round(time.monotonic() - t0, 1)
    result["load"] = CURRENT.get("load")
    result["app_pid"] = CURRENT.get("app_pid")
    result["sampled"] = sampled
    if SAMPLER is not None:
        result["samples"] = SAMPLER.join()
    return result


def main() -> int:
    scenarios = [s for s in opts.scenarios.split(",") if s]
    for s in scenarios:
        if s not in SCENARIOS:
            sys.exit(f"--scenarios: {s!r} is not one of {', '.join(SCENARIOS)}")
    log(f"start host={REPORT['host']} chip={REPORT['chip']} scenarios={scenarios} runs={opts.runs}+1 sampled")
    for scenario in scenarios:
        runs = REPORT["scenarios"].setdefault(scenario, [])
        for run in range(0, opts.runs + 1):
            log(f"{scenario} run {run}{' (sampled)' if run == 0 else ''} starts")
            result = one_run(scenario, run)
            runs.append(result)
            brief = {k: v for k, v in result.items() if k not in ("samples", "counts", "log", "traceback", "intervals_ms", "gestures")}
            log(f"{scenario} run {run} done {json.dumps(brief)[:1500]}")
            if scenario.startswith("split_"):
                log(f"{scenario} run {run} gestures {json.dumps(result.get('gestures'))[:2500]}")
            if scenario == "golden_resize":
                log(f"{scenario} run {run} verdict {json.dumps(result.get('verdict'))[:1500]}")
            if scenario == "pane_drag":
                for entry in result.get("counts") or []:
                    for g in ("tab", "pane"):
                        summary = {k: v for k, v in (entry.get(g) or {}).items() if k != "each"}
                        log(f"pane_drag run {run} count={entry.get('asked')} {g} {json.dumps(summary)[:1200]}")
            write()
    log("done")
    write()
    return 0


if __name__ == "__main__":
    sys.exit(main())
