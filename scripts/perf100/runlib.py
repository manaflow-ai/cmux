"""perf100 run records: host facts, process groups, flat metrics and the run JSON."""
from __future__ import annotations

import json
import os
import platform
import socket
import subprocess
import sys
import time

import procstat

SCHEMA = "perf100.run.v1"
# Groups that are cmux's own cost; the rest (the scenario's workload, agent stand-ins,
# harness clients) are reported but stay out of the cmux total.
CMUX_GROUPS = ("app", "tui", "acpmux", "browser", "helpers")
GROUP_ORDER = CMUX_GROUPS + ("agents", "workload", "harness")
GROUP_METRICS = ("procs", "exited_procs", "cpu_s", "cpu_pct", "wakeups_per_s", "pkg_idle_wakeups_per_s", "rss_mb", "footprint_mb", "peak_footprint_mb",
                 "threads", "disk_written_mb", "disk_written_mb_per_min", "disk_io_written_mb", "syscalls_per_s",
                 "energy_mw")


def group_of(kind: str) -> str:
    if kind == "app":
        return "app"
    if kind in ("tui-daemon", "tui-daemon-chief", "terminal-host"):
        return "tui"
    if kind == "acpmux-client":
        return "harness"
    if kind.startswith("acpmux"):
        return "acpmux"
    if kind.startswith(("cef-", "webkit-")):
        return "browser"
    if kind == "agent-standin":
        return "agents"
    if kind.startswith("workload:"):
        return "workload"
    return "helpers"


def sh(argv: list[str]) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def host_info(host_class: str | None = None) -> dict:
    name = socket.gethostname().split(".")[0]
    info = {"name": name, "class": host_class or os.environ.get("PERF100_HOST_CLASS") or name,
            "os": platform.platform(), "machine": platform.machine(), "cores": os.cpu_count(),
            "python": sys.version.split()[0], "load_at_start": [round(x, 2) for x in os.getloadavg()]}
    if procstat.IS_MAC:
        info["model"] = sh(["sysctl", "-n", "hw.model"])
        info["cpu"] = sh(["sysctl", "-n", "machdep.cpu.brand_string"])
        info["ram_gb"] = round(int(sh(["sysctl", "-n", "hw.memsize"]) or 0) / 1073741824)
        info["macos"] = sh(["sw_vers", "-productVersion"])
        info["ptmx_max"] = sh(["sysctl", "-n", "kern.tty.ptmx_max"])
    else:
        try:
            with open("/proc/meminfo") as handle:
                info["ram_gb"] = round(int(handle.readline().split()[1]) / 1048576)
            with open("/proc/cpuinfo") as handle:
                info["cpu"] = next((l.split(":", 1)[1].strip() for l in handle if l.startswith("model name")), "")
        except OSError:
            pass
    return info


def git_sha(root: str) -> str:
    return sh(["git", "-C", root, "rev-parse", "HEAD"])


def latency_summary(values: list[float]) -> dict:
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return {"n": 0}
    q = lambda p: vals[min(len(vals) - 1, int(p * len(vals)))]  # noqa: E731
    return {"n": len(vals), "p50_ms": round(q(0.5), 2), "p95_ms": round(q(0.95), 2), "max_ms": round(vals[-1], 2)}


class Run:
    """One scenario run: collects windows, extra metrics and notes, and writes the JSON."""

    def __init__(self, scenario: str, variant: str, seed: int, args: dict, build: dict, host_class: str | None):
        self.data = {"schema": SCHEMA, "scenario": scenario, "variant": variant, "seed": seed,
                     "host": host_info(host_class), "build": build, "params": args,
                     "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                     "sources": procstat.SOURCES, "phases": {}, "metrics": {}, "notes": [], "unverified": []}
        self.began = time.monotonic()

    def phase(self, name: str, window: "procstat.Window", per_unit: dict | None = None) -> dict:
        """Records one measured window under `name`: groups, kinds and flat metrics `name.group.metric`."""
        groups = window.aggregate(group_of)
        total = {}
        for g in CMUX_GROUPS:
            for metric, value in (groups.get(g) or {}).items():
                if value is not None:
                    total[metric] = round(total.get(metric, 0) + value, 3)
        if total:
            # The peak of the sum, not the sum of the groups' peaks.
            peak = window.peak(lambda k: group_of(k) in CMUX_GROUPS) / procstat.MB
            total["peak_footprint_mb"] = round(max(peak, total.get("footprint_mb", 0)), 1)
        groups["cmux"] = total
        kinds = window.aggregate(lambda k: k)
        entry = {"seconds": round(window.seconds, 2), "groups": groups, "kinds": kinds,
                 "processes": sorted(window.rows, key=lambda r: -(r.get("footprint") or 0))[:40]}
        if per_unit:
            entry["per_unit"] = per_unit
        self.data["phases"][name] = entry
        for g, values in groups.items():
            for metric in GROUP_METRICS:
                if values.get(metric) is not None:
                    self.data["metrics"][f"{name}.{g}.{metric}"] = values[metric]
        for unit, values in (per_unit or {}).items():
            for metric, value in values.items():
                self.data["metrics"][f"{name}.per_{unit}.{metric}"] = value
        return entry

    def metric(self, name: str, value):
        if value is not None:
            self.data["metrics"][name] = value

    def latency(self, name: str, values: list[float]):
        summary = latency_summary(values)
        self.data.setdefault("latency", {})[name] = summary
        for key in ("p50_ms", "p95_ms", "max_ms"):
            if key in summary:
                self.data["metrics"][f"latency.{name}.{key}"] = summary[key]

    def note(self, text: str):
        self.data["notes"].append(text)

    def unverified(self, text: str):
        self.data["unverified"].append(text)

    def write(self, out_dir: str) -> str:
        self.data["wall_s"] = round(time.monotonic() - self.began, 1)
        self.data["host"]["load_at_end"] = [round(x, 2) for x in os.getloadavg()]
        os.makedirs(out_dir, exist_ok=True)
        tag = self.data["build"].get("tag") or "untagged"
        path = os.path.join(out_dir, f"{self.data['scenario']}-{self.data['variant']}-{tag}-seed{self.data['seed']}.json")
        with open(path, "w") as handle:
            json.dump(self.data, handle, indent=1, sort_keys=False)
        return path


def per_unit(groups: dict, count: int, unit: str, which=("cmux", "tui", "app", "acpmux", "browser")) -> dict:
    """Footprint, RSS, threads and CPU-seconds per unit (terminal, tab, agent session)."""
    if count <= 0:
        return {}
    rows = {}
    for g in which:
        values = groups.get(g) or {}
        if not values:
            continue
        rows[f"{g}_footprint_mb"] = round(values.get("footprint_mb", 0) / count, 3)
        rows[f"{g}_rss_mb"] = round(values.get("rss_mb", 0) / count, 3)
        rows[f"{g}_threads"] = round(values.get("threads", 0) / count, 2)
    return {unit: rows}
