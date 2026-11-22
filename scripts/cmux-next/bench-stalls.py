#!/usr/bin/env python3
"""Main-thread stall bench for the paths the user touches (cmux-next).

Launches each tagged build with a clean environment (no activation, windows
on the last screen, a scratch cmux.json), then measures over the control
socket:

  launch       process start -> applicationDidFinishLaunching start/end,
               first window frame committed, first terminal surface created
               (debug.timings), and the longest main-thread stall during
               launch (debug.hangs)
  palette      first and second Command Palette open: open request to the
               panel's committed first frame (debug.timings) and the longest
               main-thread gap while it opens (debug.hangs max_gap_ms)
  terminal     each `ghostty_surface_new` (debug.timings), first and later
  tab          New Terminal Tab, first and later: the longest main-thread
               gap while the tab opens (debug.hangs max_gap_ms)

Stalls are sampled from 8 ms (CMUX_NEXT_HANG_THRESHOLD_MS), so each result
lists the top stacks of every stall over one 120 Hz frame with its CPU time
(cpu close to duration: app work; much lower: the thread waited or the
machine descheduled it). The *_stall_cpu_ms metrics (main-thread CPU time
of the worst stall) are the less load-sensitive numbers on a busy machine.

Several tags run interleaved (tag A run 1, tag B run 1, A run 2, ...), so
machine load affects before and after alike:

  scripts/cmux-next/bench-stalls.py --tag nxstlb --tag nxstl --runs 5 [--json out.json]
      [--daemon cold|warm] [--startup-only]

Startup: launch.key_echo_ms is the time to interactive (keys typed through
the app's key path, debug.key, appear on the focused terminal's screen);
launch.to_first_content_ms is the first terminal replay or output; the
daemon.* spans are the start path (login environment, server ensure,
handshake). --daemon warm primes a launch and quits only the app first.

Prints the load average, a per-run table, and the median, minimum and
spread per metric and tag. Refuses a tag whose app is already running (it
never touches an instance it did not start) and the default socket. Kills
only the app it launched and the processes under that tag's DerivedData.
"""
import argparse
import glob
import json
import os
import signal
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_cli_storm import Client  # noqa: E402

DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")


def app_binary(tag):
    tagged = f"{DERIVED}/cmux-{tag}/Build/Products/Debug/cmux DEV {tag}.app/Contents/MacOS/cmux DEV"
    if os.path.exists(tagged):
        return tagged
    matches = glob.glob(f"{DERIVED}/cmux-{tag}/Build/Products/Debug/cmux DEV*.app/Contents/MacOS/cmux DEV")
    if not matches:
        raise SystemExit(f"no tagged app for {tag} under {DERIVED}/cmux-{tag}")
    return matches[0]


def tag_pids(tag):
    """The tag's app, daemon and terminal hosts: processes started from its bundle."""
    out = subprocess.run(["pgrep", "-f", f"DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV"],
                         capture_output=True, text=True).stdout
    return [int(p) for p in out.split() if int(p) != os.getpid()]


def app_pids(tag):
    out = subprocess.run(["pgrep", "-f", f"DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV.*/Contents/MacOS/"],
                         capture_output=True, text=True).stdout
    return [int(p) for p in out.split() if int(p) != os.getpid()]


