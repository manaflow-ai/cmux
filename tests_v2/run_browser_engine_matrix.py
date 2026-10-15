#!/usr/bin/env python3
"""Run the v2 browser suites once per browser engine against one cmux socket.

Each suite runs as its own process with CMUX_BROWSER_TEST_ENGINE set, so
tests_v2/cmux.py asks every browser-creating call for that engine and fails a
call that opens another one (a Chromium run cannot pass on a WebKit fallback).

Usage (a tagged build, never the user's cmux):
  CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ...   # launches/targets the tag
  python3 tests_v2/run_browser_engine_matrix.py --socket /tmp/cmux-debug-<tag>.sock \
      [--engines webkit,chromium] [--include-focus] [--json out.json] [SUITE...]

Suites that drive window or first-responder focus (FOCUS_SUITES) are left out
by default: they move focus in the app under test and are run separately.
Suites that need a remote machine (ssh, cloud) are never selected here.
Exit status is nonzero when any selected suite fails on any engine.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINES = ("webkit", "chromium")
# Suites that switch pane, window or first-responder focus.
FOCUS_SUITES = frozenset({
    "test_browser_custom_keybinds",
    "test_browser_goto_split",
    "test_browser_panel_stability",
})


def browser_suites(include_focus: bool) -> list[str]:
    names = sorted(
        path.stem for path in HERE.glob("test_*.py")
        if "browser" in path.stem
        and "ssh" not in path.stem
        and "cloud" not in path.stem
        and path.stem != "test_terminal_path_link_not_browser"
    )
    return [name for name in names if include_focus or name not in FOCUS_SUITES]


def run_suite(name: str, engine: str, socket: str, timeout: float) -> dict:
    env = {**os.environ, "CMUX_SOCKET_PATH": socket, "CMUX_BROWSER_TEST_ENGINE": engine}
    started = time.monotonic()
    try:
        done = subprocess.run(
            [sys.executable, str(HERE / f"{name}.py")],
            env=env, capture_output=True, text=True, timeout=timeout,
        )
        verdict = "pass" if done.returncode == 0 else "fail"
        output = (done.stdout + done.stderr).strip().splitlines()
    except subprocess.TimeoutExpired as expired:
        verdict = "timeout"
        text = (expired.stdout or b"")
        output = (text.decode() if isinstance(text, bytes) else text).strip().splitlines()
    return {
        "suite": name,
        "engine": engine,
        "verdict": verdict,
        "seconds": round(time.monotonic() - started, 1),
        "tail": output[-6:],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("suites", nargs="*", help="suite file stems; default: every browser suite")
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"), help="the tagged app's socket")
    parser.add_argument("--engines", default=",".join(ENGINES))
    parser.add_argument("--include-focus", action="store_true", help="also run the focus-moving suites")
    parser.add_argument("--timeout", type=float, default=300.0, help="seconds per suite run")
    parser.add_argument("--json", type=Path, help="write every result here")
    args = parser.parse_args()
    if not args.socket:
        parser.error("--socket (or CMUX_SOCKET_PATH) names the tagged app's socket")
    engines = [engine.strip() for engine in args.engines.split(",") if engine.strip()]
    unknown = sorted(set(engines) - set(ENGINES))
    if unknown:
        parser.error(f"unknown engine(s): {', '.join(unknown)}")
    available = browser_suites(include_focus=True)
    suites = args.suites or browser_suites(args.include_focus)
    missing = sorted(set(suites) - set(available))
    if missing:
        parser.error(f"not browser suites here: {', '.join(missing)}")
    if not suites:
        parser.error("no browser suites selected")

    results = []
    for engine in engines:
        for suite in suites:
            result = run_suite(suite, engine, args.socket, args.timeout)
            results.append(result)
            print(f"{result['verdict']:7} {engine:8} {suite} ({result['seconds']}s)", flush=True)
            if result["verdict"] != "pass":
                for line in result["tail"]:
                    print(f"        | {line}", flush=True)

    print()
    print("| suite | " + " | ".join(engines) + " |")
    print("|---|" + "---|" * len(engines))
    by_key = {(r["suite"], r["engine"]): r["verdict"] for r in results}
    for suite in suites:
        print(f"| {suite} | " + " | ".join(by_key[(suite, e)] for e in engines) + " |")
    if args.json:
        args.json.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    return 0 if all(r["verdict"] == "pass" for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
