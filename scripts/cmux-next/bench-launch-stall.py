#!/usr/bin/env python3
"""Does the main-thread watchdog see a stall in main(), before NSApp exists, with its startup tag (p08-startup-088)?

Launches a bench or DEV build (`reload.sh --config bench`) with CMUX_NEXT_BENCH_LAUNCH_STALL_MS (default 300): the app
spins its main thread that long in main(), inside the startup task `bench.launch_stall`, before NSApp. Then reads
`debug.hangs` and passes when one stall of at least that length is listed with `startup_phase` `main` and
`startup_task` `bench.launch_stall`. A watchdog that starts only in applicationDidFinishLaunching never sees it (red).

Prints one BENCH-LAUNCH-STALL JSON line; exit 0 on a pass, 1 on a miss, 2 when the app did not launch.

Usage: bench-launch-stall.py --app APP [--stall-ms 300] [--out DIR] [--json PATH]
Fleet: cmux-ci run --class isolated --script 'python3 scripts/cmux-next/bench-launch-stall.py --app "$NX_APP"' --ref SHA
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STALL_VARIABLE = "CMUX_NEXT_BENCH_LAUNCH_STALL_MS"
STALL_TASK = "bench.launch_stall"


def find_launch_stall(reply, stall_ms):
    """The verdict for a `debug.hangs` reply: the longest stall of at least `stall_ms` and its startup tag."""
    records = [r for r in (reply or {}).get("records") or [] if r.get("kind", "stall") == "stall"]
    long_enough = [r for r in records if float(r.get("duration_ms") or 0) >= stall_ms]
    tagged = [r for r in long_enough if r.get("startup_phase") == "main" and r.get("startup_task") == STALL_TASK]
    best = max(tagged or long_enough, key=lambda r: float(r.get("duration_ms") or 0), default=None)
    result = {
        "ok": bool(tagged),
        "installed": bool((reply or {}).get("installed")),
        "stall_ms": stall_ms,
        "stalls": len(records),
    }
    if best is not None:
        result.update(duration_ms=best.get("duration_ms"), startup_phase=best.get("startup_phase"),
                      startup_task=best.get("startup_task"))
    if not tagged:
        result["reason"] = ("a stall of the length was listed without the main-phase startup tag" if long_enough
                            else "no stall of the length was listed: the watchdog was not running in main()")
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--stall-ms", type=int, default=300)
    parser.add_argument("--out")
    parser.add_argument("--json")
    parser.add_argument("--timeout", type=float, default=180)
    opts = parser.parse_args(argv)

    sys.path.insert(0, HERE)
    from bench_launch import BenchApp, LaunchError  # noqa: E402

    app = BenchApp(opts.app, out=opts.out, env={STALL_VARIABLE: str(opts.stall_ms)}, socket_only=True)
    try:
        app.launch(timeout=opts.timeout)
        result = {"tag": app.tag, **find_launch_stall(app.rpc("debug.hangs"), opts.stall_ms)}
        code = 0 if result["ok"] else 1
    except LaunchError as error:
        result, code = {"tag": app.tag, "ok": False, "reason": f"launch: {error.reason}"}, 2
    finally:
        app.stop()
    line = json.dumps(result, sort_keys=True)
    print("BENCH-LAUNCH-STALL " + line, flush=True)
    if opts.json:
        with open(opts.json, "w") as f:
            f.write(line + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
