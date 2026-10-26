#!/usr/bin/env python3
"""Main-thread stall bench for the paths the user touches (cmux-next).

Launches each tagged build through bench_launch.BenchApp (the lab's bench
env: no activation, windows on the last screen, a scratch cmux.json), then
measures over the control socket:

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

Several builds run interleaved (A run 1, B run 1, A run 2, ...), so machine
load affects before and after alike:

  scripts/cmux-next/bench-stalls.py --app "A.app" --app "B.app" --runs 5 [--json out.json]
      [--daemon cold|warm] [--startup-only] [--out DIR] [--story stalls]
  scripts/cmux-next/bench-stalls.py --tag nxstlb --tag nxstl ...   (each tag's Debug build in DerivedData)

Startup: launch.key_echo_ms is the time to interactive (keys typed through
the app's key path, debug.key, appear on the focused terminal's screen);
launch.to_first_content_ms is the first terminal replay or output; the
daemon.* spans are the start path (login environment, server ensure,
handshake). --daemon warm primes a launch and quits only the app first.

Prints the load average, a per-run table, and the median (perf_stats.pct,
the lab's one percentile), p99, minimum and maximum per metric and build.
BenchApp refuses a build whose app is already running (it never touches an
instance it did not start); each run ends with BenchApp.stop (the app, then
the tag's daemons and terminals by bundle path, never a pattern kill).

With --story (stalls) every build also writes cmux-perf-result/v1 through its
BenchApp.record: `stalls.<metric>` (ms, the `_ms` suffix dropped) with every
run's value, and for the tab steps every tab's value (raw samples, not the
per-run median the table shows). launch.stole_focus is a check, not a
series. A series --story cannot record exits 1.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # bench_launch under `python3 -I` too
import bench_launch  # noqa: E402
from bench_launch import PERF_LAB, BenchApp, load_by_path  # noqa: E402
from bench_cli_storm import Client  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
STORY = "stalls"
CHECKS = ("launch.stole_focus",)  # pass/fail values, never a series


def bundle_of(tag):
    """A tag's Debug bundle in DerivedData (a by-hand run with --tag)."""
    tagged = f"{DERIVED}/cmux-{tag}/Build/Products/Debug/cmux DEV {tag}.app"
    if os.path.isdir(tagged):
        return tagged
    matches = glob.glob(f"{DERIVED}/cmux-{tag}/Build/Products/Debug/cmux DEV*.app")
    if not matches:
        raise SystemExit(f"no tagged app for {tag} under {DERIVED}/cmux-{tag}")
    return matches[0]


def bench_app(bundle, threshold_ms, out):
    """One BenchApp per build for all of its runs: one teardown and one perf_result.Run for every result."""
    return BenchApp(bundle, out=out, env={"CMUX_NEXT_HANG_THRESHOLD_MS": str(threshold_ms)}, config={},
                    window=None, screen="last")


class Run:
    def __init__(self, app):
        self.app = app
        self.tag = app.tag
        self.client = None
        self.started = None

    def launch(self, warm_daemon=False):
        """Starts the app (BenchApp: refuses a running app of the bundle) and connects. A warm launch keeps the
        tag's saved state, which the primed daemon still uses."""
        def spawned(_process):
            self.started = time.monotonic()  # launch.key_echo_ms counts from the spawn
            if self.app.teardown:
                # One teardown for every launch of this build, armed at this one's spawn: a launch that then fails
                # readiness still ends its daemons and terminal hosts.
                self.app.teardown.remember()

        self.app.fresh_state = not warm_daemon
        # The lab's host validation runs after the launch spans (one_run), never inside launch.key_echo.
        self.app.launch(timeout=60, ready="debug.timings", on_start=spawned, validate_host=False)
        self.client = Client(self.app.socket, timeout=10)

    def call(self, method, params=None):
        return self.client.call(method, params or {})

    def close(self):
        if self.client:
            self.client.close()
            self.client = None

    def quit_app(self):
        """Quits only the app (the daemon keeps running: a warm next launch): TERM, then KILL, of its own PID."""
        self.close()
        self.app.process.terminate()
        try:
            self.app.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.app.process.kill()
            self.app.process.wait()

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




def one_run(app, tabs, daemon="cold", startup_only=False):
    """One run of `app`: its metrics (the tab steps as lists, one value per tab) and the stall detail."""
    run = Run(app)
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
        app.validate_lab_host()  # once per build, while its app runs, after every launch metric is read
        if startup_only:
            return metrics, detail

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
        run.close()
        app.stop()
    return metrics, detail


def finish(metrics):
    """The run's table row: each list (one value per tab) as its median (perf_stats.pct), rounded to 0.1."""
    out = {}
    for key, value in metrics.items():
        if isinstance(value, list):
            value = round(perf_stats.pct(value, 0.50), 1) if value else None
        out[key] = value
    return out


