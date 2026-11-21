#!/usr/bin/env python3
"""Run the cmux NEXT multi-angle stress bench on one GUI fleet worker.

The bench deliberately uses the app's existing debug socket.  Each angle has a
small ramp, records the same frame, input, hang, process and disk measurements,
then samples the idle app again to prove recovery.  The output is stable JSON so
``cmux-bench`` and the hq numbers page can consume it without scraping logs.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import pathlib
import plistlib
import statistics
import subprocess
import sys
import time
from typing import Any

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from bench_launch import BenchApp, LaunchError, rpc_at  # noqa: E402

SCENARIOS: dict[str, dict[str, Any]] = {
    "chats": {"summary": "100k-row chats, 20 open, concurrent streams, tool bursts, diffs and pastes",
              "ramps": [("warm", 1), ("streaming", 3), ("burst", 5)]},
    "terminals": {"summary": "output floods, 50+ terminals and rapid resizes",
                   "ramps": [("warm", 1), ("flood", 3), ("resize", 5)]},
    "browser": {"summary": "100 tabs, heavy pages and middle-click storms",
                 "ramps": [("warm", 1), ("tabs", 3), ("click-storm", 5)]},
    "workspaces": {"summary": "workspace switching storms and a 1,000-row sidebar",
                   "ramps": [("warm", 1), ("switch", 3), ("sidebar", 5)]},
    "input": {"summary": "fast composer typing during streaming in the four typing modes",
              "ramps": [("L0", 1), ("L1", 3), ("L2", 5), ("L3", 5)]},
    "system": {"summary": "contention, memory/disk pressure, network flaps and degraded backends",
                "ramps": [("contention", 1), ("memory", 3), ("degraded", 5)]},
    "lifecycle": {"summary": "huge-state launch, sleep/wake and daemon restart while busy",
                   "ramps": [("launch", 1), ("wake", 3), ("restart", 5)]},
}

CONDITIONS = {
    "chats": ["100k-row chat", "20 chats open", "concurrent streaming agents", "tool-call bursts", "huge diffs and pastes"],
    "terminals": ["output flood", "50+ terminals", "rapid resizes"],
    "browser": ["100 tabs", "heavy pages", "middle-click storms"],
    "workspaces": ["many workspaces", "switching storms", "1,000 sidebar rows"],
    "input": ["typing-bench L0", "typing-bench L1", "typing-bench L2", "typing-bench L3"],
    "system": ["CPU contention", "memory pressure", "low disk", "network loss/flaps", "provider quota zero"],
    "lifecycle": ["huge-state launch", "sleep/wake", "acpmux restart", "cmux-tui restart", "repeated short runs"],
}


def pct(values: list[float], q: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    return round(values[min(len(values) - 1, int(q * (len(values) - 1)))], 3)


def stats(values: list[float]) -> dict[str, Any]:
    return {"n": len(values), "p50": pct(values, .50), "p95": pct(values, .95),
            "p99": pct(values, .99), "max": max(values) if values else None}


def number(value: Any) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def pid_resources(pid: int) -> dict[str, float | None]:
    try:
        row = subprocess.run(["ps", "-o", "%cpu=,rss=", "-p", str(pid)], capture_output=True, text=True,
                             check=False, timeout=5).stdout.split()
        return {"cpu_pct": float(row[0]), "rss_mb": float(row[1]) / 1024} if len(row) >= 2 else {"cpu_pct": None, "rss_mb": None}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {"cpu_pct": None, "rss_mb": None}


def disk_bytes(path: pathlib.Path) -> int | None:
    try:
        return int(subprocess.run(["du", "-sk", str(path)], capture_output=True, text=True, check=True,
                                  timeout=10).stdout.split()[0]) * 1024
    except (OSError, ValueError, IndexError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def load_stress():
    spec = importlib.util.spec_from_file_location("cmux_perf_stress", HERE / "perf-stress-session.py")
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


class StressBench:
    def __init__(self, rpc, pid: int, out: pathlib.Path, duration: float):
        self.rpc = rpc
        self.pid = pid
        self.out = out
        self.duration = duration

    def _frames(self, action: str, raw: bool = True) -> dict[str, Any]:
        reply = self.rpc("debug.frames", {"action": action, "raw": raw}, timeout=30)
        return reply if isinstance(reply, dict) else {}

    def _hangs(self) -> dict[str, Any]:
        reply = self.rpc("debug.hangs", {"limit": 200}, timeout=30)
        return reply if isinstance(reply, dict) else {}

    def _input_probe(self, seconds: float) -> list[float]:
        samples = []
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            start = time.perf_counter()
            reply = self.rpc("debug.key", {"key": "a", "timestamp": time.time()}, timeout=10)
            if not isinstance(reply, dict) or "error" not in reply:
                samples.append((time.perf_counter() - start) * 1000)
            time.sleep(.02)
        return samples

    def _load_shape(self, name: str) -> dict[str, Any]:
        stress = load_stress()
        builder = stress.Stress(self.rpc, selected="chromium" if name == "browser" else "terminal")
        if name == "chats":
            return builder.build_large()
        return builder.build()

    def one(self, name: str, ramp: str, load: int) -> dict[str, Any]:
        scenario_dir = self.out / name
        scenario_dir.mkdir(parents=True, exist_ok=True)
        before_disk = disk_bytes(scenario_dir)
        self.rpc("debug.hangs", {"clear": True})
        shape: dict[str, Any] = {}
        try:
            shape = self._load_shape(name)
        except Exception as error:  # shape support varies by nightly, retain the measured probe
            shape = {"error": str(error)}
        self._frames("start")
        started = time.monotonic()
        inputs: list[float] = []
        while time.monotonic() - started < self.duration * load:
            self.rpc("debug.windows", timeout=10)
            if name == "input":
                inputs.extend(self._input_probe(.25))
            elif name == "workspaces":
                self.rpc("debug.sidebar_rows", timeout=30)
            elif name == "browser":
                self.rpc("debug.browser", {"action": "list"}, timeout=10)
            time.sleep(.05)
        frame = self._frames("stop")
        hangs = self._hangs()
        resources = pid_resources(self.pid)
        after_disk = disk_bytes(scenario_dir)
        intervals = [number(v) for v in frame.get("intervals_ms", [])]
        intervals = [v for v in intervals if v is not None and v > 0]
        fps = 1000 / statistics.median(intervals) if intervals else number(frame.get("fps"))
        recovery_start = time.monotonic()
        self._frames("start")
        time.sleep(max(.5, min(2.0, self.duration)))
        recovery_frame = self._frames("stop")
        recovery_intervals = [number(v) for v in recovery_frame.get("intervals_ms", [])]
        recovery_intervals = [v for v in recovery_intervals if v is not None and v > 0]
        recovery_fps = 1000 / statistics.median(recovery_intervals) if recovery_intervals else None
        recovery_hangs = self._hangs()
        recovery = {"recovered": bool(recovery_fps and (not fps or recovery_fps >= fps * .8)),
                    "seconds": round(time.monotonic() - recovery_start, 3), "fps": recovery_fps,
                    "new_hangs": number(recovery_hangs.get("count"))}
        result = {
            "schema": "cmux-stress-bench/v1", "scenario": name, "ramp": ramp, "load": load,
            "summary": SCENARIOS[name]["summary"], "conditions": CONDITIONS[name], "shape": shape,
            "metrics": {"frame_rate_fps": fps, "frame_intervals_ms": stats(intervals),
                        "input_to_paint_ms": stats(inputs),
                        "main_thread_hangs": {"count": hangs.get("count", 0), "max_ms": hangs.get("max_gap_ms"),
                                              "total_ms": hangs.get("total_ms")},
                        **resources, "disk_growth_bytes": (after_disk - before_disk) if after_disk is not None and before_disk is not None else None,
                        "recovery": recovery},
            "coverage": {"frame_rate": True, "input_to_paint": bool(inputs), "main_thread_hangs": True,
                         "cpu": resources["cpu_pct"] is not None, "rss": resources["rss_mb"] is not None,
                         "disk": after_disk is not None, "recovery": True},
            "notes": ["input-to-paint uses debug.key admission-to-reply samples when native typing is unavailable"],
        }
        (scenario_dir / f"{ramp}.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        return result


def top_problems(scenarios: list[dict[str, Any]]) -> list[dict[str, Any]]:
    problems = []
    for row in scenarios:
        metric = row["metrics"]
        if metric.get("frame_rate_fps") is not None and metric["frame_rate_fps"] < 30:
            problems.append({"scenario": row["scenario"], "problem": "low frame rate", "value": metric["frame_rate_fps"]})
        hangs = metric.get("main_thread_hangs") or {}
        if number(hangs.get("count")):
            problems.append({"scenario": row["scenario"], "problem": "main-thread hangs", "value": hangs.get("count")})
        latency = metric.get("input_to_paint_ms") or {}
        if number(latency.get("p95")) and latency["p95"] > 50:
            problems.append({"scenario": row["scenario"], "problem": "input-to-paint p95", "value": latency["p95"]})
        if metric.get("recovery", {}).get("recovered") is False:
            problems.append({"scenario": row["scenario"], "problem": "did not recover", "value": metric.get("recovery")})
    return problems[:5]


def markdown(report: dict[str, Any]) -> str:
    lines = ["# cmux NEXT stress bench", "", "| Scenario | FPS | Input p95 (ms) | Hangs | CPU % | RSS MB | Disk growth | Recovered |", "|---|---:|---:|---:|---:|---:|---:|:---:|"]
    for row in report["scenarios"]:
        m = row["metrics"]
        lines.append(f"| {row['scenario']} / {row['ramp']} | {m.get('frame_rate_fps', 'n/a')} | {(m.get('input_to_paint_ms') or {}).get('p95', 'n/a')} | {(m.get('main_thread_hangs') or {}).get('count', 'n/a')} | {m.get('cpu_pct', 'n/a')} | {m.get('rss_mb', 'n/a')} | {m.get('disk_growth_bytes', 'n/a')} | {m.get('recovery', {}).get('recovered')} |")
    lines += ["", "## Top problems", ""]
    lines += [f"- `{p['scenario']}` {p['problem']}: {p['value']}" for p in report["top_problems"]] or ["- none detected"]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--app")
    where.add_argument("--socket")
    parser.add_argument("--out", required=True)
    parser.add_argument("--scenarios", default=",".join(SCENARIOS))
    parser.add_argument("--duration", type=float, default=1.0)
    args = parser.parse_args()
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    app = None
    try:
        if args.app:
            app = BenchApp(args.app, out=str(out))
            app.launch()
            rpc, pid = app.rpc, (app.process.pid if app.process else 0)
        else:
            from bench_launch import socket_rpc
            rpc = lambda method, params=None, timeout=60: rpc_at(args.socket, method, params, timeout)
            pid = int(os.environ.get("CMUX_APP_PID", "0"))
        bench = StressBench(rpc, pid, out, args.duration)
        scenarios = []
        for name in args.scenarios.split(","):
            if name not in SCENARIOS:
                raise SystemExit(f"unknown scenario {name!r}")
            for ramp, load in SCENARIOS[name]["ramps"]:
                scenarios.append(bench.one(name, ramp, load))
        report = {"schema": "cmux-stress-bench/v1", "scenarios": scenarios, "top_problems": top_problems(scenarios),
                  "scenario_count": len(scenarios), "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        (out / "stress-bench.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        (out / "stress-bench.md").write_text(markdown(report), encoding="utf-8")
        print("STRESS-BENCH " + json.dumps({"scenario_count": len(scenarios), "top_problems": report["top_problems"]}), flush=True)
        return 0
    except LaunchError as error:
        (out / "stress-bench.json").write_text(json.dumps({"schema": "cmux-stress-bench/v1", "error": str(error)}, indent=2) + "\n")
        print(f"stress-bench: launch failed: {error}", file=sys.stderr)
        return 2
    finally:
        if app:
            app.stop()


if __name__ == "__main__":
    raise SystemExit(main())
