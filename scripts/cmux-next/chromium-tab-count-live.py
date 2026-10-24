#!/usr/bin/env python3
"""Many Chromium tabs, and the app still answers (release blocker 2026-10-23: the app died at about
82-100 Chromium tabs in activation-perf; launchd's soft open-file limit of 256 is the cause the
fix removes, OpenFileLimit).

Launches the tagged Debug app through bench_launch.BenchApp (a failed launch reports its cause; it
starts the app with launchd's soft limits, as Finder does: 256 open files), opens `--tabs` Chromium tabs on a local page over `--workspaces` workspaces, and after
every `--every` tabs reads the app's soft open-file limit (its launch log line), its open
descriptors (lsof), its thread count, resident memory and Chromium helpers, and checks the socket answers. Fails
(exit 1) when the app stops answering, dies, or reports a soft limit at or below 256.

For the cause of a death (the cmux-ci deaths near 82-100 tabs at the step's nofile 65536): `--limits inherit` keeps
the step's limits; older crash reports are set aside first (moved into a dated subfolder, never deleted:
osanalyticshelper writes no report once 25 of a type are there) and the host's report cap is recorded; a sampler
records every `--sample-s` seconds what PL-verify's batch2-verify crash part records (process_sample.resources: fds
by type, threads, children, RSS, Mach ports, memory pressure, vm_stat, CEF helpers) plus the GUI session (console
user, gui/UID domain, WindowServer). A death records its time after launch, exit code and signal, the last samples,
this launch's crash reports and the window's system log (memory pressure, jetsam, open files, bootstrap "No such
process", loginwindow, WindowServer and launchd session lines).

Not a CI gate: run it yourself on a fleet GUI host, before and after a change:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/chromium-tab-count-live.py --tag "$NX_APP_TAG" --app "$NX_APP" --out "$NX_ARTIFACTS"
or build the app in the step (macOS 27 measure hosts):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --arg=--suite=chromium-tab-count --artifact artifacts/split-spring/report.json
"""
import argparse, glob, json, os, re, shutil, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp  # noqa: E402
from bench_launch import account_home  # noqa: E402
from process_sample import exit_signal, regular_files, report_cap, report_dirs, resources  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", help="(accepted; the app's tag comes from its bundle name)")
parser.add_argument("--app", required=True)
parser.add_argument("--tabs", type=int, default=150)
parser.add_argument("--workspaces", type=int, default=15)
parser.add_argument("--every", type=int, default=10)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
parser.add_argument("--limits", default="finder", help="finder: launchd's soft limits (256 open files); inherit: this step's")
parser.add_argument("--sample-s", type=float, default=5, help="seconds between resource samples (0: none)")
opts, _unknown = parser.parse_known_args()
if opts.limits == "inherit":
    os.environ["BENCH_LAUNCH_LIMITS"] = "inherit"  # bench_launch.finder_limits keeps this process's limits
os.makedirs(opts.out, exist_ok=True)
PAGE = os.path.join(tempfile.mkdtemp(prefix="cef-count-"), "page.html")
open(PAGE, "w").write("<!doctype html><title>count</title><body>" + "".join(f"<p>line {i}</p>" for i in range(40)) + "</body>")
# BenchApp starts the app with launchd's soft limits, as Finder does (finder_limits: 256 open files).
bench = BenchApp(opts.app, out=opts.out)


def action(name, args=None, timeout=60):
    return bench.rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)


def open_files(pid):
    """{soft, open} of the app: its soft limit (launchctl's view of a process: `ulimit` is not readable from
    outside, so the app's own log line "cmux: open-file limit A -> B" names it) and its open descriptors (lsof)."""
    soft = None
    try:
        for line in open(bench.log_path, errors="replace"):
            if line.startswith("cmux: open-file limit "):
                soft = int(line.rsplit(" ", 1)[1])
    except (OSError, ValueError):
        pass
    listed = subprocess.run(["lsof", "-n", "-P", "-p", str(pid)], capture_output=True, text=True).stdout.splitlines()
    numbered = [l for l in listed[1:] if len(l.split()) > 3 and l.split()[3][:1].isdigit()]
    return {"soft": soft if soft is not None else 256, "open": len(numbered)}


def process_stats(pid):
    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
    threads = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout.count("\n") - 1
    helpers = sum(1 for line in subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout.splitlines()
                  if line.startswith(bench.app + "/") and "Helper" in line)
    return {"rss_mb": round(int(rss[0]) / 1024, 1) if rss else None, "threads": threads, "helpers": helpers}