def metric_name(key):
    """`launch.key_echo_ms` -> `stalls.launch.key_echo` (the unit is the result's)."""
    return f"{STORY}." + (key[:-3] if key.endswith("_ms") else key)


def series(raw_runs):
    """{result-v1 metric: samples} over every run: each run's value, and each tab's for the tab steps."""
    out = {}
    for metrics in raw_runs:
        for key, value in metrics.items():
            if key in CHECKS:
                continue
            values = value if isinstance(value, list) else [value]
            out.setdefault(metric_name(key), []).extend(v for v in values if isinstance(v, (int, float)))
    return {name: samples for name, samples in out.items() if samples}


def record_series(app, story, raw_runs):
    """{metric: result-v1 path or "not recorded: <reason>"} through the build's BenchApp."""
    written = {}
    for metric, samples in series(raw_runs).items():
        try:
            written[metric] = str(app.record(story, metric, "ms", samples, better="lower", engine="none"))
        except (bench_launch.RecordError, perf_result.ResultError) as error:
            written[metric] = f"not recorded: {error}"
    return written


def summarize(values):
    """{median, p99, min, max} of one metric's per-run values (perf_stats.pct)."""
    return {"median": perf_stats.pct(values, 0.50), "p99": perf_stats.pct(values, 0.99),
            "min": min(values), "max": max(values)}


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", action="append", help="a `cmux DEV <tag>.app` (repeat to compare, e.g. before and after)")
    parser.add_argument("--tag", action="append", help="without --app: a tag's Debug build in DerivedData (repeat to "
                                                       "compare); with --app, the story runner's (each bundle names its tag)")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--tabs", type=int, default=3, help="new tabs per run (the first is 'first', the rest 'later')")
    parser.add_argument("--hang-threshold-ms", type=int, default=8)
    parser.add_argument("--daemon", choices=["cold", "warm"], default="cold",
                        help="cold: the daemon starts with the app; warm: a priming launch leaves it running")
    parser.add_argument("--startup-only", action="store_true", help="measure launch only (no palette or tab steps)")
    parser.add_argument("--json")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS"),
                        help="BenchApp's folder (app logs, cmux-perf-result/v1); default a new temporary one")
    parser.add_argument("--story", help=f"write cmux-perf-result/v1 under this story ({STORY})")
    parser.add_argument("--details", action="store_true", help="print the stall stacks of each run")
    args = parser.parse_args(argv)
    if not (args.app or args.tag):
        parser.error("--app or --tag is required")
    return args


def main(argv=None):
    args = parse_args(argv)
    bundles = args.app or [bundle_of(tag) for tag in args.tag]
    apps = {}
    for bundle in bundles:
        app = bench_app(bundle, args.hang_threshold_ms, args.out)
        if app.tag in apps:
            raise SystemExit(f"bench-stalls: two builds are tag {app.tag}; their sockets and saved state would collide")
        apps[app.tag] = app
    tags = list(apps)

    load_before = os.getloadavg()
    print(f"load average before: {load_before[0]:.1f} {load_before[1]:.1f} {load_before[2]:.1f}  (cpus: {os.cpu_count()})")
    results = {tag: [] for tag in tags}
    raw = {tag: [] for tag in tags}
    details = {tag: [] for tag in tags}
    for run_index in range(args.runs):
        for tag in tags:
            measured, detail = one_run(apps[tag], args.tabs, args.daemon, args.startup_only)
            raw[tag].append(measured)
            metrics = finish(measured)
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

    keys = [k for k in results[tags[0]][0] if k != "load1"]
    header = f"{'metric (ms)':38}" + "".join(f"{tag + ' median [min-max]':>30}" for tag in tags)
    print(header)
    summary = {}
    for key in keys:
        row = f"{key:38}"
        for tag in tags:
            values = [r.get(key) for r in results[tag] if r.get(key) is not None]
            if values:
                stats = summary.setdefault(tag, {})[key] = summarize(values)
                med, low, high = stats["median"], stats["min"], stats["max"]
                row += f"{f'{med:.1f} [{low:.1f}-{high:.1f}]':>30}"
            else:
                row += f"{'-':>30}"
        print(row)
    status = 0
    recorded = {}
    if args.story:
        for tag in tags:
            recorded[tag] = record_series(apps[tag], args.story, raw[tag])
            for metric, where in recorded[tag].items():
                print(f"bench-stalls: {tag} result-v1 {metric}: {where}")
                if where.startswith("not recorded"):
                    status = 1
    if args.json:
        with open(args.json, "w") as out:
            json.dump({"load_before": load_before, "load_after": load_after, "runs": results, "summary": summary,
                       "details": details, "results": recorded}, out, indent=2)
    return status


if __name__ == "__main__":
    sys.exit(main())
