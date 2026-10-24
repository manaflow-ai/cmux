#!/usr/bin/env python3
"""Measure sandbox lifecycle costs with identical commands.

The harness deliberately treats missing isolation capabilities as data.  It
does not silently fall back from a VM to a process, and it never enables
networking for the rootless gVisor path.

Examples:
  sandbox_bench.py probe --runsc /path/to/runsc
  sandbox_bench.py cold --backend process --iterations 30 -- /bin/true
  sandbox_bench.py cold --backend gvisor --runsc /path/to/runsc -- /bin/true
  sandbox_bench.py density --backend gvisor --runsc /path/to/runsc --sizes 1,4,8
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import resource
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable


SCHEMA = 1
DEFAULT_ITERATIONS = 20
DEFAULT_TIMEOUT_S = 30.0


def now_ns() -> int:
    return time.monotonic_ns()


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) - 1) * p
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return round(ordered[low], 3)
    return round(ordered[low] + (ordered[high] - ordered[low]) * (rank - low), 3)


def executable_version(path: str | None) -> str | None:
    if not path:
        return None
    try:
        completed = subprocess.run(
            [path, "--version"], capture_output=True, text=True, timeout=5
        )
    except (OSError, subprocess.SubprocessError):
        return None
    output = (completed.stdout or completed.stderr).strip().splitlines()
    return output[0] if output else None


def command_exists(name: str) -> str | None:
    return shutil.which(name)


def run_probe_command(argv: list[str]) -> dict[str, Any]:
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"available": False, "error": str(exc)}
    return {
        "available": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": completed.stdout.strip()[-400:],
        "stderr": completed.stderr.strip()[-400:],
    }


def host_probe(
    runsc: str | None = None,
    firecracker: str | None = None,
    cloud_hypervisor: str | None = None,
) -> dict[str, Any]:
    cpuinfo = Path("/proc/cpuinfo").read_text(errors="replace") if Path("/proc/cpuinfo").exists() else ""
    flags = set()
    for line in cpuinfo.splitlines():
        if line.lower().startswith(("flags", "features")) and ":" in line:
            flags.update(line.split(":", 1)[1].split())
    kvm = Path("/dev/kvm")
    runsc = runsc or command_exists("runsc")
    firecracker = firecracker or command_exists("firecracker")
    cloud_hypervisor = cloud_hypervisor or command_exists("cloud-hypervisor")
    return {
        "schema": SCHEMA,
        "hostname": platform.node(),
        "kernel": platform.release(),
        "arch": platform.machine(),
        "cpu_count": os.cpu_count(),
        "mem_available_kib": _meminfo_value("MemAvailable"),
        "hypervisor_flag": "hypervisor" in flags,
        "virtualization_flags": sorted(flags.intersection({"vmx", "svm"})),
        "kvm": {
            "path": str(kvm),
            "exists": kvm.exists(),
            "readable": os.access(kvm, os.R_OK),
            "writable": os.access(kvm, os.W_OK),
        },
        "user_namespace": run_probe_command(
            ["unshare", "--user", "--map-root-user", "/bin/true"]
        )
        if command_exists("unshare")
        else {"available": False, "error": "unshare not installed"},
        "runtimes": {
            "runsc": {"path": runsc, "version": executable_version(runsc)},
            "firecracker": {
                "path": firecracker,
                "version": executable_version(firecracker),
            },
            "cloud_hypervisor": {
                "path": cloud_hypervisor,
                "version": executable_version(cloud_hypervisor),
            },
        },
    }


def _meminfo_value(key: str) -> int | None:
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith(key + ":"):
                return int(line.split()[1])
    except (OSError, ValueError):
        return None
    return None


def backend_status(name: str, host: dict[str, Any]) -> dict[str, Any]:
    if name == "process":
        return {"available": True, "mode": "host process baseline"}
    if name == "gvisor":
        runsc = host["runtimes"]["runsc"]["path"]
        if not runsc:
            return {"available": False, "reason": "runsc executable not found"}
        return {
            "available": True,
            "mode": "runsc rootless systrap, network=none",
            "runsc": runsc,
        }
    if name in {"firecracker", "cloud-hypervisor"}:
        runtime_key = "cloud_hypervisor" if name == "cloud-hypervisor" else name
        runtime = host["runtimes"][runtime_key]
        if not runtime["path"]:
            return {"available": False, "reason": f"{name} executable not found"}
        if not host["kvm"]["exists"]:
            return {
                "available": False,
                "reason": "/dev/kvm is absent; a microVM cannot start on this host",
            }
        return {
            "available": False,
            "reason": "a guest kernel/rootfs/config is required; pass the VM image adapter",
            "runtime": runtime,
        }
    return {"available": False, "reason": f"unknown backend {name!r}"}


def _proc_rss_kib(pid: int) -> int:
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except (OSError, ValueError):
        pass
    return 0


def _children_of(pid: int) -> list[int]:
    children: dict[int, list[int]] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / "stat").read_text().split()
            parent = int(fields[3])
            children.setdefault(parent, []).append(int(entry.name))
        except (OSError, ValueError, IndexError):
            continue
    result = [pid]
    queue = [pid]
    while queue:
        parent = queue.pop()
        for child in children.get(parent, []):
            if child not in result:
                result.append(child)
                queue.append(child)
    return result


def process_rss_kib(pid: int) -> int:
    return sum(_proc_rss_kib(child) for child in _children_of(pid))


class Invocation:
    def __init__(self, process: subprocess.Popen[str], cleanup: Any = None):
        self.process = process
        self.cleanup = cleanup

    def close(self) -> None:
        if self.cleanup:
            self.cleanup()


def start_invocation(
    backend: str,
    command: list[str],
    runsc: str | None,
    state_dir: str,
) -> Invocation:
    if backend == "process":
        return Invocation(
            subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
        )
    if backend == "gvisor":
        if not runsc:
            raise RuntimeError("gVisor backend requires --runsc or runsc on PATH")
        root = tempfile.mkdtemp(prefix="runsc-", dir=state_dir)
        argv = [
            runsc,
            "--root",
            root,
            "--rootless",
            "--network=none",
            "--platform=systrap",
            "do",
            "--quiet",
            *command,
        ]
        return Invocation(
            subprocess.Popen(
                argv,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            ),
            cleanup=lambda: shutil.rmtree(root, ignore_errors=True),
        )
    raise RuntimeError(
        f"{backend} lifecycle needs a guest image adapter; use probe to record the host gate"
    )


def stop_invocation(invocation: Invocation) -> None:
    process = invocation.process
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
    invocation.close()


def run_cold(
    backend: str,
    command: list[str],
    iterations: int,
    timeout_s: float,
    runsc: str | None,
    state_dir: str,
) -> dict[str, Any]:
    latencies: list[float] = []
    rss: list[int] = []
    failures: list[dict[str, Any]] = []
    successes = 0
    for index in range(iterations):
        started = now_ns()
        invocation: Invocation | None = None
        try:
            invocation = start_invocation(backend, command, runsc, state_dir)
            try:
                stdout, stderr = invocation.process.communicate(timeout=timeout_s)
                returncode = invocation.process.returncode
            except subprocess.TimeoutExpired:
                stop_invocation(invocation)
                stdout, stderr = "", "timeout"
                returncode = -signal.SIGKILL
            elapsed = (now_ns() - started) / 1_000_000
            latencies.append(elapsed)
            if returncode == 0:
                successes += 1
                rss.append(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
            else:
                failures.append(
                    {
                        "iteration": index,
                        "returncode": returncode,
                        "stdout": stdout[-400:],
                        "stderr": stderr[-400:],
                    }
                )
        except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
            failures.append({"iteration": index, "error": str(exc)})
        finally:
            if invocation:
                invocation.close()
    return {
        "iterations": iterations,
        "completed": len(latencies),
        "successes": successes,
        "failures": failures[:5],
        "latency_ms": {
            "p50": percentile(latencies, 0.50),
            "p95": percentile(latencies, 0.95),
            "p99": percentile(latencies, 0.99),
            "max": round(max(latencies), 3) if latencies else None,
        },
        "child_max_rss_kib": max(rss) if rss else None,
    }


def run_density(
    backend: str,
    command: list[str],
    size: int,
    hold_s: float,
    timeout_s: float,
    runsc: str | None,
    state_dir: str,
) -> dict[str, Any]:
    invocations: list[Invocation] = []
    started_ns = now_ns()
    peak_rss = 0
    try:
        for _ in range(size):
            invocations.append(start_invocation(backend, command, runsc, state_dir))
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            peak_rss = max(peak_rss, sum(process_rss_kib(i.process.pid) for i in invocations))
            if all(i.process.poll() is not None for i in invocations):
                break
            time.sleep(0.005)
        elapsed_ms = (now_ns() - started_ns) / 1_000_000
        failures = []
        for index, invocation in enumerate(invocations):
            try:
                stdout, stderr = invocation.process.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                stop_invocation(invocation)
                stdout, stderr = "", "timeout"
            if invocation.process.returncode != 0:
                failures.append(
                    {
                        "index": index,
                        "returncode": invocation.process.returncode,
                        "stdout": stdout[-200:],
                        "stderr": stderr[-400:],
                    }
                )
        return {
            "size": size,
            "elapsed_ms": round(elapsed_ms, 3),
            "peak_rss_kib": peak_rss or None,
            "peak_rss_per_sandbox_kib": round(peak_rss / size, 3) if peak_rss else None,
            "failures": failures[:5],
        }
    finally:
        for invocation in invocations:
            invocation.close()


def lifecycle_status(backend: str, host: dict[str, Any]) -> dict[str, Any]:
    if backend == "gvisor":
        return {
            "snapshot": "not_run",
            "restore": "not_run",
            "fork": "not_run",
            "reason": "runsc do is a cold-start probe; checkpoint/restore needs an OCI create path and a privileged or explicitly supported rootless setup",
        }
    if backend == "process":
        return {
            "snapshot": "unsupported",
            "restore": "unsupported",
            "fork": "unsupported",
            "reason": "host process baseline has no sandbox snapshot boundary",
        }
    status = backend_status(backend, host)
    return {
        "snapshot": "blocked",
        "restore": "blocked",
        "fork": "blocked",
        "reason": status.get("reason", "backend unavailable"),
    }


def output_result(result: dict[str, Any], json_output: bool) -> None:
    if json_output:
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    print(f"schema={result['schema']} host={result['host'].get('hostname')}")
    if "backends" in result:
        for name, status in result["backends"].items():
            print(f"{name}: {'available' if status.get('available') else 'blocked'} ({status.get('reason', status.get('mode', ''))})")
    else:
        print(f"backend={result['backend']} command={' '.join(result['command'])}")
        if "cold" in result:
            cold = result["cold"]
            print(f"cold: {cold['successes']}/{cold['iterations']} p50={cold['latency_ms']['p50']}ms p95={cold['latency_ms']['p95']}ms")
        if "density" in result:
            for row in result["density"]:
                print(f"density {row['size']}: peak={row['peak_rss_kib']}KiB ({row['peak_rss_per_sandbox_kib']}KiB/sandbox)")
        print(f"lifecycle: {result['lifecycle']}")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--json", action="store_true", dest="json_output")
    p.add_argument("--runsc", help="path to runsc; defaults to runsc on PATH")
    p.add_argument("--firecracker", help="path to firecracker; defaults to PATH")
    p.add_argument("--cloud-hypervisor", dest="cloud_hypervisor", help="path to cloud-hypervisor; defaults to PATH")
    p.add_argument("--state-dir", default=None, help="temporary state directory")
    sub = p.add_subparsers(dest="subcommand", required=True)
    def common(child: argparse.ArgumentParser) -> None:
        # Suppress these subparser defaults so the same options also work
        # before the subcommand (argparse otherwise overwrites parent values).
        child.add_argument("--json", action="store_true", dest="json_output", default=argparse.SUPPRESS)
        child.add_argument("--runsc", default=argparse.SUPPRESS, help="path to runsc; defaults to runsc on PATH")
        child.add_argument("--firecracker", default=argparse.SUPPRESS, help="path to firecracker; defaults to PATH")
        child.add_argument("--cloud-hypervisor", dest="cloud_hypervisor", default=argparse.SUPPRESS, help="path to cloud-hypervisor; defaults to PATH")
        child.add_argument("--state-dir", default=argparse.SUPPRESS, help="temporary state directory")

    probe = sub.add_parser("probe", help="report host and runtime capabilities")
    common(probe)
    for name in ("cold", "density"):
        child = sub.add_parser(name)
        common(child)
        child.add_argument("--backend", choices=("process", "gvisor", "firecracker", "cloud-hypervisor"), required=True)
        child.add_argument("--iterations", type=int, default=DEFAULT_ITERATIONS)
        child.add_argument("--timeout-s", type=float, default=DEFAULT_TIMEOUT_S)
        child.add_argument("--sizes", default="1,4,8", help="density sizes (density only)")
        child.add_argument("--hold-s", type=float, default=1.0, help="density command hold time")
        child.add_argument(
            "--host-cost-per-hour",
            type=float,
            default=None,
            help="optional host hourly price; density output includes cost per sandbox-hour",
        )
        child.add_argument("command", nargs=argparse.REMAINDER, help="command after --")
    return p


def main(argv: Iterable[str] | None = None) -> int:
    args = parser().parse_args(argv)
    host = host_probe(args.runsc, args.firecracker, args.cloud_hypervisor)
    statuses = {
        name: backend_status(name, host)
        for name in ("process", "gvisor", "firecracker", "cloud-hypervisor")
    }
    if args.subcommand == "probe":
        output_result({"schema": SCHEMA, "host": host, "backends": statuses}, args.json_output)
        return 0
    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        command = ["/bin/true"]
    status = statuses[args.backend]
    if not status["available"]:
        output_result(
            {
                "schema": SCHEMA,
                "host": host,
                "backend": args.backend,
                "command": command,
                "status": status,
                "lifecycle": lifecycle_status(args.backend, host),
            },
            args.json_output,
        )
        return 2
    state_dir = args.state_dir or tempfile.mkdtemp(prefix="sandbox-bench-")
    owns_state = args.state_dir is None
    try:
        result: dict[str, Any] = {
            "schema": SCHEMA,
            "host": host,
            "backend": args.backend,
            "command": command,
            "status": status,
            "lifecycle": lifecycle_status(args.backend, host),
        }
        if args.subcommand == "cold":
            result["cold"] = run_cold(
                args.backend,
                command,
                max(1, args.iterations),
                args.timeout_s,
                status.get("runsc"),
                state_dir,
            )
        else:
            sizes = [int(value) for value in args.sizes.split(",") if value.strip()]
            density_command = command
            if command == ["/bin/true"]:
                density_command = ["/bin/sleep", str(args.hold_s)]
            result["density"] = [
                run_density(
                    args.backend,
                    density_command,
                    max(1, size),
                    args.hold_s,
                    args.timeout_s,
                    status.get("runsc"),
                    state_dir,
                )
                for size in sizes
            ]
            if args.host_cost_per_hour is not None:
                for row in result["density"]:
                    row["host_cost_per_sandbox_hour"] = round(
                        args.host_cost_per_hour / row["size"], 8
                    )
                result["host_cost_per_hour"] = args.host_cost_per_hour
        output_result(result, args.json_output)
        return 0
    finally:
        if owns_state:
            shutil.rmtree(state_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
