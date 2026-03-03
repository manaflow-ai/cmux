#!/usr/bin/env python3
"""
Regression harness: compare typing latency before and after workspace churn.

Scenario A (baseline):
1) Keep only the first workspace.
2) Seed shell history.
3) Measure per-key latency for repeated Up-arrow shortcuts.

Scenario B (churn):
1) Keep only the first workspace.
2) Create N workspaces.
3) Visit every workspace (simulates clicking each tab), then return to the first.
4) Seed shell history.
5) Measure Up-arrow latency again.

The test fails when churn latency regresses too far relative to baseline.
"""

from __future__ import annotations

import os
import select
import socket
import statistics
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmux import cmux, cmuxError

NEW_WORKSPACES = int(os.environ.get("CMUX_LAG_NEW_WORKSPACES", "20"))
SWITCH_PASSES = int(os.environ.get("CMUX_LAG_SWITCH_PASSES", "1"))
SWITCH_DELAY_S = float(os.environ.get("CMUX_LAG_SWITCH_DELAY_S", "0.06"))
HISTORY_SEED_LINES = int(os.environ.get("CMUX_LAG_HISTORY_LINES", "120"))
KEY_EVENTS = int(os.environ.get("CMUX_LAG_KEY_EVENTS", "180"))
KEY_DELAY_S = float(os.environ.get("CMUX_LAG_KEY_DELAY_S", "0.0"))
KEY_COMBO = os.environ.get("CMUX_LAG_KEY_COMBO", "up")

MAX_P95_RATIO = float(os.environ.get("CMUX_LAG_MAX_P95_RATIO", "1.70"))
MAX_AVG_RATIO = float(os.environ.get("CMUX_LAG_MAX_AVG_RATIO", "1.70"))
MAX_CHURN_P95_MS = float(os.environ.get("CMUX_LAG_MAX_CHURN_P95_MS", "35.0"))
MAX_P95_DELTA_MS = float(os.environ.get("CMUX_LAG_MAX_P95_DELTA_MS", "20.0"))
MAX_AVG_DELTA_MS = float(os.environ.get("CMUX_LAG_MAX_AVG_DELTA_MS", "12.0"))
MIN_BASELINE_P95_MS_FOR_RATIO = float(os.environ.get("CMUX_LAG_MIN_BASELINE_P95_MS_FOR_RATIO", "6.0"))
MIN_BASELINE_AVG_MS_FOR_RATIO = float(os.environ.get("CMUX_LAG_MIN_BASELINE_AVG_MS_FOR_RATIO", "4.0"))
MAX_CPU_PERCENT = float(os.environ.get("CMUX_LAG_MAX_CPU_PERCENT", "180.0"))
ENFORCE_CPU = os.environ.get("CMUX_LAG_ENFORCE_CPU", "0") == "1"
ALLOW_MAIN_SOCKET = os.environ.get("CMUX_LAG_ALLOW_MAIN_SOCKET", "0") == "1"


@dataclass
class LatencyStats:
    n: int
    avg_ms: float
    p50_ms: float
    p95_ms: float
    p99_ms: float
    max_ms: float


class RawSocketClient:
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.sock: Optional[socket.socket] = None
        self.recv_buffer = ""

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        sock.connect(self.socket_path)
        self.sock = sock

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def __enter__(self) -> RawSocketClient:
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()

    def command(self, command: str, timeout_s: float = 2.0) -> str:
        if self.sock is None:
            raise cmuxError("Raw socket client not connected")

        self.sock.sendall((command + "\n").encode("utf-8"))
        deadline = time.time() + timeout_s

        while True:
            if "\n" in self.recv_buffer:
                line, self.recv_buffer = self.recv_buffer.split("\n", 1)
                return line

            remaining = deadline - time.time()
            if remaining <= 0:
                raise cmuxError(f"Timed out waiting for response to: {command}")

            ready, _, _ = select.select([self.sock], [], [], remaining)
            if not ready:
                raise cmuxError(f"Timed out waiting for response to: {command}")

            chunk = self.sock.recv(8192)
            if not chunk:
                raise cmuxError("Socket closed while waiting for response")
            self.recv_buffer += chunk.decode("utf-8", errors="replace")


