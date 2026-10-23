#!/usr/bin/env python3
"""Base against head, interleaved on one host: perf-gate.py plus Cmd-Tab, tab switch and pane focus in STRESS.

Written for the PL-arch batch 2 check (perf-lead.md section 5): a before/after perf-gate run on one host showed
Cmd-Tab light observers_ms p95 13.5 -> 24.5 ms and 4 late tab switches, both judged host noise without a rerun,
and the heavy activation lost the app's socket. This script answers "is it real" with repeated, interleaved runs
of two apps on the same host in the same step:

  gate     perf-gate.py (every scenario, --frames required, --hang-ms) on each app. A watchdog probes the app's
           socket whenever perf-gate prints nothing for --silent-s seconds; when the app does not answer in 20 s
           (a main-thread hang) it records a /usr/bin/sample of the app (OUT/<run>/hang-N.txt, the main thread's
           top frames in the report); when the app is gone, the crash report.
  stress   the app launched on the main display (bench_launch.BenchApp), STRESS built by
           perf-stress-session.py (its STRESS-SESSION line is in the report), Chromium checked real (debug.cef),
           then 20 Cmd-Tab cycles (activation-perf.py's cycles: observers_ms, resyncs), 40 Next Tab switches in the
           focused pane (debug.tab_switch: apply, commit, late_vsyncs) and 40 Focus Next Pane moves
           (debug.pane_focus). A socket call that times out records a sample the same way.

The two apps carry the same tag (split-spring), so they never run at once; each run ends the tag's daemons.
--order BH runs base then head, HB head then base (alternate it across rounds).

Fleet (the allowlisted entry builds the head app; the base app comes from the worker's app cache, put there by a
`--build-only` step of the base commit on the same worker):
  cmux-ci run --class exclusive --measurement --label measure --target-worker W \\
    --script scripts/measure/split-spring.sh --ref HEAD_SHA --timeout 14400 --no-supersede \\
    --artifact artifacts/split-spring/report.json \\
    --arg=--app-cache --arg=--vdisplay=60 --arg=--vdisplay-hold=14000 \\
    --arg=--suite=batch2-verify --arg=--base-sha=BASE_SHA --arg=--order=BH
The step passes whenever the report was written; every failure is a field in it.
"""
import argparse, glob, importlib.util, json, os, re, shutil, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError, crash_reports, crash_summary, rpc_at  # noqa: E402


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def note(text):
    print(f"batch2-verify: {text}", flush=True)


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return round(values[min(len(values) - 1, max(0, int(round(len(values) * q)) - 1))], 2)


def stats(values):
    values = [v for v in values if isinstance(v, (int, float))]
    return {"n": len(values), "p50": pct(values, 0.5), "p95": pct(values, 0.95),
            "max": round(max(values), 2) if values else None}


def main_thread_top(path, lines=45):
    """The first lines of the main thread's call graph in a /usr/bin/sample file."""
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return None
    graph = text.split("Call graph:", 1)[-1].splitlines()
    out, started = [], False
    for line in graph:
        if not started:
            started = "Thread_" in line and ("main-thread" in line or "com.apple.main-thread" in line or "DispatchQueue_1" in line)
            if not started:
                continue
        if line.strip():
            out.append(line.rstrip()[:200])
        if len(out) >= lines:
            break
    return "\n".join(out) if out else "\n".join(l.rstrip()[:200] for l in graph[:lines] if l.strip())


def sample(pid, path, seconds=5):
    try:
        subprocess.run(["/usr/bin/sample", str(pid), str(seconds), "-mayDie", "-file", path],
                       capture_output=True, timeout=seconds + 60)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"path": path, "error": str(error)}
    return {"path": path, "main_thread": main_thread_top(path)}


def alive(pid):
    try:
        os.kill(pid, 0)  # signal 0: only asks whether the PID this run started still exists
        return True
    except OSError:
        return False


def socket_paths(tag):
    return [os.path.expanduser(f"~/.local/state/cmux/cmux-debug-{tag}.sock"), f"/tmp/cmux-debug-{tag}.sock"]