def stop_tag(tag, app_pid):
    """Quits the app this run started, then ends the tag's daemon and hosts."""
    if app_pid:
        try:
            os.kill(app_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and tag_pids(tag):
        for pid in tag_pids(tag):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        time.sleep(0.5)
    for pid in tag_pids(tag):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


class Run:
    def __init__(self, tag, threshold_ms, scratch):
        self.tag = tag
        self.socket = f"/tmp/cmux-debug-{tag}.sock"
        if os.path.realpath(self.socket) in {"/tmp/cmux-debug.sock", "/private/tmp/cmux-debug.sock"}:
            raise SystemExit("refusing the default socket")
        self.threshold_ms = threshold_ms
        self.scratch = scratch
        self.pid = None
        self.client = None

    def launch(self, warm_daemon=False):
        # A warm launch keeps the daemon this run primed; only the app must be gone.
        running = (lambda: app_pids(self.tag)) if warm_daemon else (lambda: tag_pids(self.tag))
        deadline = time.monotonic() + 15
        while running() and time.monotonic() < deadline:
            time.sleep(0.5)  # a previous run's daemon may still be exiting
        if running():
            listing = subprocess.run(["ps", "-o", "pid=,command=", "-p", ",".join(map(str, tag_pids(self.tag)))],
                                     capture_output=True, text=True).stdout
            raise SystemExit(f"tag {self.tag} already has processes running; quit them first "
                             f"(this bench only kills what it starts):\n{listing}")
        env = {
            "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_CONFIG_FILE": os.path.join(self.scratch, "cmux.json"),
            "CMUX_NEXT_HANG_THRESHOLD_MS": str(self.threshold_ms),
        }
        self.started = time.monotonic()
        process = subprocess.Popen([app_binary(self.tag)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        self.process = process
        self.pid = process.pid
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                self.client = Client(self.socket, timeout=10)
                if self.call("debug.timings").get("ok"):
                    return
            except (OSError, ConnectionError, ValueError):
                self.client = None
            time.sleep(0.1)
        raise SystemExit(f"{self.tag}: control socket did not answer within 60 s")

    def call(self, method, params=None):
        return self.client.call(method, params or {})

    def quit_app(self):
        """Quits only the app (the daemon keeps running: a warm next launch)."""
        if self.client:
            self.client.close()
            self.client = None
        os.kill(self.pid, signal.SIGTERM)
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(self.pid, signal.SIGKILL)
            self.process.wait()

    def key_echo_ms(self, timeout=20):
        """Launch to the moment a key typed into the focused terminal (debug.key
        through the app's key path) shows up on its screen, in milliseconds
        since the app process was spawned. Keys typed before the shell reads
        them wait in the PTY, so this is the time to interactive."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            launch = self.result("debug.timings").get("launch_ms_since_process_start", {})
            if "first_terminal_surface_created" in launch:
                break
            time.sleep(0.01)
        # Keys typed before the terminal attaches may be dropped: retype
        # (after clearing the line) until the echo shows.
        typed_at = 0.0
        while time.monotonic() < deadline:
            if time.monotonic() - typed_at > 1.0:
                if typed_at:
                    self.call("debug.key", {"key": "u", "modifiers": ["ctrl"]})
                for key in ("q", "z", "q"):
                    self.call("debug.key", {"key": key})
                typed_at = time.monotonic()
            text = (self.result("surface.read_text") or {}).get("text", "")
            if "qzq" in text:
                ms = (time.monotonic() - self.started) * 1000
                self.call("debug.key", {"key": "u", "modifiers": ["ctrl"]})
                return round(ms, 1)
            time.sleep(0.01)
        return None

    def result(self, method, params=None):
        return self.call(method, params).get("result") or {}

    def action(self, name, args=None):
        params = {"action": name}
        if args:
            params["args"] = args
        return self.call("action.run", params)

    def wait_launch_settled(self, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            launch = self.result("debug.timings").get("launch_ms_since_process_start", {})
            if "first_terminal_surface_created" in launch and "first_window_frame_committed" in launch:
                break
            time.sleep(0.1)
        time.sleep(2.0)  # let the first frames and deferred idle work run

    def stalls(self, hangs):
        out = []
        for record in hangs.get("records", []):
            frames = [f for f in record.get("frames", []) if "cmux" in f or "Ghostty" in f or "AppKit" in f][:6]
            out.append({"ms": round(record.get("duration_ms", 0), 1), "cpu_ms": round(record.get("cpu_ms", 0), 1),
                        "frames": frames or record.get("frames", [])[:6]})
        return sorted(out, key=lambda s: -s["ms"])

    def measure(self, label, trigger, settle):
        """Clears the counters, runs `trigger`, waits `settle` seconds, reads them."""
        self.result("debug.hangs", {"clear": True})
        self.result("debug.timings", {"clear": True})
        time.sleep(0.3)
        self.result("debug.hangs", {"clear": True})
        response = trigger()
        time.sleep(settle)
        hangs = self.result("debug.hangs")
        timings = self.result("debug.timings")
        return {
            "label": label,
            "ok": bool(response.get("ok", True)),
            "max_gap_ms": round(hangs.get("max_gap_ms", 0), 1),
            "frames_over_8_3ms": hangs.get("frames_over_8_3ms"),
            "palette_open_ms": [p["ms"] for p in timings.get("palette_opens", [])],
            "surfaces_ms": timings.get("terminal_surfaces_ms", []),
            "stalls": self.stalls(hangs),
        }


def one_run(tag, threshold_ms, tabs, daemon="cold", startup_only=False):
    scratch = tempfile.mkdtemp(prefix=f"bench-stalls-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as out:
        out.write("{}\n")
    run = Run(tag, threshold_ms, scratch)
    metrics = {}
    detail = []
    try:
        if daemon == "warm":
            # Priming launch: starts the daemon, then only the app quits.
            run.launch()
            run.wait_launch_settled()
            run.quit_app()
        run.launch(warm_daemon=daemon == "warm")
        metrics["launch.key_echo_ms"] = run.key_echo_ms()
        # CMUX_NEXT_NO_ACTIVATE=1: the launch must never become the active app.
        focus = run.result("debug.focus")
        metrics["launch.stole_focus"] = int(bool(focus.get("app_active")) or focus.get("key_window") is not None)
        run.wait_launch_settled()
        timings = run.result("debug.timings")
        launch = timings.get("launch_ms_since_process_start", {})
        hangs = run.result("debug.hangs")
        start = launch.get("did_finish_launching_start")
        end = launch.get("did_finish_launching_end")
        metrics["launch.to_did_finish_launching_ms"] = start
        metrics["launch.did_finish_launching_ms"] = round(end - start, 1) if start is not None and end is not None else None
        metrics["launch.to_first_window_frame_ms"] = launch.get("first_window_frame_committed")
        # launch-snapshot-v1: the last layout drawn before the daemon answers.
        metrics["launch.to_snapshot_applied_ms"] = launch.get("launch_snapshot_applied")
        metrics["launch.to_snapshot_layout_ms"] = launch.get("launch_snapshot_shown")
        metrics["launch.to_first_terminal_ms"] = launch.get("first_terminal_surface_created")
        metrics["launch.to_daemon_connected_ms"] = launch.get("daemon_connected")
        metrics["launch.to_snapshot_loaded_ms"] = launch.get("daemon_snapshot_loaded")
        metrics["launch.to_first_content_ms"] = launch.get("first_terminal_content")

        def span(a, b):
            return round(launch[b] - launch[a], 1) if a in launch and b in launch else None
        metrics["daemon.login_env_ms"] = span("daemon.login_env_start", "daemon.login_env_end")
        metrics["daemon.ensure_ms"] = span("daemon.ensure_start", "daemon.ensure_end")
        metrics["daemon.handshake_ms"] = span("daemon.connect_start", "daemon.handshake_end")
        metrics["launch.max_stall_ms"] = round(hangs.get("max_gap_ms", 0), 1)
        metrics["launch.max_stall_cpu_ms"] = max((s["cpu_ms"] for s in run.stalls(hangs)), default=0)
        surfaces = timings.get("terminal_surfaces_ms", [])
        metrics["launch.first_surface_ms"] = surfaces[0] if surfaces else None
        detail.append({"label": "launch", "stalls": run.stalls(hangs), "surfaces_ms": surfaces, "marks": launch})
        if startup_only:
            return finish(metrics), detail

        for index in (1, 2):
            result = run.measure(f"palette open {index}", lambda: run.action("app command-palette"), settle=1.0)
            metrics[f"palette.open{index}_frame_ms"] = result["palette_open_ms"][0] if result["palette_open_ms"] else None
            metrics[f"palette.open{index}_max_gap_ms"] = result["max_gap_ms"]
            metrics[f"palette.open{index}_stall_cpu_ms"] = max((s["cpu_ms"] for s in result["stalls"]), default=0)
            detail.append(result)
            run.action("app command-palette")  # toggles it closed
            time.sleep(0.5)

        for index in range(1, tabs + 1):
            result = run.measure(f"new tab {index}", lambda: run.action("tab new-terminal"), settle=2.0)
            key = "first" if index == 1 else "later"
            metrics.setdefault(f"tab.{key}_max_gap_ms", []).append(result["max_gap_ms"])
            metrics.setdefault(f"tab.{key}_stall_cpu_ms", []).append(max((s["cpu_ms"] for s in result["stalls"]), default=0))
            if result["surfaces_ms"]:
                metrics.setdefault(f"tab.{key}_surface_ms", []).append(result["surfaces_ms"][0])
            detail.append(result)
        for _ in range(tabs):
            run.action("tab close")
            time.sleep(0.3)
    finally:
        if run.client:
            run.client.close()
        stop_tag(tag, run.pid)
    return finish(metrics), detail


def finish(metrics):
    for key, value in list(metrics.items()):
        if isinstance(value, list):
            metrics[key] = round(statistics.median(value), 1) if value else None
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", action="append", required=True, help="tagged build (repeat to compare, e.g. before and after)")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--tabs", type=int, default=3, help="new tabs per run (the first is 'first', the rest 'later')")
    parser.add_argument("--hang-threshold-ms", type=int, default=8)
    parser.add_argument("--daemon", choices=["cold", "warm"], default="cold",
                        help="cold: the daemon starts with the app; warm: a priming launch leaves it running")
    parser.add_argument("--startup-only", action="store_true", help="measure launch only (no palette or tab steps)")
    parser.add_argument("--json")
    parser.add_argument("--details", action="store_true", help="print the stall stacks of each run")
    args = parser.parse_args()

    load_before = os.getloadavg()
    print(f"load average before: {load_before[0]:.1f} {load_before[1]:.1f} {load_before[2]:.1f}  (cpus: {os.cpu_count()})")
    results = {tag: [] for tag in args.tag}
    details = {tag: [] for tag in args.tag}
    for run_index in range(args.runs):
        for tag in args.tag:
            metrics, detail = one_run(tag, args.hang_threshold_ms, args.tabs, args.daemon, args.startup_only)
            metrics["load1"] = round(os.getloadavg()[0], 1)
            results[tag].append(metrics)
            details[tag].append(detail)
            print(f"run {run_index + 1} {tag}: " + ", ".join(f"{k}={v}" for k, v in metrics.items()), flush=True)
            if args.details:
                for part in detail:
                    for stall in part["stalls"][:3]:
                        print(f"    {part['label']}: {stall['ms']} ms (cpu {stall['cpu_ms']} ms) " + " <- ".join(stall["frames"][:4]))
    load_after = os.getloadavg()
    print(f"load average after: {load_after[0]:.1f} {load_after[1]:.1f} {load_after[2]:.1f}")

    keys = [k for k in results[args.tag[0]][0] if k != "load1"]
    header = f"{'metric (ms)':38}" + "".join(f"{tag + ' median [min-max]':>30}" for tag in args.tag)
    print(header)
    summary = {}
    for key in keys:
        row = f"{key:38}"
        for tag in args.tag:
            values = [r.get(key) for r in results[tag] if r.get(key) is not None]
            if values:
                med, low, high = statistics.median(values), min(values), max(values)
                summary.setdefault(tag, {})[key] = {"median": med, "min": low, "max": high}
                row += f"{f'{med:.1f} [{low:.1f}-{high:.1f}]':>30}"
            else:
                row += f"{'-':>30}"
        print(row)
    if args.json:
        with open(args.json, "w") as out:
            json.dump({"load_before": load_before, "load_after": load_after, "runs": results, "summary": summary,
                       "details": details}, out, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