def set_aside_old_reports():
    """Moves (never deletes) this account's older crash reports into a dated subfolder: osanalyticshelper writes no
    new report once 25 of a type are there ("the limit of 25 logs has been reached")."""
    # The account's own folder, not the step's HOME: ReportCrash writes and counts reports there
    # (cmux10s, 2026-10-24: 51 reports in /Users/cmux/Library/Logs/DiagnosticReports, 0 moved from the step's HOME).
    moved = 0
    for folder in dict.fromkeys([os.path.join(account_home(), "Library/Logs/DiagnosticReports"), report_dirs()[0]]):
        aside = os.path.join(folder, "set-aside-" + time.strftime("%Y%m%d-%H%M%S"))
        for path in glob.glob(os.path.join(folder, "*.ips")):
            try:
                os.makedirs(aside, exist_ok=True)
                shutil.move(path, aside)
                moved += 1
            except OSError:
                pass
    return moved


def log_tails(lines=80):
    """The app's stdout/stderr (a Swift fatal error prints its message there) and Chromium's own logs
    (a CHECK prints [FATAL:...]): the death's cause when the crash reporter keeps no report."""
    tails = {}
    try:
        tails[bench.log_path] = open(bench.log_path, errors="replace").read().splitlines()[-lines:]
    except (OSError, TypeError):
        pass
    for home in dict.fromkeys([os.environ.get("HOME", ""), account_home()]):
        for path in glob.glob(os.path.join(home, "Library/Application Support/*split*spring*/Chromium/*.log")) + \
                glob.glob(os.path.join(home, "Library/Application Support/*/Chromium/cef*.log")):
            try:
                if os.path.getmtime(path) >= time.time() - 3600:
                    tails[path] = open(path, errors="replace").read().splitlines()[-lines:]
            except OSError:
                pass
    fatal = [l for t in tails.values() for l in t if "FATAL" in l or "Fatal error" in l or "precondition" in l.lower() or "Check failed" in l]
    return {"files": {k: [l[:300] for l in v] for k, v in tails.items()}, "fatal": [l[:400] for l in fatal[-20:]]}


def system_log(since, until):
    """The window's memory pressure, jetsam, open-file, bootstrap ("No such process"), GUI session (loginwindow,
    WindowServer, launchd gui domain) and cmux launchd lines."""
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since))
    end = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(until))
    predicate = ('eventMessage CONTAINS[c] "memorystatus" OR eventMessage CONTAINS[c] "jetsam" OR '
                 'eventMessage CONTAINS[c] "Too many open files" OR eventMessage CONTAINS "No such process" OR '
                 'process == "loginwindow" OR (process == "WindowServer" AND messageType >= 16) OR '
                 '(process == "launchd" AND (eventMessage CONTAINS[c] "cmux" OR eventMessage CONTAINS "gui/")) OR '
                 '(process == "kernel" AND (eventMessage CONTAINS[c] "port" OR eventMessage CONTAINS "EXC_RESOURCE")) OR '
                 f'(processID == {bench.process.pid} AND messageType >= 16)')
    try:
        out = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--start", start, "--end", end, "--predicate", predicate],
                             capture_output=True, text=True, timeout=300).stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": repr(error)[:200]}
    path = os.path.join(opts.out, "system-log.txt")
    open(path, "w").write(out)
    lines = out.splitlines()
    return {"lines": len(lines), "path": path, "tail": [l[:300] for l in lines[-40:]]}


def step_context():
    """The CI step's own deadline fields, when its runner exports them (names only matched, no secrets read)."""
    return {k: v for k, v in os.environ.items() if re.match(r"^(CMUX_CI|CI)_\w*(TIMEOUT|DEADLINE|UNTIL|STEP|JOB)\w*$", k)}


class Sampler:
    """Samples the app every `every` seconds on its own thread until stopped or the app is gone."""

    def __init__(self, pid, every):
        self.pid, self.every, self.rows, self.stop = pid, every, [], threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        # A fixed sample interval is the bench's intended cadence (PL-verify's 5 s), not a wait for a state.
        while not self.stop.wait(self.every):
            if bench.process.poll() is not None:
                return
            row = resources(self.pid)
            self.rows.append(row)
            print("SAMPLE " + json.dumps(row), flush=True)

    def __enter__(self):
        if self.every > 0:
            self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        if self.thread.is_alive():
            self.thread.join(60)


