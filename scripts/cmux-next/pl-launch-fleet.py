#!/usr/bin/env python3
"""Scratch fleet harness for #17587 testing (pl-launch; not for landing).

Runs through the allowlisted fleet entry scripts/measure/split-spring.sh with --suite=pl-launch:
  LIGHT : bench-startup.py --profile realistic --mode <modes> --launch-guard --hangs 50 --budget first_window_frame_committed=150
  STRESS: perf-stress-session.Stress(rpc).build() in the tagged app, a normal quit (keep sessions), then
          bench-startup.py --mode warm (state kept) and --mode kept, both with --launch-guard.
Writes one report.json (host, display, every log and json) at --json.
"""
import argparse, importlib.util, json, os, platform, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, file):
    sys.path.insert(0, HERE)
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout
    except Exception as error:  # report, never fail the run on a host probe
        return f"error: {error}"


def bench(app, out, name, args, report):
    log_path, json_path = os.path.join(out, f"{name}.log"), os.path.join(out, f"{name}.json")
    cmd = [sys.executable, "-u", os.path.join(HERE, "bench-startup.py"), "--app", app, *args, "--json", json_path]
    print(f"pl-launch: {name}: {' '.join(cmd)}", flush=True)
    with open(log_path, "w") as log:
        code = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT)
    text = open(log_path).read()
    print(text, flush=True)
    print(f"pl-launch: {name} exit {code}", flush=True)
    entry = {"cmd": cmd[2:], "exit": code, "log": text}
    if os.path.exists(json_path):
        try:
            entry["json"] = json.load(open(json_path))
        except ValueError:
            entry["json_error"] = True
    report["runs"][name] = entry


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--tag"); p.add_argument("--app", required=True); p.add_argument("--out", required=True)
    p.add_argument("--json", required=True)
    p.add_argument("--pl-runs", type=int, default=5)
    p.add_argument("--pl-modes", default="warm,kept")
    p.add_argument("--pl-stress", type=int, default=1)
    p.add_argument("--pl-light", type=int, default=1)
    o, _ = p.parse_known_args([a for a in sys.argv[1:] if a != "--suite=pl-launch"])
    os.makedirs(o.out, exist_ok=True)
    app = os.path.abspath(o.app)
    tag = os.path.basename(app.rstrip("/"))[len("cmux DEV "):-len(".app")]
    bs = load("bench_startup", "bench-startup.py")
    report = {"host": {"hostname": platform.node(), "sw_vers": sh(["sw_vers"]), "model": sh(["sysctl", "-n", "hw.model"]).strip(),
                       "cpu": sh(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(), "uptime": sh(["uptime"]).strip(),
                       "head": sh(["git", "-C", HERE, "rev-parse", "HEAD"]).strip(), "app": app, "tag": tag},
              "runs": {}}
    try:
        report["host"]["displays"] = json.loads(sh(["system_profiler", "-json", "SPDisplaysDataType"]) or "{}")
    except ValueError:
        report["host"]["displays"] = None
    print("pl-launch: host " + json.dumps({k: v for k, v in report["host"].items() if k != "displays"}), flush=True)
    print("pl-launch: displays " + json.dumps(report["host"]["displays"])[:1500], flush=True)
    common = ["--runs", str(o.pl_runs), "--launch-guard", "--hangs", "50", "--budget", "first_window_frame_committed=150"]
    modes = [x for m in o.pl_modes.split(",") if m for x in ("--mode", m)]
    teardown = None
    try:
        teardown = load("tag_teardown_mod", "tag_teardown.py").TagTeardown(app)
        teardown.install()
    except Exception as error:  # an old tree without it: the bench still stops what it starts
        print(f"pl-launch: no tag teardown ({error})", flush=True)
    try:
        if o.pl_light:
            bs.reset_state(tag)
            bench(app, o.out, "light", ["--profile", "realistic", *modes, *common], report)
        if o.pl_stress:
            bs.reset_state(tag)
            stress = load("perf_stress_session", "perf-stress-session.py")
            App = stress.load_activation_app()
            launched = App(app, o.out, 50)
            launched.launch()
            try:
                summary = stress.Stress(launched.rpc).build()
                print("STRESS-SESSION " + json.dumps(summary), flush=True)
                report["stress_session"] = summary
                report["stress_cef"] = launched.rpc("debug.cef", timeout=20)
                print("pl-launch: debug.cef " + json.dumps(report["stress_cef"])[:2000], flush=True)
            finally:
                quit_reply = launched.rpc("debug.quit", {"fixture_quit": "keep"}, timeout=20)
                print(f"pl-launch: STRESS quit (keep sessions): {quit_reply}", flush=True)
                try:
                    launched.process.wait(90)
                except subprocess.TimeoutExpired:
                    print("pl-launch: the STRESS app did not quit in 90 s; terminating it", flush=True)
                    launched.process.terminate()
                    launched.process.wait(20)
            time.sleep(2)  # test script: the daemon writes its state after the app's exit
            for mode in [m for m in o.pl_modes.split(",") if m]:
                bench(app, o.out, f"stress-{mode}", ["--mode", mode, "--timeout", "90", *common], report)
    finally:
        if teardown:
            teardown.end()
        with open(o.json, "w") as f:
            json.dump(report, f, indent=1)
        print(f"pl-launch: report {o.json}", flush=True)


if __name__ == "__main__":
    main()