def wait_for(predicate: Callable[[], bool], timeout_s: float, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]
    sorted_values = sorted(values)
    idx = (len(sorted_values) - 1) * p
    lower = int(idx)
    upper = min(lower + 1, len(sorted_values) - 1)
    fraction = idx - lower
    return sorted_values[lower] * (1 - fraction) + sorted_values[upper] * fraction


def compute_stats(values_ms: list[float]) -> LatencyStats:
    return LatencyStats(
        n=len(values_ms),
        avg_ms=statistics.mean(values_ms) if values_ms else 0.0,
        p50_ms=percentile(values_ms, 0.50),
        p95_ms=percentile(values_ms, 0.95),
        p99_ms=percentile(values_ms, 0.99),
        max_ms=max(values_ms) if values_ms else 0.0,
    )


def get_cmux_pid_for_socket(socket_path: Optional[str]) -> Optional[int]:
    if socket_path and os.path.exists(socket_path):
        result = subprocess.run(["lsof", "-t", socket_path], capture_output=True, text=True)
        if result.returncode == 0:
            for line in result.stdout.strip().split("\n"):
                line = line.strip()
                if not line:
                    continue
                try:
                    pid = int(line)
                except ValueError:
                    continue
                if pid != os.getpid():
                    return pid

    result = subprocess.run(
        ["pgrep", "-f", r"cmux DEV.*\.app/Contents/MacOS/cmux DEV"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return int(lines[0]) if lines else None


def resolve_target_socket() -> str:
    socket_path = os.environ.get("CMUX_SOCKET_PATH")
    if not socket_path:
        raise cmuxError(
            "CMUX_SOCKET_PATH is required. Point it to a tagged dev socket (for example /tmp/cmux-debug-<tag>.sock)."
        )
    base = os.path.basename(socket_path)
    if not ALLOW_MAIN_SOCKET and base in {"cmux.sock", "cmux-debug.sock"}:
        raise cmuxError(
            f"Refusing to run against main socket '{socket_path}'. Set CMUX_SOCKET_PATH to a tagged dev instance."
        )
    return socket_path


def get_cpu(pid: int) -> float:
    result = subprocess.run(["ps", "-p", str(pid), "-o", "%cpu="], capture_output=True, text=True)
    if result.returncode != 0:
        return 0.0
    try:
        return float(result.stdout.strip())
    except ValueError:
        return 0.0


class CPUMonitor:
    def __init__(self, pid: int, interval_s: float = 0.2):
        self.pid = pid
        self.interval_s = interval_s
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self.samples: list[float] = []

    def _run(self) -> None:
        while not self._stop.is_set():
            self.samples.append(get_cpu(self.pid))
            time.sleep(self.interval_s)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=2.0)


def keep_only_first_workspace(client: cmux) -> str:
    workspaces = sorted(client.list_workspaces(), key=lambda row: row[0])
    if not workspaces:
        first_id = client.new_workspace()
        client.select_workspace(first_id)
        return first_id

    first_id = workspaces[0][1]
    client.select_workspace(first_id)
    for _index, wid, _title, _selected in reversed(workspaces[1:]):
        if wid == first_id:
            continue
        client.close_workspace(wid)

    def only_first() -> bool:
        current = sorted(client.list_workspaces(), key=lambda row: row[0])
        return len(current) == 1 and current[0][1] == first_id

    wait_for(only_first, timeout_s=6.0)
    return first_id


def create_workspaces(client: cmux, count: int) -> list[str]:
    created: list[str] = []
    for _ in range(count):
        wid = client.new_workspace()
        created.append(wid)
        time.sleep(0.04)
    return created


def cycle_all_workspaces(client: cmux, passes: int, delay_s: float) -> list[str]:
    ids = [wid for _idx, wid, _title, _selected in sorted(client.list_workspaces(), key=lambda row: row[0])]
    for _ in range(passes):
        for wid in ids:
            client.select_workspace(wid)
            time.sleep(delay_s)
    return ids


def focused_terminal_panel(client: cmux) -> str:
    surfaces = client.list_surfaces()
    if not surfaces:
        raise cmuxError("No surfaces available in selected workspace")
    focused = next(((idx, sid) for idx, sid, is_focused in surfaces if is_focused), None)
    if focused is None:
        idx, sid, _ = surfaces[0]
        client.focus_surface(idx)
        return sid
    return focused[1]


def seed_history(client: cmux, lines: int) -> None:
    for i in range(lines):
        client.send_line(f"echo cmux-lag-seed-{i}")


def run_shortcut_latency_burst(
    socket_path: str,
    combo: str,
    count: int,
    delay_s: float,
) -> list[float]:
    latencies_ms: list[float] = []
    with RawSocketClient(socket_path) as raw:
        # Warm up the command path and responder chain.
        for _ in range(5):
            response = raw.command(f"simulate_shortcut {combo}")
            if not response.startswith("OK"):
                raise cmuxError(response)

        for _ in range(count):
            start = time.perf_counter()
            response = raw.command(f"simulate_shortcut {combo}")
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            if not response.startswith("OK"):
                raise cmuxError(response)
            latencies_ms.append(elapsed_ms)
            if delay_s > 0:
                time.sleep(delay_s)

    return latencies_ms


def maybe_write_sample(pid: Optional[int], prefix: str) -> Optional[Path]:
    if pid is None:
        return None
    out = Path(f"/tmp/{prefix}_{pid}.txt")
    result = subprocess.run(["sample", str(pid), "2"], capture_output=True, text=True)
    out.write_text(result.stdout + result.stderr)
    return out


def print_stats(label: str, stats: LatencyStats) -> None:
    print(f"\n{label}")
    print(f"  events:   {stats.n}")
    print(f"  avg_ms:   {stats.avg_ms:.2f}")
    print(f"  p50_ms:   {stats.p50_ms:.2f}")
    print(f"  p95_ms:   {stats.p95_ms:.2f}")
    print(f"  p99_ms:   {stats.p99_ms:.2f}")
    print(f"  max_ms:   {stats.max_ms:.2f}")


def run_baseline_scenario(client: cmux, socket_path: str) -> tuple[str, LatencyStats]:
    first_workspace_id = keep_only_first_workspace(client)
    client.select_workspace(first_workspace_id)
    panel_id = focused_terminal_panel(client)
    seed_history(client, HISTORY_SEED_LINES)
    latencies = run_shortcut_latency_burst(
        socket_path=socket_path,
        combo=KEY_COMBO,
        count=KEY_EVENTS,
        delay_s=KEY_DELAY_S,
    )
    return panel_id, compute_stats(latencies)


def run_churn_scenario(client: cmux, socket_path: str, first_workspace_id: str) -> tuple[str, LatencyStats]:
    first_workspace_id = keep_only_first_workspace(client)
    _ = create_workspaces(client, NEW_WORKSPACES)
    ordered_ids = cycle_all_workspaces(client, SWITCH_PASSES, SWITCH_DELAY_S)

    if first_workspace_id in ordered_ids:
        client.select_workspace(first_workspace_id)
    elif ordered_ids:
        client.select_workspace(ordered_ids[0])

    panel_id = focused_terminal_panel(client)
    seed_history(client, HISTORY_SEED_LINES)
    latencies = run_shortcut_latency_burst(
        socket_path=socket_path,
        combo=KEY_COMBO,
        count=KEY_EVENTS,
        delay_s=KEY_DELAY_S,
    )
    return panel_id, compute_stats(latencies)


def main() -> int:
    print("=" * 64)
    print("Workspace Churn + Up-Arrow Latency Regression")
    print("=" * 64)

    client: Optional[cmux] = None
    pid: Optional[int] = None
    first_workspace_id: Optional[str] = None

    try:
        target_socket = resolve_target_socket()
        client = cmux(socket_path=target_socket)
        client.connect()
        print(f"Using socket: {client.socket_path}")

        pid = get_cmux_pid_for_socket(client.socket_path)
        if pid is None:
            print("SKIP: cmux process not found for socket")
            return 0

        cpu_monitor = CPUMonitor(pid)
        cpu_monitor.start()

        first_workspace_id = keep_only_first_workspace(client)
        baseline_panel_id, baseline = run_baseline_scenario(client, client.socket_path)
        print(f"Baseline panel: {baseline_panel_id}")

        churn_panel_id, churn = run_churn_scenario(client, client.socket_path, first_workspace_id)
        print(f"Churn panel:    {churn_panel_id}")

        cpu_monitor.stop()
        cpu_samples = cpu_monitor.samples
        cpu_avg = statistics.mean(cpu_samples) if cpu_samples else 0.0
        cpu_max = max(cpu_samples) if cpu_samples else 0.0

        print_stats("Baseline", baseline)
        print_stats("After workspace churn", churn)

        p95_ratio = churn.p95_ms / max(baseline.p95_ms, 0.001)
        avg_ratio = churn.avg_ms / max(baseline.avg_ms, 0.001)
        p95_delta_ms = churn.p95_ms - baseline.p95_ms
        avg_delta_ms = churn.avg_ms - baseline.avg_ms
        enforce_p95_ratio = baseline.p95_ms >= MIN_BASELINE_P95_MS_FOR_RATIO
        enforce_avg_ratio = baseline.avg_ms >= MIN_BASELINE_AVG_MS_FOR_RATIO

        print("\nComparison")
        print(
            f"  p95_ratio: {p95_ratio:.2f}x (max {MAX_P95_RATIO:.2f}x, "
            f"enabled when baseline p95 >= {MIN_BASELINE_P95_MS_FOR_RATIO:.2f}ms)"
        )
        print(
            f"  avg_ratio: {avg_ratio:.2f}x (max {MAX_AVG_RATIO:.2f}x, "
            f"enabled when baseline avg >= {MIN_BASELINE_AVG_MS_FOR_RATIO:.2f}ms)"
        )
        print(f"  churn_p95_ms: {churn.p95_ms:.2f} (max {MAX_CHURN_P95_MS:.2f})")
        print(f"  p95_delta_ms: {p95_delta_ms:.2f} (max {MAX_P95_DELTA_MS:.2f})")
        print(f"  avg_delta_ms: {avg_delta_ms:.2f} (max {MAX_AVG_DELTA_MS:.2f})")
        print(f"  cpu_avg_pct: {cpu_avg:.2f}")
        print(f"  cpu_max_pct: {cpu_max:.2f}")

        failures: list[str] = []
        if enforce_p95_ratio and p95_ratio > MAX_P95_RATIO:
            failures.append(f"p95 ratio {p95_ratio:.2f}x > {MAX_P95_RATIO:.2f}x")
        if enforce_avg_ratio and avg_ratio > MAX_AVG_RATIO:
            failures.append(f"avg ratio {avg_ratio:.2f}x > {MAX_AVG_RATIO:.2f}x")
        if p95_delta_ms > MAX_P95_DELTA_MS:
            failures.append(f"p95 delta {p95_delta_ms:.2f}ms > {MAX_P95_DELTA_MS:.2f}ms")
        if avg_delta_ms > MAX_AVG_DELTA_MS:
            failures.append(f"avg delta {avg_delta_ms:.2f}ms > {MAX_AVG_DELTA_MS:.2f}ms")
        if churn.p95_ms > MAX_CHURN_P95_MS:
            failures.append(f"churn p95 {churn.p95_ms:.2f}ms > {MAX_CHURN_P95_MS:.2f}ms")
        if ENFORCE_CPU and cpu_max > MAX_CPU_PERCENT:
            failures.append(f"cpu max {cpu_max:.2f}% > {MAX_CPU_PERCENT:.2f}%")

        if failures:
            print("\nFAIL")
            for item in failures:
                print(f"  - {item}")
            sample_path = maybe_write_sample(pid, "cmux_workspace_churn_up_arrow_lag")
            if sample_path:
                print(f"  sample_path: {sample_path}")
            return 1

        print("\nPASS")
        return 0

    except cmuxError as e:
        print(f"FAIL: {e}")
        sample_path = maybe_write_sample(pid, "cmux_workspace_churn_up_arrow_error")
        if sample_path:
            print(f"sample_path: {sample_path}")
        return 1

    finally:
        if client is not None:
            try:
                if first_workspace_id:
                    client.select_workspace(first_workspace_id)
                    keep_only_first_workspace(client)
            except Exception:
                pass
            client.close()


if __name__ == "__main__":
    raise SystemExit(main())
