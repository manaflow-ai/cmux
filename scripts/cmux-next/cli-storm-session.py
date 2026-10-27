#!/usr/bin/env python3
"""The CLI storm (bench_cli_storm.py) in a tagged app this script launches, light or STRESS, with the main-thread
scheduler's counters around it (plans/cmux-next/main-thread-budget.md: a storm on an idle main thread drains at the
4 ms a frame, and the budgeted display link stays up through the backlog).

Launches the tagged app through bench_launch.BenchApp (the bench environment: no activation, automation socket,
isolated Chief; a scratch cmux.json and Ghostty config; the tag's daemons ended at the stop), with --session stress
builds the STRESS session (perf-stress-session.py), then runs bench_cli_storm.py against its socket. Around the storm
(its warm-up storm included) it records:

  main_budget     debug.main_budget after a reset: per class tasks, yielded_to_input, idle_tasks, max_frame_ms, and
                  max_input_check_ms, max_render_pass_ms
  links_made      per frame scheduler, the display links made during the run (debug.wakeups links_made, after minus
                  before): the budgeted scheduler should make about one per burst, never one per frame
  storm           the bench's own report (throughput_rps, latency, stalls, frames, criteria; without its raw samples)
  results         {metric: result-v1 path, or "not recorded: why"}: the storm's raw samples as cmux-perf-result/v1
                  (storm_bench_results.cli_storm_series) in story cli-storm (light, engine none) or cli-storm-stress
                  (stress, engine chromium: STRESS holds Chromium pages)

  cli-storm-session.py --app APP --out DIR [--tag TAG] [--json DIR/report.json] [--session light|stress]
      [-- bench_cli_storm.py options, e.g. --requests 2000 --clients 32]

The session is --session, else $PERF_LAB_SESSION (the lab story runner), else light.

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=cli-storm [--arg=--session=stress] [--arg=--vdisplay=120]
The storm's own pass criteria do not fail this run (--no-fail): the numbers are the result.
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError, ROOT, load_by_path  # noqa: E402
import storm_bench_results as results  # noqa: E402

SESSION_ENV = "PERF_LAB_SESSION"  # set by the lab story runner


def parse(argv=None, environ=os.environ):
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--tag", help="the runner passes it; the bundle names its own tag")
    parser.add_argument("--out", required=True)
    parser.add_argument("--json")
    parser.add_argument("--session", choices=sorted(results.CLI_STORM_STORIES))
    opts, storm_args = parser.parse_known_args(argv)
    opts.session = opts.session or environ.get(SESSION_ENV) or "light"
    if opts.session not in results.CLI_STORM_STORIES:
        parser.error(f"${SESSION_ENV}={opts.session}: the session is one of {sorted(results.CLI_STORM_STORIES)}")
    opts.storm_args = [a for a in storm_args if a != "--"]
    opts.out = os.path.abspath(opts.out)
    return opts


def links(wakeups):
    return {s.get("name"): s.get("links_made") for s in (wakeups or {}).get("frame_schedulers") or []
            if isinstance(s, dict)}


def storm_report(path):
    """The storm's report and its result-v1 series; the report keeps every key but the raw samples."""
    try:
        with open(path) as f:
            storm = json.load(f)
    except (OSError, ValueError) as error:
        return {"error": str(error)}, []
    series = results.cli_storm_series(storm)
    storm.pop("samples", None)
    return storm, series


def main(argv=None):
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    story = results.CLI_STORM_STORIES[opts.session]
    app = BenchApp(opts.app, out=opts.out, config={"appearance": {"theme": "Catppuccin Mocha"}}, window=None,
                   screen="last", log_name="app.log", perf_session=opts.session)
    sha = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    report = {"bench": "cli-storm-session", "host": os.uname().nodename, "sha": sha, "tag": app.tag,
              "session": opts.session, "storm_args": opts.storm_args, "load_at_start": os.getloadavg()}
    code = 1
    try:
        app.launch()
        stress = load_by_path("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
        if opts.session == "stress":
            report["stress_session"] = stress.Stress(app.rpc).build()
            print("STRESS-SESSION " + json.dumps(report["stress_session"]), flush=True)
        app.rpc("debug.main_budget", {"reset": True})
        before = links(app.rpc("debug.wakeups"))
        label = f"cli-storm-{opts.session}"
        done = subprocess.run([sys.executable, os.path.join(HERE, "bench_cli_storm.py"), "--repo-root", ROOT,
                               "--sha", sha[:11], "--tag", app.tag, "--socket", app.socket, "--out", opts.out,
                               "--label", label, "--no-fail", *opts.storm_args])
        code = done.returncode
        report["main_budget"] = app.rpc("debug.main_budget", timeout=20)
        after = links(app.rpc("debug.wakeups", timeout=20))
        report["links_made"] = {name: (after.get(name) or 0) - (before.get(name) or 0) for name in after
                                if isinstance(after.get(name), int)}
        report["storm"], series = storm_report(os.path.join(opts.out, f"{sha[:11]}-{label}.json"))
        report["results"] = results.record_all(app, story, results.SESSION_ENGINES[opts.session], series)
        storm = report["storm"]
        budget = report["main_budget"] if isinstance(report["main_budget"], dict) else {}
        print(f"cli-storm {opts.session}: {storm.get('throughput_rps', 0):.1f} req/s over {storm.get('storm_seconds')} s; "
              f"max_frame_ms {max((c.get('max_frame_ms') or 0) for c in (budget.get('classes') or {}).values()) if budget.get('classes') else None} "
              f"max_input_check_ms {budget.get('max_input_check_ms')} max_render_pass_ms {budget.get('max_render_pass_ms')}; "
              f"links_made {report['links_made']}; result-v1 {len(series)} series in {story}", flush=True)
    except LaunchError as error:
        report["launch_error"] = str(error)
        raise
    finally:
        with open(opts.json or os.path.join(opts.out, "report.json"), "w") as f:
            json.dump(report, f, indent=1, default=str)
        app.stop()
    return code


if __name__ == "__main__":
    sys.exit(main())
