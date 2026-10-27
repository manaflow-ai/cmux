#!/usr/bin/env python3
"""Bounded real-workspace scale probe. Run on an exclusively leased GUI Mac.

Creates ordinary background terminal workspaces through the bundled CLI. The
same script measures before/after; --empty is a diagnostic control only.
Uses bench_launch for tagged launch, fresh state, GUI/limit checks and teardown.
No permanent timers, observers, or background processes survive the run.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time


def command(argv, timeout=15):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{argv[0]} exit {result.returncode}: {result.stderr[-300:]}")
    return result.stdout.strip()


def cpu_seconds(value):
    days, _, clock = value.rpartition("-")
    parts = [float(p) for p in clock.split(":")]
    return (int(days) * 86400 if days else 0) + sum(v * 60 ** i for i, v in enumerate(reversed(parts)))


def processes():
    begin = time.monotonic()
    rows = {}
    for line in command(["ps", "-axo", "pid=,ppid=,rss=,time=,comm="]).splitlines():
        fields = line.split(None, 4)
        if len(fields) == 5:
            pid, parent, rss, cpu, name = fields
            rows[int(pid)] = dict(parent=int(parent), rss_bytes=int(rss) * 1024,
                                  cpu_s=cpu_seconds(cpu), name=name)
    end = time.monotonic()
    return rows, (begin + end) / 2, end - begin


def percentile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * p))] if ordered else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--sizes", default="50,100,200,400")
    parser.add_argument("--empty", action="store_true")
    parser.add_argument("--focus", action="store_true", help="visit each created workspace (diagnostic control)")
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--deadline", type=float, default=3600)
    opts = parser.parse_args()
    from bench_launch import BenchApp, host_facts
    from bench_idle import usage

    out = Path(opts.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    sizes = [int(v) for v in opts.sizes.split(",")]
    if sizes != sorted(set(sizes)) or not sizes or sizes[0] < 1 or sizes[-1] > 400:
        parser.error("sizes must be unique, increasing, and between 1 and 400")
    report = dict(status="running", mode="empty" if opts.empty else "terminal",
                  focus_each=opts.focus,
                  host=platform.node(), facts=host_facts(), checkpoints=[], creations=[])
    app = BenchApp(opts.app, out=str(out), env={"CMUX_NEXT_NO_ACTIVATE": None})
    deadline = time.monotonic() + opts.deadline
    made = 0
    creation_sample = None

    def save():
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def rpc(method, params=None, timeout=15):
        result = app.rpc(method, params, timeout=timeout)
        if not isinstance(result, dict) or result.get("error"):
            raise RuntimeError(f"{method}: {str(result)[-400:]}")
        return result

    def check_deadline():
        if time.monotonic() >= deadline:
            raise RuntimeError("scale probe reached its total deadline")

    def profile(label):
        # Exact PID from our Popen; never attach to another app.
        result = subprocess.run(["sample", str(app.process.pid), "3", "10", "-file",
                                 str(out / f"sample-{label}.txt")],
                                capture_output=True, text=True, timeout=15)
        return dict(exit=result.returncode, detail=result.stderr[-200:])

    def system():
        return {name: command(argv) for name, argv in {
            "vm_stat": ["vm_stat"], "swap": ["sysctl", "vm.swapusage"],
            "pressure": ["memory_pressure", "-Q"],
            "load": ["sysctl", "vm.loadavg"],
        }.items()}

    def verified_topology(target):
        expected = {f"scale-{index:03d}" for index in range(1, target + 1)}
        end = min(deadline, time.monotonic() + 30)
        detail = None
        while time.monotonic() < end:
            topology = rpc("snapshot.get")
            topology = topology.get("topology", topology)
            rows = [w for w in topology["workspaces"] if w["name"] in expected]
            valid = []
            for workspace in rows:
                tabs = [tab for screen in workspace["screens"] for pane in screen["panes"] for tab in pane["tabs"]]
                valid.append(not tabs if opts.empty else len(tabs) == 1 and tabs[0]["kind"] == "terminal" and
                             bool(tabs[0].get("terminal")) and not tabs[0]["dead"])
            names = [w["name"] for w in rows]
            detail = dict(created_workspaces=len(rows), valid_workspaces=sum(valid),
                          total_workspaces=len(topology["workspaces"]))
            if len(names) == target and set(names) == expected and all(valid):
                return topology, detail
            time.sleep(.1)  # bounded wait for CLI-created workspaces to mirror, not a completion claim
        raise RuntimeError(f"workspace population never matched requested fixture: {detail}")

    def show_created(output):
        created = json.loads(output)
        workspace = created.get("result", created)["value"]["workspace_id"]
        end = min(deadline, time.monotonic() + 10)
        match = None
        while time.monotonic() < end:
            snapshot = rpc("snapshot.get")
            topology = snapshot.get("topology", snapshot)
            match = next((w for w in topology["workspaces"] if w["id"] == workspace), None)
            if match:
                break
            time.sleep(.05)  # wait for the daemon-created model before issuing its UI action
        if match is None:
            raise RuntimeError(f"created workspace {workspace} never mirrored")
        rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": match["key"]},
                           "origin": "script", "focus": True})
        end = min(deadline, time.monotonic() + 10)
        while time.monotonic() < end:
            snapshot = rpc("snapshot.get")
            topology = snapshot.get("topology", snapshot)
            match = next((w for w in topology["workspaces"] if w["id"] == workspace), None)
            screens = rpc("debug.screens").get("windows", [])
            if (match and topology["focus"]["workspace"] == workspace and
                    any(window["workspace"] == match["key"] for window in screens)):
                return
            time.sleep(.05)  # bounded wait until the created native workspace is actually mounted
        raise RuntimeError(f"created workspace {workspace} never mounted in the window")

    try:
        app.launch()
        report.update(pid=app.process.pid, socket=app.socket, limits=app.limits,
                      app=app.app, launch_environment=app.launched_env)
        report["initial_topology"] = rpc("snapshot.get")
        report["initial_system"] = system()
        save()
        for target in sizes:
            check_deadline()
            rpc("debug.frames", {"action": "start"})
            segment_start = time.monotonic()
            creation_sample = subprocess.Popen([
                "sample", str(app.process.pid), "3", "10", "-file",
                str(out / f"sample-creating-{target}.txt")],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            while made < target:
                check_deadline()
                name = f"scale-{made + 1:03d}"
                args = [app.cli, "--app-socket", app.socket, "--json", "workspace", "create", "--name", name]
                if opts.empty:
                    args.append("--empty")
                if opts.focus:
                    args.append("--focus")
                start = time.monotonic()
                result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True,
                                        text=True, timeout=30, env=app.launched_env)
                report["creations"].append(dict(index=made + 1, ms=(time.monotonic() - start) * 1000,
                                                exit=result.returncode, result=result.stdout[-300:],
                                                error=result.stderr[-300:]))
                if result.returncode:
                    raise RuntimeError(f"workspace {made + 1} create failed: {result.stderr[-300:]}")
                if opts.focus:
                    show_created(result.stdout)
                made += 1
            topology, population = verified_topology(target)
            checkpoint = dict(created=made, creation_seconds=time.monotonic() - segment_start,
                              verified_population=population, topology=topology,
                              creation_frames=rpc("debug.frames", {"action": "stop", "raw": True}))
            checkpoint["creation_sample_exit"] = creation_sample.wait(timeout=15)
            creation_sample = None
            report["checkpoints"].append(checkpoint)
            save()
            # Profile after creation, then measure idle with no app-side probe running.
            checkpoint["sample"] = profile(str(target))
            before, before_time, before_span = processes()
            footprint_before = usage(app.process.pid)
            time.sleep(opts.seconds)  # bounded measurement interval, not a completion wait
            after, after_time, after_span = processes()
            elapsed = after_time - before_time
            footprint_after = usage(app.process.pid)
            selected = {pid for pid, row in after.items() if pid == app.process.pid or
                        row["name"].endswith("/WindowServer") or
                        row["name"].startswith(app.app + "/")}
            # Include shell processes and other descendants in the terminal resource cost.
            while True:
                expanded = selected | {pid for pid, row in after.items() if row["parent"] in selected and
                                       not row["name"].endswith("/WindowServer")}
                if expanded == selected:
                    break
                selected = expanded
            checkpoint["cpu_interval_s"] = elapsed
            checkpoint["cpu_snapshot_uncertainty_s"] = (before_span + after_span) / 2
            checkpoint["processes"] = [dict(pid=pid, **after[pid], cpu_percent=
                (after[pid]["cpu_s"] - before[pid]["cpu_s"]) / elapsed * 100
                if pid in before else None) for pid in sorted(selected)]
            checkpoint["app_usage_before"] = footprint_before
            checkpoint["app_usage_after"] = footprint_after
            checkpoint["system"] = system()
            checkpoint["wakeups"] = rpc("debug.wakeups", {"run_loop": True})
            checkpoint["sidebar"] = rpc("debug.sidebar_rows")
            rpc("debug.frames", {"action": "start"})
            rpc("debug.main_cpu", {"action": "start"})
            latency = []
            for _ in range(100):
                check_deadline()
                start = time.monotonic()
                rpc("debug.frames", {"action": "read"})
                latency.append((time.monotonic() - start) * 1000)
                time.sleep(.05)  # bounded 20 Hz main-thread response probe
            checkpoint["response_ms"] = dict(p50=statistics.median(latency),
                                              p95=percentile(latency, .95), maximum=max(latency))
            checkpoint["response_frames"] = rpc("debug.frames", {"action": "stop", "raw": True})
            checkpoint["main_cpu"] = rpc("debug.main_cpu", {"action": "stop"})
            checkpoint["topology_after"], checkpoint["population_after"] = verified_topology(target)
            save()
            print(json.dumps({"created": made, "response_ms": checkpoint["response_ms"],
                              "app_footprint_bytes": footprint_after[2] if footprint_after else None}), flush=True)
        report["status"] = "completed"
    except BaseException as error:
        report.update(status="failed", error=f"{type(error).__name__}: {error}", created=made)
        if app.process and app.process.poll() is None:
            try:
                report["failure_profile"] = profile("failure")
                report["failure_system"] = system()
            except Exception as diagnostic:
                report["diagnostic_error"] = str(diagnostic)
        raise
    finally:
        try:
            save()
        finally:
            try:
                if creation_sample is not None:
                    if creation_sample.poll() is None:
                        creation_sample.terminate()
                    try:
                        creation_sample.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        creation_sample.kill()
                        creation_sample.wait(timeout=5)
            finally:
                app.stop()


if __name__ == "__main__":
    main()
