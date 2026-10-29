#!/usr/bin/env python3
"""Is a bench build as fast as Release? Same actions, same host, interleaved runs.

A bench build (`scripts/reload.sh --config bench`: Release optimization with `-DCMUX_BENCH_HOOKS
-DCMUX_BLOCKING_CHECKS`, scripts/cmux-next/lib/bench-swift-defines.sh) keeps the debug.* control commands
the fleet benches drive and the main-thread blocking detector (record only, as a Nightly has it), so it
is not byte-for-byte the shipped Release app. This compares it with a Release build of the same commit on what both builds have:

  * the always-on action signposts (`action.perform`, `action.commit`; CmuxNextSignposts), for the
    same actions run through `action.run` (a normal socket method): --rounds of newTab + closeTab
    and splitRight + closeTab per launch;
  * the app process's CPU time over --idle seconds of idle after a settle (ps cputime).

Runs alternate (Release, bench, Release, bench, ...) --runs times each, each a fresh launch with a
scratch config, so drift on the host hits both builds alike. The verdict per row: the difference of
the two medians against the larger run-to-run spread (max - min of the per-run medians) of either
build; within noise when |diff| <= spread (or <= 0.05 ms for sub-0.1 ms rows).

Usage (a fleet GUI host, never a laptop):
  bench-config-parity.py --release APP --bench APP [--runs 3] [--rounds 20] [--idle 30] [--out DIR]
"""

