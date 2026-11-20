#!/usr/bin/env python3
"""Sidebar stress at 1x and at scale, customization included: runs sidebar-stress-bench.py once per profile against
one built app, each a fresh launch, and writes every profile's results to --json (no traces).

  1x     20 workspaces in 1 group, custom sections 1, 10, 50
  scale  500 workspaces in 50 groups, custom sections 50

Each profile runs scroll, switch, theme_scroll and custom_sections (sidebar-stress-bench.py's docstring).
Fleet routes (both build a bench-config app of the step's checkout first):
  cmux-ci run --class exclusive --label measure --measurement --display --script scripts/measure/split-spring.sh \
    --ref <sha> --arg=--suite=sidebar-stress --arg=--config=bench --artifact artifacts/split-spring/report.json
  cmux-ci run ... --script scripts/measure/sidebar-stress.sh --ref <feat-cmux-next sha> --artifact sidebar-stress.json
Other arguments (--profiles=1x,scale aside) go to every bench run, e.g. --no-trace."""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROFILES = {
    "1x": ["--sizes", "20", "--groups", "1", "--custom-sections", "1,10,50"],
    "scale": ["--sizes", "500", "--groups", "50", "--custom-sections", "50"],
}
SCENARIOS = "scroll,switch,theme_scroll,custom_sections"


def main(argv):
    opts, rest = {}, []
    it = iter(argv)
    for arg in it:
        key = arg.split("=", 1)[0]
        if key in ("--tag", "--app", "--out", "--json", "--profiles"):
            opts[key] = arg.split("=", 1)[1] if "=" in arg else next(it)
        else:
            rest.append(arg)
    for need in ("--tag", "--app", "--out"):
        if need not in opts:
            sys.exit(f"sidebar-stress-profiles: {need} is required")
    profiles = [p for p in opts.get("--profiles", "1x,scale").split(",") if p]
    unknown = [p for p in profiles if p not in PROFILES]
    if unknown:
        sys.exit(f"sidebar-stress-profiles: unknown profile {unknown} (known: {', '.join(PROFILES)})")
    env = dict(os.environ)
    env.setdefault("CMUX_BENCH_LAUNCH", "direct")  # a fleet step has no LaunchServices session
    merged, failed = {}, False
    for profile in profiles:
        out = os.path.join(opts["--out"], f"sidebar-{profile}")
        cmd = [sys.executable, os.path.join(HERE, "sidebar-stress-bench.py"), "--app", opts["--app"], "--tag", opts["--tag"],
               "--out", out, "--scenarios", SCENARIOS, "--tickers", "1", "--stop", *PROFILES[profile], *rest]
        print(f"sidebar-stress: profile {profile}: {' '.join(cmd[2:])}", flush=True)
        # One profile that fails does not stop the next (each launches its own app); the run fails at the end.
        code = subprocess.call(cmd, env=env)
        if code != 0:
            print(f"sidebar-stress: profile {profile} exited {code}", flush=True)
            failed = True
        path = os.path.join(out, "results.json")
        merged[profile] = json.load(open(path)) if os.path.exists(path) else {"error": f"no results.json (exit {code})"}
        merged[profile]["exit"] = code
    dest = opts.get("--json") or os.path.join(opts["--out"], "sidebar-stress.json")
    with open(dest, "w") as f:
        json.dump(merged, f, indent=1, default=str)
    print(f"sidebar-stress: wrote {dest} ({os.path.getsize(dest)} bytes)", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