# -- gate: perf-gate.py with a hang watchdog ----------------------------------------------------------------------

class GateRun:
    def __init__(self, app, out, tag, hang_ms, silent_s):
        self.app, self.out, self.tag, self.hang_ms, self.silent_s = app, out, tag, hang_ms, silent_s
        self.pid, self.last_line, self.last_text = None, time.monotonic(), ""
        self.hangs, self.crash, self.done = [], None, False
        self.started = time.time()

    def watchdog(self):
        probes = 0
        while not self.done:
            time.sleep(5)  # test script: the watchdog's own poll interval (it reads no app state unless perf-gate is silent)
            if self.done or not self.pid:
                continue
            if not alive(self.pid):
                if not self.done and self.crash is None:
                    time.sleep(3)  # the crash report lands a moment after the process ends
                    reports = crash_reports(self.started - 1)
                    self.crash = {"after_line": self.last_text[-200:],
                                  "report": reports[-1] if reports else None,
                                  "summary": crash_summary(reports[-1]) if reports else None}
                    note(f"gate: the app (pid {self.pid}) ended during perf-gate after `{self.last_text[-120:]}`")
                continue
            if time.monotonic() - self.last_line < self.silent_s or len(self.hangs) >= 4:
                continue
            probes += 1
            path = next((p for p in socket_paths(self.tag) if os.path.exists(p)), socket_paths(self.tag)[-1])
            t0 = time.monotonic()
            reply = rpc_at(path, "debug.windows", timeout=20)
            took = round(time.monotonic() - t0, 1)
            if isinstance(reply, dict) and reply.get("error"):
                note(f"gate: no answer from the app in {took} s after {int(time.monotonic() - self.last_line)} s of silence "
                     f"(`{self.last_text[-120:]}`): sampling")
                record = sample(self.pid, os.path.join(self.out, f"hang-{len(self.hangs) + 1}.txt"))
                record.update({"silent_s": int(time.monotonic() - self.last_line), "after_line": self.last_text[-200:],
                               "probe_error": str(reply.get("error"))[:200]})
                self.hangs.append(record)
                print("\n".join("  | " + l for l in (record.get("main_thread") or "").splitlines()[:30]), flush=True)
            self.last_line = time.monotonic()  # the next probe after another silent window

    def run(self):
        os.makedirs(self.out, exist_ok=True)
        cmd = [sys.executable, os.path.join(HERE, "perf-gate.py"), "--app", self.app, "--out", self.out,
               "--frames", "required", "--hang-ms", str(self.hang_ms)]
        thread = threading.Thread(target=self.watchdog, daemon=True)
        thread.start()
        log = open(os.path.join(self.out, "perf-gate.log"), "w")
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        for line in process.stdout:
            log.write(line)
            log.flush()
            self.last_line, self.last_text = time.monotonic(), line.strip()
            match = re.search(r"perf-gate: launched \S+ pid (\d+)", line)
            if match:
                self.pid = int(match.group(1))
            if line.startswith(("FAIL", "WARN", "==", "perf-gate:")) or "tab switch:" in line or "pane focus " in line \
                    or "activation-perf:" in line or "main-thread stall" in line:
                print("  gate| " + line.rstrip()[:400], flush=True)
        code = process.wait()
        self.done = True
        thread.join(10)
        report = {}
        try:
            report = json.load(open(os.path.join(self.out, "perf-gate.json")))
        except (OSError, ValueError) as error:
            report = {"error": f"no perf-gate.json: {error}"}
        return self.summarize(report, code)

    def summarize(self, report, code):
        phases = report.get("phases") or {}
        result = {"exit": code, "checks": len(report.get("checks") or []), "failed": report.get("failures"),
                  "warnings": report.get("warnings"), "seconds": report.get("seconds"),
                  "frames_probe": report.get("frames_probe"), "hangs_sampled": self.hangs, "crash": self.crash,
                  "error": report.get("error")}
        for name in ("tabs", "relaunch tabs"):
            phase = phases.get(name) or {}
            rows = phase.get("switches") or []
            result[name.replace(" ", "_")] = {
                "switches": len(rows), "late": sum(1 for r in rows if (r.get("late_vsyncs") or 0) > 0),
                "late_rows": [(r.get("apply_ms"), r.get("commit_ms"), r.get("late_vsyncs")) for r in rows if (r.get("late_vsyncs") or 0) > 0][:8],
                "apply_ms": stats([r.get("apply_ms") for r in rows]), "commit_ms": stats([r.get("commit_ms") for r in rows]),
                "refresh_ms": rows[0].get("refresh_ms") if rows else None,
                "stalls_ms": [round(h.get("duration_ms", 0), 1) for h in phase.get("hangs") or []][:12]}
        focus = (phases.get("pane_focus") or {}).get("modes") or {}
        result["pane_focus"] = {mode: {k: v.get(k) for k in ("apply_p50_ms", "apply_p95_ms", "commit_p50_ms", "commit_p95_ms", "late")}
                                for mode, v in focus.items()}
        activation = phases.get("activation") or {}
        result["activation"] = {k: {kk: (activation.get(k) or {}).get(kk) for kk in ("observers_ms", "resyncs", "hangs", "errors")}
                                for k in ("light", "heavy_app_only", "heavy")}
        result["activation"]["session"] = activation.get("session")
        return result


