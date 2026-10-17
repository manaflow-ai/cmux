#!/usr/bin/env python3
"""Cold/warm/explicit-previsit workspace journeys using the tab-switch bench RPCs.

Only launches the supplied tagged app. Measurements are surface-readiness RPC
upper bounds, not pixels-presented times. Performance warnings always exit 0.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time

from workspace_switch_receipt import CACHE_STATES, frame_metrics, receipt, visible_state, write_report


def display_info() -> dict:
    probe = subprocess.run(["system_profiler", "SPDisplaysDataType", "-json"], capture_output=True, text=True, timeout=30)
    try:
        adapters = json.loads(probe.stdout)["SPDisplaysDataType"]
        return {"adapters": [{"model": row.get("sppci_model"), "displays": row.get("spdisplays_ndrvs", [])} for row in adapters],
                "selection": "last screen (CMUX_NEXT_TEST_WINDOW_SCREEN)"}
    except (ValueError, KeyError):
        return {"selection": "last screen", "error": "display metadata unavailable"}


def measure(bench, action, target, args, scenario, iteration, *, previous=None) -> dict:
    from bench_tab_switch import refused, result
    bench.control.call("debug.frames", {"action": "start"}, timeout=10)
    started = time.monotonic()
    reason = refused(action())
    if reason:
        raise RuntimeError(f"workspace action refused: {reason}")
    first, settled, stable_since = None, None, None
    transient, transient_count, samples, last = [], 0, 0, ["no surface sample"]
    destination = target
    deadline = started + args.deadline
    while time.monotonic() < deadline:
        if destination is None:
            candidate = (bench.topology().get("focus") or {}).get("workspace")
            if candidate and candidate != previous:
                destination = candidate
        state = bench.surfaces()
        ready, last = visible_state(state, destination)
        ready = ready and destination is not None
        if destination is None:
            last = ["new workspace has not been selected"]
        now = time.monotonic()
        samples += 1
        if ready:
            if first is None:
                first = (now - started) * 1000
            stable_since = stable_since or now
            if now - stable_since >= args.stable_ms / 1000:
                settled = (now - started) * 1000
                break
        else:
            stable_since = None
            transient_count += 1
            if len(transient) < 20:
                transient.append({"at_ms": round((now - started) * 1000, 3), "violations": last})
        time.sleep(args.poll_ms / 1000)  # bench sampling; overhead is included in the upper bound
    # Keep a short, fixed display-frame observation window even for a fast switch.
    remaining = args.frame_window_ms / 1000 - (time.monotonic() - started)
    if remaining > 0:
        time.sleep(remaining)
    frames = frame_metrics(result(bench.control.call("debug.frames", {"action": "stop"}, timeout=10)))
    _, final = visible_state(bench.surfaces(), destination)
    return {"scenario": scenario, "iteration": iteration, "cache_state": CACHE_STATES[scenario],
            "workspace": destination, "first_visible_ms": round(first, 3) if first is not None else None,
            "settled_ms": round(settled, 3) if settled is not None else None, "frames": frames,
            "invariant_samples": samples, "transient_violations": transient, "transient_violation_count": transient_count,
            "settled_violations": final,
            "status": "measured" if settled is not None else "timeout"}


def run(args, report):
    # Native libraries load only here; receipt tests and --help are portable.
    from bench_tab_switch import Bench, refused, result, wait_for_socket
    from daemon_teardown import end_terminals
    bundle = args.app.resolve()
    if bundle.name != f"cmux DEV {args.tag}.app":
        raise RuntimeError("--app must be the cmux DEV <tag>.app for this bench tag")
    with (bundle / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") == "com.cmuxterm.app":
        raise RuntimeError("the user's cmux bundle may never be benchmarked")
    binary = bundle / "Contents/MacOS/cmux DEV"
    report["app"] = {"bundle_id": info.get("CFBundleIdentifier"), "version": info.get("CFBundleVersion"),
                     "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    if subprocess.run(["pgrep", "-f", re.escape(str(binary))], capture_output=True, text=True).stdout.strip():
        report.update(status="skipped", reason="this tagged app is already running")
        return
    slug = re.sub(r"[^a-z0-9]+", "-", args.tag.lower()).strip("-")
    with tempfile.TemporaryDirectory(prefix=f"workspace-switch-{slug}-") as scratch:
        env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_TAG": args.tag, "CMUX_NEXT_NO_ACTIVATE": "1",
               "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
               "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"), "CMUX_DEV_BACKEND_MODE": "local"}
        app = subprocess.Popen([str(binary)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            control = wait_for_socket(f"/tmp/cmux-debug-{slug}.sock")
            identity = result(control.call("system.identify"))
            if identity.get("pid") != app.pid:
                raise RuntimeError("tagged socket identity does not match the app this bench launched")
            bench = Bench(control, app.pid, args)

            def action(name, **kwargs):
                reply = control.action(name, timeout=30, **kwargs)
                reason = refused(reply)
                if reason:
                    raise RuntimeError(f"{name}: {reason}")
                return reply

            # Reset only our disposable tagged daemon's earlier benchmark workspaces.
            action("workspace new")
            action("palette.closeOtherWorkspaces")
            home = (bench.topology().get("focus") or {}).get("workspace")
            def select(workspace):
                order = [row["id"] for row in bench.topology().get("workspaces", [])]
                return action("selectWorkspaceByNumber", index=order.index(workspace) + 1)

            setup = measure(bench, lambda: select(home), home, args, "warm", 0)
            if setup["settled_ms"] is None:
                report.update(status="skipped", reason="tagged window never became drawable in the GUI session")
                return
            report["setup_surfaces"] = bench.surfaces()
            def return_home():
                parked = measure(bench, lambda: select(home), home, args, "warm", 0)
                if parked["settled_ms"] is None:
                    raise RuntimeError("home workspace did not settle between journeys")

            for iteration in range(1, args.runs + 1):
                return_home()
                cold = measure(bench, lambda: action("workspace new"), None, args, "cold", iteration, previous=home)
                report["runs"].append(cold)
                target = cold["workspace"]
                if not target:
                    raise RuntimeError("new workspace did not appear before the deadline")
                # Warm: content from the cold journey remains parked while home is shown.
                return_home()
                time.sleep(args.warm_delay_ms / 1000)
                report["runs"].append(measure(bench, lambda: select(target), target, args, "warm", iteration))
                # Prefetch simulation: explicitly prime the destination, return home, then time it.
                return_home()
                primed = measure(bench, lambda: select(target), target, args, "prefetched", 0)
                return_home()
                row = measure(bench, lambda: select(target), target, args, "prefetched", iteration)
                row["previsit_ready"] = primed["settled_ms"] is not None
                report["runs"].append(row)
        finally:
            if app.poll() is None:
                app.send_signal(signal.SIGTERM)
            try:
                app.wait(timeout=15)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait(timeout=5)
            try:
                report["teardown"] = end_terminals(str(bundle / "Contents/Resources/bin/cmux-tui"), args.tag)
            except Exception as error:
                report["teardown"] = {"error": str(error)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--sha", required=True, help="full source SHA of the downloaded app, not the harness checkout")
    parser.add_argument("--harness-sha", default="unknown")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--deadline", type=float, default=5)
    parser.add_argument("--stable-ms", type=float, default=100)
    parser.add_argument("--poll-ms", type=float, default=20)
    parser.add_argument("--frame-window-ms", type=float, default=400)
    parser.add_argument("--warm-delay-ms", type=float, default=1000)
    args = parser.parse_args(argv)
    if not 1 <= args.runs <= 10 or min(args.deadline, args.stable_ms, args.poll_ms, args.frame_window_ms, args.warm_delay_ms) <= 0:
        parser.error("runs must be 1..10 and time windows must be positive")
    parameters = {key: value for key, value in vars(args).items() if key not in ("app", "out")}
    report = receipt(args.sha, args.tag, {}, parameters)
    code = 0
    try:
        if sys.platform != "darwin":
            report.update(status="skipped", reason="a macOS GUI runner is required")
        else:
            report = receipt(args.sha, args.tag, display_info(), parameters)
            run(args, report)
    except (Exception, SystemExit) as error:
        report.update(status="error", reason=str(error))
        code = 1
    finally:
        write_report(report, args.out)
    return code


if __name__ == "__main__":
    sys.exit(main())