import argparse
import json
import os
import plistlib
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class App:
    """A tagged app of any configuration, launched without activation, driven through its socket."""

    def __init__(self, bundle, out):
        self.bundle = os.path.abspath(bundle)
        with open(os.path.join(self.bundle, "Contents/Info.plist"), "rb") as f:
            info = plistlib.load(f)
        self.executable = os.path.join(self.bundle, "Contents/MacOS", info["CFBundleExecutable"])
        bundle_id = info.get("CFBundleIdentifier", "")
        self.tag = bundle_id.rsplit(".", 1)[-1]
        self.socket = f"/tmp/cmux-debug-{self.tag}.sock"
        self.out, self.process, self.scratch = out, None, None

    def rpc(self, method, params=None, timeout=60):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(self.socket)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            reply = json.loads(buf)
        except (OSError, ValueError) as error:
            return {"error": str(error)}
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}

    def launch(self):
        self.scratch = tempfile.mkdtemp(prefix=f"parity-{self.tag}-")
        config = os.path.join(self.scratch, "cmux.json")
        with open(config, "w") as f:
            json.dump({"appearance": {"backgroundOpacity": 1}}, f)
        ghostty = os.path.join(self.scratch, "ghostty")
        open(ghostty, "w").close()
        if os.path.exists(self.socket):
            os.unlink(self.socket)
        env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
               "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1440,900",
               "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
               "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(self.scratch, "chief"),
               "ACPMUX_AGENT_LAUNCH": "deny"}
        log = open(os.path.join(self.out, f"app-{self.tag}.log"), "a")
        self.process = subprocess.Popen([self.executable], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:  # the app's start: the socket answers, a workspace exists
            ping = self.rpc("system.ping", timeout=5) if os.path.exists(self.socket) else None
            if isinstance(ping, dict) and "error" not in ping or ping is True:
                break
            time.sleep(0.5)
        else:
            raise SystemExit(f"bench-config-parity: {self.tag}'s socket never answered at {self.socket}")

    def cpu_seconds(self):
        out = subprocess.run(["ps", "-o", "time=", "-p", str(self.process.pid)], capture_output=True, text=True).stdout.strip()
        if not out:
            return None
        parts = [float(p) for p in out.replace("-", ":").split(":")]
        seconds = 0.0
        for p in parts:
            seconds = seconds * 60 + p
        return seconds

    def stop(self):
        try:
            if self.process and self.process.poll() is None:
                self.rpc("app.quit", {}, timeout=10)
                try:
                    self.process.wait(30)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    try:
                        self.process.wait(15)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
        finally:
            if self.scratch:
                shutil.rmtree(self.scratch, ignore_errors=True)


def scenario(opts):
    """Runs the actions on --socket (internal: perf-signposts.py runs this while it streams)."""
    app = App.__new__(App)
    app.socket = opts.socket
    errors = []
    for _ in range(opts.rounds):
        for action in ("newTab", "closeTab", "splitRight", "closeTab"):
            reply = app.rpc("action.run", {"action": action})
            if isinstance(reply, dict) and reply.get("error"):
                errors.append({"action": action, "error": reply["error"]})
            time.sleep(0.05)  # spacing between presses, as a person types; not a wait for a condition
    with open(os.path.join(opts.out, "scenario.json"), "w") as f:
        json.dump({"errors": errors[:20], "error_count": len(errors)}, f)


def one_run(kind, bundle, opts, index, signposts):
    out = os.path.join(opts.out, f"{kind}-{index}")
    os.makedirs(out, exist_ok=True)
    app = App(bundle, out)
    app.launch()
    try:
        time.sleep(opts.settle)  # the measured settle after launch (launch work done), not a poll
        cpu0 = app.cpu_seconds()
        time.sleep(opts.idle)  # the idle window itself
        cpu1 = app.cpu_seconds()
        ndjson = os.path.join(out, "run.ndjson")
        command = [sys.executable, os.path.join(HERE, "perf-signposts.py"), "--pid", str(app.process.pid),
                   "--category", "action", "--save", ndjson, "--allow-loss", "--json", "--",
                   sys.executable, os.path.abspath(__file__), "--scenario", "--socket", app.socket,
                   "--out", out, "--rounds", str(opts.rounds)]
        subprocess.run(command, check=False, stdout=subprocess.DEVNULL)
        with open(ndjson) as f:
            parsed = signposts.parse(f.read().splitlines(), signposts.local_timebase())
        rows = {(r["name"], r["detail"]): r for r in signposts.summarize(parsed["intervals"])}
        with open(os.path.join(out, "scenario.json")) as f:
            scen = json.load(f)
        idle_pct = None if cpu0 is None or cpu1 is None else round(100 * (cpu1 - cpu0) / opts.idle, 3)
        result = {"kind": kind, "run": index, "idle_cpu_pct": idle_pct, "lost": parsed["lost"],
                  "action_errors": scen["error_count"], "rows": {}}
        for name in ("action.perform", "action.commit"):
            for detail in ("newTab", "closeTab", "splitRight", "*"):
                row = rows.get((name, detail))
                if row:
                    result["rows"][f"{name} {detail}"] = {"n": row["count"], "p50": row["p50_ms"], "p95": row["p95_ms"]}
        print("PARITY-RUN " + json.dumps(result), flush=True)
        return result
    finally:
        app.stop()


def verdict(runs):
    table, ok = [], True
    keys = sorted({k for r in runs for k in r["rows"]})
    metrics = [("idle_cpu_pct", None)] + [(k, "p50") for k in keys] + [(k, "p95") for k in keys]
    for key, stat in metrics:
        per = {}
        for kind in ("release", "bench"):
            values = [r[key] if stat is None else r["rows"].get(key, {}).get(stat) for r in runs if r["kind"] == kind]
            per[kind] = [v for v in values if v is not None]
        if not per["release"] or not per["bench"]:
            continue
        med = {k: statistics.median(v) for k, v in per.items()}
        spread = max(max(v) - min(v) for v in per.values())
        diff = med["bench"] - med["release"]
        floor = 0.05 if stat else 0.05
        within = abs(diff) <= max(spread, floor)
        ok &= within
        table.append({"metric": key if stat is None else f"{key} {stat}", "release": per["release"], "bench": per["bench"],
                      "median_release": round(med["release"], 3), "median_bench": round(med["bench"], 3),
                      "diff": round(diff, 3), "spread": round(spread, 3), "within_noise": within})
    return table, ok


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--release")
    parser.add_argument("--bench")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--settle", type=float, default=20)
    parser.add_argument("--idle", type=float, default=30)
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/bench-config-parity")
    parser.add_argument("--socket", help=argparse.SUPPRESS)
    parser.add_argument("--scenario", action="store_true", help=argparse.SUPPRESS)
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    if opts.scenario:
        return scenario(opts)
    if not (opts.release and opts.bench):
        parser.error("--release and --bench are required")
    signposts = load("perf_signposts", "perf-signposts.py")
    runs = []
    for index in range(opts.runs):
        for kind, bundle in (("release", opts.release), ("bench", opts.bench)):
            runs.append(one_run(kind, bundle, opts, index, signposts))
    table, ok = verdict(runs)
    report = {"host": os.uname().nodename, "runs": runs, "table": table, "within_noise": ok}
    with open(os.path.join(opts.out, "parity.json"), "w") as f:
        json.dump(report, f, indent=1)
    print(f"{'metric':42} {'release med':>11} {'bench med':>10} {'diff':>8} {'spread':>8}  verdict")
    for row in table:
        print(f"{row['metric']:42} {row['median_release']:11.3f} {row['median_bench']:10.3f} {row['diff']:8.3f} "
              f"{row['spread']:8.3f}  {'ok' if row['within_noise'] else 'OUTSIDE NOISE'}")
    print("BENCH-CONFIG-PARITY " + json.dumps({"within_noise": ok, "table": table}), flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