# -- stress: STRESS, then Cmd-Tab, Next Tab and Focus Next Pane ----------------------------------------------------

class StressRun:
    def __init__(self, app, out, hang_ms, stress_module, activation_module):
        self.app_path, self.out, self.hang_ms = app, out, hang_ms
        self.stress_module, self.activation = stress_module, activation_module
        self.hangs = []

    def rpc(self, method, params=None, timeout=120):
        reply = self.bench.rpc(method, params, timeout=timeout)
        if isinstance(reply, dict) and reply.get("unreachable") and self.bench.process and self.bench.process.poll() is None \
                and len(self.hangs) < 4:
            note(f"stress: {method} got no answer ({str(reply.get('error'))[:80]}): sampling the app")
            record = sample(self.bench.process.pid, os.path.join(self.out, f"hang-{len(self.hangs) + 1}.txt"))
            record["method"] = method
            self.hangs.append(record)
            print("\n".join("  | " + l for l in (record.get("main_thread") or "").splitlines()[:30]), flush=True)
        return reply

    def chromium(self):
        cef = self.rpc("debug.cef") or {}
        bad = [f"{k} {cef.get(k)}" for k in ("unavailable", "fallback") if cef.get(k)]
        if cef.get("default_engine") != "chromium":
            bad.append(f"default engine {cef.get('default_engine')}")
        if os.path.exists(os.path.expanduser("~/.config/cmux/web-dev.json")):
            bad.append("~/.config/cmux/web-dev.json")
        return {"chromium_ok": not bad, "bad": bad, "devtools": len(cef.get("devtools") or []),
                **{k: cef.get(k) for k in ("state", "default_engine", "ready_after_launch_s")}}

    def tab_switches(self, ops=40):
        app = self
        seen = []
        for _ in range(3):
            app.rpc("action.run", {"action": "nextSurface", "args": {}, "focus": True, "origin": "script"})
            topology = (app.rpc("snapshot.get") or {}).get("topology") or {}
            seen.append((topology.get("focus") or {}).get("tab"))
        time.sleep(1.0)  # test script: the selection moves end before the measured window
        app.rpc("debug.frames", {"action": "start"})
        app.rpc("debug.tab_switch", {"action": "start"})
        app.rpc("debug.hangs", {"clear": True})
        replies = []
        for _ in range(ops):
            t0 = time.monotonic()
            app.rpc("action.run", {"action": "nextSurface", "args": {}, "focus": True, "origin": "script"})
            replies.append(round((time.monotonic() - t0) * 1000, 1))
        time.sleep(0.5)  # test script: the last switch's commit lands before the stop
        own = app.rpc("debug.tab_switch", {"action": "stop"}) or {}
        frames = app.rpc("debug.frames", {"action": "stop"}) or {}
        hangs = (app.rpc("debug.hangs") or {}).get("records") or []
        rows = own.get("switches") or []
        late = [r for r in rows if (r.get("late_vsyncs") or 0) > 0]
        by_kind = {}
        for r in rows:
            by_kind.setdefault(r.get("kind") or "?", []).append(r.get("commit_ms"))
        return {"selection_moves": len(set(seen)), "switches": len(rows), "late": len(late),
                "late_rows": [(round(r.get("apply_ms", 0), 1), round(r.get("commit_ms", 0), 1), r.get("late_vsyncs"), r.get("kind"))
                              for r in late][:10],
                "apply_ms": stats([r.get("apply_ms") for r in rows]), "commit_ms": stats([r.get("commit_ms") for r in rows]),
                "commit_ms_by_kind": {k: stats(v) for k, v in by_kind.items()},
                "refresh_ms": rows[0].get("refresh_ms") if rows else None, "reply_ms": stats(replies),
                "frames": {k: frames.get(k) for k in ("frames", "missed", "refresh_ms", "max_interval_ms") if k in frames},
                "stalls_ms": [round(h.get("duration_ms", 0), 1) for h in hangs][:12],
                "stall_tops": [" < ".join(str(f)[:60] for f in (h.get("frames") or [])[:12]) for h in hangs[:3]]}

    def pane_focus(self, moves=40):
        app = self
        app.rpc("debug.frames", {"action": "start"})
        app.rpc("debug.pane_focus", {"action": "start"})
        replies = []
        for _ in range(moves):
            t0 = time.monotonic()
            app.rpc("action.run", {"action": "focusNextPane", "args": {}, "focus": True, "origin": "script"})
            replies.append(round((time.monotonic() - t0) * 1000, 1))
        time.sleep(0.5)  # test script: the last move's commit lands before the stop
        own = app.rpc("debug.pane_focus", {"action": "stop"}) or {}
        app.rpc("debug.frames", {"action": "stop"})
        rows = own.get("moves") or []
        return {"moves": len(rows), "late": sum(1 for r in rows if (r.get("late_vsyncs") or 0) > 0),
                "apply_ms": stats([r.get("apply_ms") for r in rows]), "commit_ms": stats([r.get("commit_ms") for r in rows]),
                "reply_ms": stats(replies)}

    def run(self):
        os.makedirs(self.out, exist_ok=True)
        result = {}
        self.bench = BenchApp(self.app_path, out=self.out, env={"CMUX_NEXT_HANG_THRESHOLD_MS": str(self.hang_ms)},
                              window=(80, 40, 1600, 1000), screen="0")
        try:
            self.bench.launch(timeout=240)
            topology = (self.rpc("snapshot.get") or {}).get("topology") or {}
            result["workspaces_at_launch"] = len(topology.get("workspaces") or [])
            builder = self.stress_module.Stress(self.rpc, log=lambda line: print("  " + line, flush=True), settle=3.0)
            try:
                summary = builder.build()
                result["shape_ok"] = True
            except self.stress_module.StressShapeError as error:
                summary = builder.summary()
                result.update(shape_ok=False, shape_error=str(error)[:600])
            note("STRESS-SESSION " + json.dumps(summary))
            result["stress_session"] = summary
            result["chromium"] = self.chromium()
            time.sleep(3.0)  # test script: the last pages' first loads end before the measured rows
            # No sampler during the cycles (perf-gate's activation runs none either): it would be in the timing.
            rows, hangs = self.activation.cycles(self, 20)
            result["activation"] = self.activation.summarize(rows, hangs)
            result["activation"]["observers_all_ms"] = [r.get("observers_ms") for r in rows]
            result["tab_switch"] = self.tab_switches()
            result["pane_focus"] = self.pane_focus()
        except LaunchError as error:
            result["launch_error"] = {"reason": error.reason, **{k: v for k, v in error.report.items() if k != "log_tail"}}
        except Exception as error:  # noqa: BLE001 - the run's failure is a field of the report; the next run still runs
            result["error"] = repr(error)[:600]
            if self.bench.process and self.bench.process.poll() is not None:
                reports = crash_reports((self.bench.launched_at or time.time()) - 1)
                result["crash"] = {"exit": self.bench.process.poll(), "report": reports[-1] if reports else None,
                                   "summary": crash_summary(reports[-1]) if reports else None}
        finally:
            result["hangs_sampled"] = self.hangs
            try:
                self.bench.stop()
            except Exception as error:  # noqa: BLE001
                result["stop_error"] = repr(error)[:300]
        return result


