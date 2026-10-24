#!/usr/bin/env python3
"""Primes a tagged app with the STRESS session for the #17587 launch guard (scripts/measure/launch-guard.sh).

Resets the tag's saved state, launches the app the way activation-perf.py does, builds STRESS
through its debug socket (scripts/cmux-next/perf-stress-session.py), prints the STRESS-SESSION line
and the app's Chromium state (`debug.cef`, measurement validity), then quits the app through
`debug.quit` with the given fixture choice:

  keep          Quit with sessions kept: the daemon and its terminals keep running and every
                visible pane's last terminal frame is saved, so the next launch is a warm one.
  end-sessions  End Sessions, Keep Layout: every terminal ends, its tab stays with a relaunch
                record, the daemon stops (the next launch is kept mode).

  launch-guard-stress-prime.py --app "/path/cmux DEV <tag>.app" --out DIR [--quit keep|end-sessions]
"""
import argparse, importlib.util, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
NEXT = os.path.join(os.path.dirname(HERE), "cmux-next")
sys.path.insert(0, NEXT)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(NEXT, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--quit", choices=["keep", "end-sessions"], default="keep")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    app_path = os.path.abspath(opts.app)
    bench = load("bench_startup", "bench-startup.py")
    stress = load("perf_stress_session", "perf-stress-session.py")
    tag = bench.app_tag(app_path)
    bench.APPS[tag] = app_path
    bench.reset_state(tag)
    app = stress.load_activation_app()(app_path, opts.out, 50)
    app.launch()
    quit_ok = False
    try:
        summary = stress.Stress(app.rpc).build()
        print("STRESS-SESSION " + json.dumps(summary), flush=True)
        cef = app.rpc("debug.cef", timeout=20)
        print("STRESS-CEF " + json.dumps(cef)[:2000], flush=True)
        reply = app.rpc("debug.quit", {"fixture_quit": opts.quit}, timeout=30)
        print(f"stress prime: debug.quit {opts.quit} -> {json.dumps(reply)[:300]}", flush=True)
        try:
            app.process.wait(90)
            quit_ok = True
        except Exception:  # subprocess.TimeoutExpired: reported, then the app is stopped below
            print("stress prime: the app did not quit within 90 s", flush=True)
    finally:
        if not quit_ok:
            app.stop()
    if opts.quit == "keep":
        live = [p for p in bench.tag_pids(tag) if p not in bench.app_pids(tag)]
        print(f"stress prime: {len(live)} tag processes (daemon, hosts) still run after the keep quit", flush=True)
    print(f"stress prime: app exit {app.process.returncode}", flush=True)
    return 0 if quit_ok else 1


if __name__ == "__main__":
    sys.exit(main())
