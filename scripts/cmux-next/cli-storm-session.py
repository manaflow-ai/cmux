#!/usr/bin/env python3
"""The CLI storm (bench_cli_storm.py) in a tagged app this script launches, light or STRESS, with the main-thread
scheduler's counters around it (plans/cmux-next/main-thread-budget.md: a storm on an idle main thread drains at the
4 ms a frame, and the budgeted display link stays up through the backlog).

Launches the tagged app (no activation, automation socket, a scratch cmux.json and Ghostty config, an isolated Chief
home), with --session stress builds the STRESS session (perf-stress-session.py), then runs bench_cli_storm.py against
its socket. Around the storm (its warm-up storm included) it records:

  main_budget     debug.main_budget after a reset: per class tasks, yielded_to_input, idle_tasks, max_frame_ms, and
                  max_input_check_ms, max_render_pass_ms
  links_made      per frame scheduler, the display links made during the run (debug.wakeups links_made, after minus
                  before): the budgeted scheduler should make about one per burst, never one per frame
  storm           the bench's own report (throughput_rps, latency, stalls, frames, criteria)

  cli-storm-session.py --app APP --tag TAG --out DIR [--json DIR/report.json] [--session light|stress]
      [-- bench_cli_storm.py options, e.g. --requests 2000 --clients 32]

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=cli-storm [--arg=--session=stress] [--arg=--vdisplay=120]
The storm's own pass criteria do not fail this run (--no-fail): the numbers are the result.
"""
import argparse, glob, json, os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--session", choices=["light", "stress"], default="light")
opts, storm_args = parser.parse_known_args()
storm_args = [a for a in storm_args if a != "--"]
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"cli-storm-{opts.tag}-")


def load(name, file):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stress = load("perf_stress_session", "perf-stress-session.py")
rpc = stress.socket_rpc(SOCKET)


def links(wakeups):
    return {s.get("name"): s.get("links_made") for s in (wakeups or {}).get("frame_schedulers") or []
            if isinstance(s, dict)}


def main():
    config = os.path.join(SCRATCH, "cmux.json")
    ghostty = os.path.join(SCRATCH, "ghostty")
    with open(config, "w") as f:
        json.dump({"appearance": {"theme": "Catppuccin Mocha"}}, f)
    open(ghostty, "w").write("")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
           "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief")}
    binary = next((p for p in sorted(glob.glob(os.path.join(opts.app, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
    log = open(os.path.join(OUT, "app.log"), "a")
    app = subprocess.Popen([binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    sha = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    report = {"bench": "cli-storm-session", "host": os.uname().nodename, "sha": sha, "tag": opts.tag,
              "session": opts.session, "storm_args": storm_args, "load_at_start": os.getloadavg()}
    code = 1
    try:
        if not stress.wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 180):
            sys.exit(f"the tagged app did not come up (exit={app.poll()})")
        time.sleep(3)  # test script: the first window settles before the storm
        if opts.session == "stress":
            report["stress_session"] = stress.Stress(rpc).build()
            print("STRESS-SESSION " + json.dumps(report["stress_session"]), flush=True)
        rpc("debug.main_budget", {"reset": True})
        before = links(rpc("debug.wakeups"))
        label = f"cli-storm-{opts.session}"
        done = subprocess.run([sys.executable, os.path.join(HERE, "bench_cli_storm.py"), "--repo-root", ROOT, "--sha", sha[:11],
                               "--tag", opts.tag, "--socket", SOCKET, "--out", OUT, "--label", label, "--no-fail", *storm_args])
        code = done.returncode
        report["main_budget"] = rpc("debug.main_budget", timeout=20)
        after = links(rpc("debug.wakeups", timeout=20))
        report["links_made"] = {name: (after.get(name) or 0) - (before.get(name) or 0) for name in after
                                if isinstance(after.get(name), int)}
        try:
            with open(os.path.join(OUT, f"{sha[:11]}-{label}.json")) as f:
                report["storm"] = json.load(f)
        except (OSError, ValueError) as error:
            report["storm"] = {"error": str(error)}
        storm = report["storm"]
        budget = report["main_budget"] if isinstance(report["main_budget"], dict) else {}
        print(f"cli-storm {opts.session}: {storm.get('throughput_rps', 0):.1f} req/s over {storm.get('storm_seconds')} s; "
              f"max_frame_ms {max((c.get('max_frame_ms') or 0) for c in (budget.get('classes') or {}).values()) if budget.get('classes') else None} "
              f"max_input_check_ms {budget.get('max_input_check_ms')} max_render_pass_ms {budget.get('max_render_pass_ms')}; "
              f"links_made {report['links_made']}", flush=True)
    finally:
        with open(opts.json or os.path.join(OUT, "report.json"), "w") as f:
            json.dump(report, f, indent=1, default=str)
        rpc("action.run", {"action": "quitEndSessions", "origin": "script"})
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            app.terminate()  # the app this script launched, by its handle
    sys.exit(code)


main()
