#!/usr/bin/env python3
"""Scratch fleet harness for the ns-launch-stalls-remaining retest (testing only, never lands).

Runs through the allowlisted fleet entry scripts/measure/split-spring.sh with --suite=nsl-launch:
  light : bench-startup.py --app APP --mode warm --runs N --profile realistic --launch-guard --wake-attachments 128
  stress: bench-startup.py --app APP --mode warm --runs N --profile stress --launch-guard
Writes one report.json (host, displays, every log, json and exit code) at --json. Exits 1 when a guard run failed.
"""
import argparse, json, os, platform, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError) as error:  # a host probe: reported in the report, never fatal
        return f"error: {error}"


def bench(app, out, name, args, report):
    log_path, json_path = os.path.join(out, f"{name}.log"), os.path.join(out, f"{name}.json")
    cmd = [sys.executable, "-u", os.path.join(HERE, "bench-startup.py"), "--app", app, *args, "--json", json_path]
    print(f"nsl-launch: {name}: {' '.join(cmd)}", flush=True)
    with open(log_path, "w") as log:
        code = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT)
    text = open(log_path).read()
    print(text, flush=True)
    print(f"nsl-launch: {name} exit {code}", flush=True)
    entry = {"cmd": cmd[2:], "exit": code, "log": text}
    if os.path.exists(json_path):
        try:
            entry["json"] = json.load(open(json_path))
        except ValueError as error:
            entry["json_error"] = str(error)
    report["runs"][name] = entry
    return code


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--tag"); p.add_argument("--app", required=True); p.add_argument("--out", required=True)
    p.add_argument("--json", required=True)
    p.add_argument("--nsl-runs", type=int, default=5)
    p.add_argument("--nsl-parts", default="light,stress")
    o, _ = p.parse_known_args([a for a in sys.argv[1:] if a != "--suite=nsl-launch"])
    os.makedirs(o.out, exist_ok=True)
    app = os.path.abspath(o.app)
    report = {"host": {"hostname": platform.node(), "sw_vers": sh(["sw_vers"]), "model": sh(["sysctl", "-n", "hw.model"]).strip(),
                       "cpu": sh(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
                       "head": sh(["git", "-C", HERE, "rev-parse", "HEAD"]).strip(), "app": app},
              "runs": {}}
    displays = sh(["system_profiler", "-json", "SPDisplaysDataType"])
    try:
        report["host"]["displays"] = json.loads(displays or "{}")
    except ValueError:
        report["host"]["displays"] = displays[:2000]
    print("nsl-launch: host " + json.dumps({k: v for k, v in report["host"].items() if k != "displays"}), flush=True)
    print("nsl-launch: displays " + json.dumps(report["host"]["displays"])[:2000], flush=True)
    parts = [x for x in o.nsl_parts.split(",") if x]
    failed = []
    try:
        if "light" in parts and bench(app, o.out, "light", ["--mode", "warm", "--runs", str(o.nsl_runs), "--profile", "realistic",
                                                             "--launch-guard", "--wake-attachments", "128"], report):
            failed.append("light")
        if "stress" in parts and bench(app, o.out, "stress", ["--mode", "warm", "--runs", str(o.nsl_runs), "--profile", "stress",
                                                               "--launch-guard", "--timeout", "90"], report):
            failed.append("stress")
    finally:
        report["failed"] = failed
        with open(o.json, "w") as f:
            json.dump(report, f, indent=1)
        print(f"nsl-launch: report {o.json}; failed {failed}", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