def base_app(sha, out):
    cache = os.environ.get("CI_SHARED_CACHE_DIR")
    if not cache:
        raise SystemExit("batch2-verify: no CI_SHARED_CACHE_DIR: the base app comes from the worker's app cache")
    folder = os.path.join(cache, "split-spring-apps", sha)
    found = glob.glob(os.path.join(folder, "cmux DEV *.app"))
    if not os.path.exists(os.path.join(folder, "ok")) or not found:
        raise SystemExit(f"batch2-verify: the base app of {sha} is not in {folder} (run a --build-only step of it on this worker first)")
    dest = os.path.join(out, "base-app")
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    subprocess.run(["ditto", found[0], os.path.join(dest, os.path.basename(found[0]))], check=True)
    os.utime(os.path.join(folder, "ok"))
    return os.path.join(dest, os.path.basename(found[0]))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True, help="the head app (the step's own build)")
    parser.add_argument("--tag")
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--base-sha", required=True, help="the base commit whose app is in the worker's app cache")
    parser.add_argument("--base-app", help="the base app (instead of the cache)")
    parser.add_argument("--order", default="BH", help="B and H in the run order (BH, HB, BHHB, ...)")
    parser.add_argument("--parts", default="gate,stress")
    parser.add_argument("--hang-ms", type=int, default=100)
    parser.add_argument("--silent-s", type=int, default=60)
    opts, _ = parser.parse_known_args()
    os.makedirs(opts.out, exist_ok=True)
    stress_module = load("perf_stress_session", "perf-stress-session.py")
    activation_module = load("activation_perf", "activation-perf.py")
    head_sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=HERE).stdout.strip()
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    report = {"host": os.uname().nodename, "macos": macos, "head_sha": head_sha, "base_sha": opts.base_sha,
              "order": opts.order, "hang_ms": opts.hang_ms, "runs": []}

    def write():
        with open(opts.json, "w") as f:
            json.dump(report, f, indent=1)

    try:
        apps = {"H": os.path.abspath(opts.app), "B": opts.base_app or base_app(opts.base_sha, opts.out)}
    except SystemExit as error:
        report["error"] = str(error)
        write()
        note(str(error))
        return 0
    tag = re.fullmatch(r"cmux DEV (.+)\.app", os.path.basename(apps["H"])).group(1)
    parts = opts.parts.split(",")
    for index, which in enumerate(opts.order):
        name = f"{index + 1}-{'base' if which == 'B' else 'head'}"
        run = {"run": name, "app": "base" if which == "B" else "head", "sha": opts.base_sha if which == "B" else head_sha}
        report["runs"].append(run)
        if "gate" in parts:
            note(f"{name}: perf-gate")
            start = time.monotonic()
            run["gate"] = GateRun(apps[which], os.path.join(opts.out, name, "gate"), tag, opts.hang_ms, opts.silent_s).run()
            run["gate"]["wall_s"] = round(time.monotonic() - start)
            note(f"{name}: gate " + json.dumps({k: run["gate"].get(k) for k in ("tabs", "activation")})[:1500])
            write()
        if "stress" in parts:
            note(f"{name}: STRESS")
            start = time.monotonic()
            run["stress"] = StressRun(apps[which], os.path.join(opts.out, name, "stress"), opts.hang_ms,
                                      stress_module, activation_module).run()
            run["stress"]["wall_s"] = round(time.monotonic() - start)
            note(f"{name}: stress " + json.dumps({k: run["stress"].get(k) for k in ("activation", "tab_switch", "pane_focus", "chromium", "error")})[:2000])
            write()
    write()
    note(f"report {opts.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
