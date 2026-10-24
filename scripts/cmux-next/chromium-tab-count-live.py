#!/usr/bin/env python3
"""Many Chromium tabs, and the app still answers (release blocker 2026-10-23: the app died at about
82-100 Chromium tabs in activation-perf; launchd's soft open-file limit of 256 is the cause the
fix removes, OpenFileLimit).

Launches the tagged Debug app through bench_launch.BenchApp (a failed launch reports its cause; it
starts the app with launchd's soft limits, as Finder does: 256 open files), opens `--tabs` Chromium tabs on a local page over `--workspaces` workspaces, and after
every `--every` tabs reads the app's soft open-file limit (the one line the app logs at every
launch, OpenFileLimit.Report: "cmux: open-file limit A -> B", "... S (kept)", "... stays S (...)"
or "... unknown (...)"; only this launch's bytes of the log count, since BenchApp appends to one log
per tag), its open descriptors (lsof), its thread count, resident memory and Chromium helpers, and
checks the socket answers. Fails (exit 1) when the app stops answering, dies, logs a soft limit at
or below 256, or logs no limit line; `--no-limit-line` is for a build from before the line
(b8b74a07b95~1), where a missing line is reported as unknown, not failed.

Not a CI gate: run it yourself on a fleet GUI host, before and after a change:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/chromium-tab-count-live.py --tag "$NX_APP_TAG" --app "$NX_APP" --out "$NX_ARTIFACTS"
or build the app in the step (macOS 27 measure hosts):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --arg=--suite=chromium-tab-count --artifact artifacts/split-spring/report.json
"""
import argparse, glob, json, os, re, shutil, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", help="(accepted; the app's tag comes from its bundle name)")
parser.add_argument("--app", required=True)
parser.add_argument("--tabs", type=int, default=150)
parser.add_argument("--workspaces", type=int, default=15)
parser.add_argument("--every", type=int, default=10)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
parser.add_argument("--no-limit-line", action="store_true",
                    help="the build predates the launch limit line (b8b74a07b95~1): a missing line is unknown, not a failure")
opts, _unknown = parser.parse_known_args()
os.makedirs(opts.out, exist_ok=True)
PAGE = os.path.join(tempfile.mkdtemp(prefix="cef-count-"), "page.html")
open(PAGE, "w").write("<!doctype html><title>count</title><body>" + "".join(f"<p>line {i}</p>" for i in range(40)) + "</body>")
# BenchApp starts the app with launchd's soft limits, as Finder does (finder_limits: 256 open files).
bench = BenchApp(opts.app, out=opts.out)


def action(name, args=None, timeout=60):
    return bench.rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)


# The app's launch line (OpenFileLimit.Report.line): raised "A -> B [(...)]", kept "S (kept)",
# refused "stays S (...)", unreadable "unknown (...)".
LIMIT_LINE = re.compile(r"^cmux: open-file limit (?:\d+ -> (\d+)|(\d+) \(kept\)|stays (\d+)|unknown)")


# The log's size before this launch: BenchApp appends to app-<tag>.log, so an earlier run's line
# (another build with the same tag and --out) must not count for this one.
LOG_START = 0


def limit_line():
    """This launch's limit line match, or None when this launch logged none."""
    found = None
    try:
        with open(bench.log_path, "rb") as log:
            log.seek(LOG_START)
            for line in log.read().decode(errors="replace").splitlines():
                found = LIMIT_LINE.match(line) or found
    except OSError:
        pass
    return found


def open_files(pid):
    """{soft, open} of the app: its soft limit (`ulimit` of another process is not readable from outside, so the
    app's own launch line names it; None when this launch logged none or says unknown) and its open descriptors (lsof)."""
    match = limit_line()
    found = next((group for group in match.groups() if group), None) if match else None
    soft = int(found) if found else None
    listed = subprocess.run(["lsof", "-n", "-P", "-p", str(pid)], capture_output=True, text=True).stdout.splitlines()
    numbered = [l for l in listed[1:] if len(l.split()) > 3 and l.split()[3][:1].isdigit()]
    return {"soft": soft, "open": len(numbered)}


def process_stats(pid):
    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
    threads = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout.count("\n") - 1
    helpers = sum(1 for line in subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout.splitlines()
                  if line.startswith(bench.app + "/") and "Helper" in line)
    return {"rss_mb": round(int(rss[0]) / 1024, 1) if rss else None, "threads": threads, "helpers": helpers}


def copy_crash_reports(since):
    copied = []
    for path in glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*")):
        name = os.path.basename(path)
        if os.path.getmtime(path) >= since and ("cmux" in name or "Chromium" in name):
            shutil.copy(path, opts.out)
            copied.append(name)
    return copied


def main():
    global LOG_START
    started = time.time()
    LOG_START = os.path.getsize(bench.log_path) if os.path.exists(bench.log_path) else 0
    bench.launch()
    rows, failure, opened = [], None, 0
    per_workspace = max(1, opts.tabs // max(1, opts.workspaces))
    while opened < opts.tabs and failure is None:
        if opened % per_workspace == 0:
            action("newTab", {"name": f"count-{opened // per_workspace}"})
            time.sleep(0.5)  # test harness: the workspace shows
        reply = action("openBrowser.chromium", {"url": f"file://{PAGE}?{opened}"})
        opened += 1
        if isinstance(reply, dict) and reply.get("error"):
            print(f"tab {opened}: {json.dumps(reply)[:200]}", flush=True)
        if opened % opts.every == 0 or opened == opts.tabs:
            time.sleep(1.5)  # test harness: the last pages load
            cef = bench.rpc("debug.cef", timeout=30) or {}
            alive = bench.process.poll() is None and "error" not in cef
            row = {"tabs": opened, "alive": alive, "open_files": open_files(bench.process.pid), "footprint_mb": cef.get("footprint_mb"),
                   **process_stats(bench.process.pid)}
            rows.append(row)
            print("COUNT " + json.dumps(row), flush=True)
            if not alive:
                failure = f"the app stopped answering at {opened} tabs ({cef.get('error') or 'exited ' + str(bench.process.poll())})"
    soft = ((rows[-1] if rows else {}).get("open_files") or {}).get("soft")
    if failure is None and soft is not None and soft <= 256:
        failure = f"the app's soft open-file limit is {soft}"
    if failure is None and limit_line() is None and not opts.no_limit_line:
        failure = "the app logged no open-file limit line at launch (its main no longer calls OpenFileLimit.raise)"
    crashes = copy_crash_reports(started) if failure else []
    result = {"host": os.uname().nodename, "tabs": opts.tabs, "rows": rows, "failure": failure, "crash_reports": crashes,
              "soft_limit": soft if soft is not None else "unknown", "log": bench.log_path}
    print("RESULT " + json.dumps({k: v for k, v in result.items() if k != "rows"}), flush=True)
    if opts.json:
        open(opts.json, "w").write(json.dumps(result, indent=1))
    return failure is None


ok = False
try:
    ok = main()
finally:
    bench.stop()
sys.exit(0 if ok else 1)