def app_specific_vm(pid):
    """The app's VM regions by tag from `vmmap -summary` (PartitionAlloc is App-Specific Tag 14, VM tag 253):
    the deaths at 143 tabs (2026-10-24, cmux7s and cmux10s) trapped in Chromium's allocator with ~41 GB and
    ~39,000 regions of that tag, while memory was free."""
    try:
        out = subprocess.run(["/usr/bin/vmmap", "-summary", str(pid)], capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": repr(error)[:120]}
    rows = {}
    for line in out.splitlines():
        if line.startswith("App-Specific Tag") or line.startswith("Guard ") or line.startswith("TOTAL") or line.startswith("Malloc "):
            name = line[:33].strip()
            fields = line[33:].split()
            rows[name] = fields[:2]
    return rows


def main():
    started = time.time()
    cap = report_cap()
    moved = set_aside_old_reports()
    print(f"crash reports set aside: {moved}; report cap before: {json.dumps(cap)}", flush=True)
    bench.launch()
    launched = time.time()
    pid = bench.process.pid
    files_before_tabs = regular_files(pid)
    print("REGULAR-FILES-BEFORE-TABS " + json.dumps(files_before_tabs), flush=True)
    rows, failure, opened, death = [], None, 0, None
    per_workspace = max(1, opts.tabs // max(1, opts.workspaces))
    with Sampler(pid, opts.sample_s) as sampler:
        while opened < opts.tabs and failure is None:
            if opened % per_workspace == 0:
                action("newTab", {"name": f"count-{opened // per_workspace}"})
                time.sleep(0.5)  # test harness: the workspace shows
            reply = action("openBrowser.chromium", {"url": f"file://{PAGE}?{opened}"})
            opened += 1
            if isinstance(reply, dict) and reply.get("error"):
                print(f"tab {opened}: {json.dumps(reply)[:200]}", flush=True)
            if opened % opts.every == 0 or opened == opts.tabs or bench.process.poll() is not None:
                time.sleep(1.5)  # test harness: the last pages load
                cef = bench.rpc("debug.cef", timeout=30) or {}
                alive = bench.process.poll() is None and "error" not in cef
                row = {"tabs": opened, "alive": alive, "open_files": open_files(pid), "footprint_mb": cef.get("footprint_mb"),
                       **process_stats(pid), "vm": app_specific_vm(pid) if alive else None}
                rows.append(row)
                print("COUNT " + json.dumps(row), flush=True)
                if not alive:
                    code = bench.process.poll()
                    death = {"tabs": opened, "seconds_after_launch": round(time.time() - launched, 1), "epoch": round(time.time(), 1),
                             "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "exit": code, "signal": exit_signal(code),
                             "rpc_error": cef.get("error")}
                    failure = (f"the app stopped answering at {opened} tabs, {death['seconds_after_launch']} s after launch "
                               f"({cef.get('error') or 'exited ' + str(code)})")
    soft = ((rows[-1] if rows else {}).get("open_files") or {}).get("soft")
    if failure is None and (soft is None or soft <= 256):
        failure = f"the app's soft open-file limit is {soft}"
    crashes = []
    if death:
        reports = bench.wait_for_crash_report(death["exit"])
        for path in reports:
            shutil.copy(path, opts.out)
            crashes.append(os.path.basename(path))
    result = {"host": os.uname().nodename, "tabs": opts.tabs, "rows": rows, "failure": failure, "death": death,
              "crash_reports": crashes, "regular_files_before_tabs": files_before_tabs, "crash_report_wait": getattr(bench, "crash_report_wait", None),
              "report_cap_before": cap, "reports_set_aside": moved, "report_cap_after": report_cap("1h") if death else None,
              "samples": sampler.rows, "log_tails": log_tails() if death else None, "last_samples": sampler.rows[-3:], "log": bench.log_path,
              "system_log": system_log(started, time.time()) if death else None, "limits": opts.limits,
              "launch_limits": getattr(bench, "limits", None), "step": step_context(),
              "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)), "seconds": round(time.time() - started)}
    if result["log_tails"]:
        print("FATAL-LINES " + json.dumps(result["log_tails"]["fatal"]), flush=True)
        for path, tail in result["log_tails"]["files"].items():
            print(f"LOG-TAIL {path}\n" + "\n".join(tail[-40:]), flush=True)
    print("RESULT " + json.dumps({k: v for k, v in result.items() if k not in ("rows", "samples", "log_tails")}), flush=True)
    if opts.json:
        open(opts.json, "w").write(json.dumps(result, indent=1))
    return failure is None


ok = False
try:
    ok = main()
finally:
    bench.stop()
sys.exit(0 if ok else 1)
