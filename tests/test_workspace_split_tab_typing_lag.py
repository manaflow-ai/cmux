#!/usr/bin/env python3
"""
Regression harness: load many workspaces, splits, and Bonsplit tabs, then type
into every visible terminal and compare typing latency against a clean baseline.

The stress workload only counts a surface once it is actually visible:
1) its workspace is selected,
2) its tab is the selected tab in its pane,
3) the terminal is focused,
4) a panel snapshot shows visible pixel changes after typing.
"""

from __future__ import annotations

import os
import select
import socket
import statistics
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmux import cmux, cmuxError

TOTAL_WORKSPACES = int(os.environ.get("CMUX_TYPING_LAG_TOTAL_WORKSPACES", "6"))
PANES_PER_WORKSPACE = int(os.environ.get("CMUX_TYPING_LAG_PANES_PER_WORKSPACE", "4"))
TABS_PER_PANE = int(os.environ.get("CMUX_TYPING_LAG_TABS_PER_PANE", "4"))
BASELINE_TOKEN_COUNT = int(os.environ.get("CMUX_TYPING_LAG_BASELINE_TOKEN_COUNT", "8"))
TOKEN_LENGTH = int(os.environ.get("CMUX_TYPING_LAG_TOKEN_LENGTH", "4"))
FOCUS_DELAY_S = float(os.environ.get("CMUX_TYPING_LAG_FOCUS_DELAY_S", "0.05"))
SETUP_DELAY_S = float(os.environ.get("CMUX_TYPING_LAG_SETUP_DELAY_S", "0.08"))
MIN_CHANGED_PIXELS = int(os.environ.get("CMUX_TYPING_LAG_MIN_CHANGED_PIXELS", "20"))

MAX_SHORTCUT_P95_RATIO = float(os.environ.get("CMUX_TYPING_LAG_MAX_SHORTCUT_P95_RATIO", "1.55"))
MAX_SHORTCUT_AVG_RATIO = float(os.environ.get("CMUX_TYPING_LAG_MAX_SHORTCUT_AVG_RATIO", "1.45"))
MAX_SHORTCUT_P95_DELTA_MS = float(os.environ.get("CMUX_TYPING_LAG_MAX_SHORTCUT_P95_DELTA_MS", "35.0"))
MAX_SHORTCUT_AVG_DELTA_MS = float(os.environ.get("CMUX_TYPING_LAG_MAX_SHORTCUT_AVG_DELTA_MS", "20.0"))
MAX_VISIBLE_P95_RATIO = float(os.environ.get("CMUX_TYPING_LAG_MAX_VISIBLE_P95_RATIO", "1.80"))
MAX_VISIBLE_P95_DELTA_MS = float(os.environ.get("CMUX_TYPING_LAG_MAX_VISIBLE_P95_DELTA_MS", "450.0"))
MAX_VISIBLE_P95_MS = float(os.environ.get("CMUX_TYPING_LAG_MAX_VISIBLE_P95_MS", "1500.0"))
MIN_BASELINE_SHORTCUT_P95_MS_FOR_RATIO = float(
    os.environ.get("CMUX_TYPING_LAG_MIN_BASELINE_SHORTCUT_P95_MS_FOR_RATIO", "20.0")
)
MIN_BASELINE_SHORTCUT_AVG_MS_FOR_RATIO = float(
    os.environ.get("CMUX_TYPING_LAG_MIN_BASELINE_SHORTCUT_AVG_MS_FOR_RATIO", "15.0")
)
MIN_BASELINE_VISIBLE_P95_MS_FOR_RATIO = float(
    os.environ.get("CMUX_TYPING_LAG_MIN_BASELINE_VISIBLE_P95_MS_FOR_RATIO", "80.0")
)

ALLOW_MAIN_SOCKET = os.environ.get("CMUX_TYPING_LAG_ALLOW_MAIN_SOCKET", "0") == "1"
CAPTURE_SAMPLE_ON_FAILURE = os.environ.get("CMUX_TYPING_LAG_CAPTURE_SAMPLE_ON_FAILURE", "1") == "1"


@dataclass
class LatencyStats:
    n: int
    avg_ms: float
    p50_ms: float
    p95_ms: float
    p99_ms: float
    max_ms: float


@dataclass
class SurfaceTarget:
    workspace_id: str
    pane_id: str
    panel_id: str


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


def print_stats(label: str, stats: LatencyStats) -> None:
    print(f"\n{label}")
    print(f"  events:   {stats.n}")
    print(f"  avg_ms:   {stats.avg_ms:.2f}")
    print(f"  p50_ms:   {stats.p50_ms:.2f}")
    print(f"  p95_ms:   {stats.p95_ms:.2f}")
    print(f"  p99_ms:   {stats.p99_ms:.2f}")
    print(f"  max_ms:   {stats.max_ms:.2f}")


def resolve_target_socket() -> str:
    socket_path = os.environ.get("CMUX_SOCKET") or os.environ.get("CMUX_SOCKET_PATH")
    if not socket_path:
        raise cmuxError(
            "CMUX_SOCKET or CMUX_SOCKET_PATH is required. Point it to a tagged dev socket "
            "(for example /tmp/cmux-debug-<tag>.sock)."
        )
    base = os.path.basename(socket_path)
    if not ALLOW_MAIN_SOCKET and base in {"cmux.sock", "cmux-debug.sock"}:
        raise cmuxError(
            f"Refusing to run against main socket '{socket_path}'. Point the test at a tagged dev instance."
        )
    return socket_path


def get_cmux_pid_for_socket(socket_path: str) -> Optional[int]:
    if os.path.exists(socket_path):
        result = subprocess.run(["lsof", "-t", socket_path], capture_output=True, text=True)
        if result.returncode == 0:
            for line in result.stdout.strip().splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    pid = int(line)
                except ValueError:
                    continue
                if pid != os.getpid():
                    return pid
    return None


def maybe_write_sample(pid: Optional[int], prefix: str) -> Optional[Path]:
    if pid is None:
        return None
    out = Path(f"/tmp/{prefix}_{pid}.txt")
    result = subprocess.run(["sample", str(pid), "2"], capture_output=True, text=True)
    out.write_text(result.stdout + result.stderr)
    return out


def current_selected_panel_id(client: cmux, pane_id: str) -> Optional[str]:
    for _index, panel_id, _title, is_selected in client.list_pane_surfaces(pane_id):
        if is_selected:
            return panel_id
    return None


def render_present_count(client: cmux, panel_id: str) -> int:
    return int(client.render_stats(panel_id).get("presentCount", 0) or 0)


def panel_is_selected_in_pane(client: cmux, pane_id: str, panel_id: str) -> bool:
    return current_selected_panel_id(client, pane_id) == panel_id


def wait_for_visible_terminal(client: cmux, target: SurfaceTarget) -> None:
    def predicate() -> bool:
        if client.current_workspace() != target.workspace_id:
            return False
        if not panel_is_selected_in_pane(client, target.pane_id, target.panel_id):
            return False
        if not client.is_terminal_focused(target.panel_id):
            return False
        return render_present_count(client, target.panel_id) > 0

    wait_for(predicate, timeout_s=8.0)


def reset_to_fresh_workspace(client: cmux) -> str:
    fresh_id = client.new_workspace()
    client.select_workspace(fresh_id)
    time.sleep(0.20)

    for _index, wid, _title, _selected in reversed(client.list_workspaces()):
        if wid == fresh_id:
            continue
        client.close_workspace(wid)

    def only_fresh() -> bool:
        workspaces = client.list_workspaces()
        return len(workspaces) == 1 and workspaces[0][1] == fresh_id and workspaces[0][3]

    wait_for(only_fresh, timeout_s=8.0)
    return fresh_id


def build_workspace_grid(client: cmux) -> list[str]:
    panes = client.list_panes()
    if len(panes) != 1:
        raise cmuxError(f"Expected a fresh workspace with 1 pane, got {panes}")

    client.new_pane("right")
    time.sleep(SETUP_DELAY_S)

    client.focus_pane(0)
    time.sleep(FOCUS_DELAY_S)
    client.new_pane("down")
    time.sleep(SETUP_DELAY_S)

    client.focus_pane(1)
    time.sleep(FOCUS_DELAY_S)
    client.new_pane("down")
    time.sleep(SETUP_DELAY_S)

    wait_for(lambda: len(client.list_panes()) == PANES_PER_WORKSPACE, timeout_s=8.0)
    return [pane_id for _index, pane_id, _surface_count, _focused in client.list_panes()]


def create_surface_targets(client: cmux, total_workspaces: int) -> list[SurfaceTarget]:
    fresh_id = reset_to_fresh_workspace(client)
    targets: list[SurfaceTarget] = []

    for workspace_index in range(total_workspaces):
        if workspace_index == 0:
            workspace_id = fresh_id
            client.select_workspace(workspace_id)
        else:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
        time.sleep(SETUP_DELAY_S)

        pane_ids = build_workspace_grid(client)
        workspace_targets: list[SurfaceTarget] = []

        for pane_id in pane_ids:
            surfaces = client.list_pane_surfaces(pane_id)
            while len(surfaces) < TABS_PER_PANE:
                client.new_surface(pane=pane_id, panel_type="terminal")
                time.sleep(SETUP_DELAY_S)
                surfaces = client.list_pane_surfaces(pane_id)

            workspace_targets.extend(
                SurfaceTarget(workspace_id=workspace_id, pane_id=pane_id, panel_id=panel_id)
                for _index, panel_id, _title, _selected in surfaces
            )

        targets.extend(workspace_targets)
        print(
            f"  workspace {workspace_index + 1}/{total_workspaces}: "
            f"panes={len(pane_ids)} targets={len(workspace_targets)}"
        )

    return targets


def make_token(prefix: str) -> str:
    if TOKEN_LENGTH <= 1:
        return prefix[:1]
    suffix = uuid.uuid4().hex[: max(1, TOKEN_LENGTH - len(prefix))]
    token = (prefix + suffix)[:TOKEN_LENGTH]
    if len(token) < TOKEN_LENGTH:
        token = (token + uuid.uuid4().hex)[:TOKEN_LENGTH]
    return token


def panel_snapshot_retry(
    client: cmux,
    panel_id: str,
    label: str,
    timeout_s: float = 3.0,
) -> dict:
    start = time.time()
    last_err: Exception | None = None
    while time.time() - start < timeout_s:
        try:
            return dict(client.panel_snapshot(panel_id, label) or {})
        except Exception as exc:
            last_err = exc
            if "Failed to capture panel image" not in str(exc):
                raise
            time.sleep(0.05)
    raise cmuxError(
        f"Timed out waiting for panel_snapshot: panel_id={panel_id} label={label}: {last_err!r}"
    )


def type_token_into_visible_terminal(
    client: cmux,
    raw: RawSocketClient,
    target: SurfaceTarget,
    token: str,
    snapshot_label: str,
) -> tuple[list[float], float, int]:
    client.select_workspace(target.workspace_id)
    wait_for(lambda: client.current_workspace() == target.workspace_id, timeout_s=4.0)
    time.sleep(FOCUS_DELAY_S)

    def focus_target() -> None:
        client.focus_pane(target.pane_id)
        time.sleep(FOCUS_DELAY_S)
        client.focus_surface_by_panel(target.panel_id)
        time.sleep(FOCUS_DELAY_S)

    focus_target()
    try:
        wait_for_visible_terminal(client, target)
    except cmuxError:
        client.activate_app()
        time.sleep(FOCUS_DELAY_S)
        focus_target()
        wait_for_visible_terminal(client, target)

    client.panel_snapshot_reset(target.panel_id)
    panel_snapshot_retry(client, target.panel_id, f"{snapshot_label}_before")

    shortcut_latencies_ms: list[float] = []
    visible_start = time.perf_counter()
    for ch in token:
        start = time.perf_counter()
        response = raw.command(f"simulate_shortcut {ch}")
        if not response.startswith("OK"):
            raise cmuxError(response)
        shortcut_latencies_ms.append((time.perf_counter() - start) * 1000.0)

    last_tail = ""

    def token_visible() -> bool:
        nonlocal last_tail
        text = client.read_terminal_text(target.panel_id)
        last_tail = text[-200:]
        return token in last_tail

    try:
        wait_for(token_visible, timeout_s=3.5)
    except cmuxError:
        client.activate_app()
        time.sleep(FOCUS_DELAY_S)
        focus_target()
        wait_for_visible_terminal(client, target)
        try:
            wait_for(token_visible, timeout_s=2.0)
        except cmuxError as exc:
            raise cmuxError(
                "Timed out waiting for typed token to appear in terminal text.\n"
                f"workspace={target.workspace_id} pane={target.pane_id} panel={target.panel_id}\n"
                f"token={token} last_tail={last_tail!r}"
            ) from exc

    visible_ms = (time.perf_counter() - visible_start) * 1000.0

    snapshot = panel_snapshot_retry(client, target.panel_id, f"{snapshot_label}_after")
    changed_pixels = int(snapshot.get("changed_pixels", -1))
    if changed_pixels < MIN_CHANGED_PIXELS:
        raise cmuxError(
            "Expected terminal pixels to change after typing while the tab was selected.\n"
            f"workspace={target.workspace_id} pane={target.pane_id} panel={target.panel_id}\n"
            f"token={token} changed_pixels={changed_pixels} min_pixels={MIN_CHANGED_PIXELS}\n"
            f"snapshot_path={snapshot.get('path')}"
        )

    return shortcut_latencies_ms, visible_ms, changed_pixels


def run_baseline_scenario(client: cmux, raw: RawSocketClient) -> tuple[LatencyStats, LatencyStats, str]:
    workspace_id = reset_to_fresh_workspace(client)
    surfaces = client.list_surfaces()
    if not surfaces:
        raise cmuxError("Expected at least one terminal in the fresh baseline workspace")

    panel_id = next((panel_id for _index, panel_id, focused in surfaces if focused), surfaces[0][1])
    panes = client.list_panes()
    if len(panes) != 1:
        raise cmuxError(f"Expected 1 pane in baseline workspace, got {panes}")
    target = SurfaceTarget(workspace_id=workspace_id, pane_id=panes[0][1], panel_id=panel_id)

    shortcut_latencies_ms: list[float] = []
    visible_latencies_ms: list[float] = []

    for baseline_index in range(BASELINE_TOKEN_COUNT):
        token = make_token("b")
        token_shortcuts, visible_ms, _changed_pixels = type_token_into_visible_terminal(
            client=client,
            raw=raw,
            target=target,
            token=token,
            snapshot_label=f"baseline_{baseline_index}",
        )
        shortcut_latencies_ms.extend(token_shortcuts)
        visible_latencies_ms.append(visible_ms)

    return (
        compute_stats(shortcut_latencies_ms),
        compute_stats(visible_latencies_ms),
        panel_id,
    )


def run_stress_scenario(
    client: cmux,
    raw: RawSocketClient,
    targets: list[SurfaceTarget],
) -> tuple[LatencyStats, LatencyStats, list[str]]:
    shortcut_latencies_ms: list[float] = []
    visible_latencies_ms: list[float] = []
    failures: list[str] = []

    for index, target in enumerate(targets, start=1):
        token = make_token("z")
        try:
            token_shortcuts, visible_ms, changed_pixels = type_token_into_visible_terminal(
                client=client,
                raw=raw,
                target=target,
                token=token,
                snapshot_label=f"stress_{index}",
            )
        except Exception as exc:
            failures.append(
                f"target {index}/{len(targets)} workspace={target.workspace_id} "
                f"pane={target.pane_id} panel={target.panel_id}: {exc}"
            )
            continue

        shortcut_latencies_ms.extend(token_shortcuts)
        visible_latencies_ms.append(visible_ms)

        if index % 12 == 0 or index == len(targets):
            print(
                f"  typed {index}/{len(targets)} terminals, "
                f"last_visible_ms={visible_ms:.2f}, last_changed_pixels={changed_pixels}"
            )

    return compute_stats(shortcut_latencies_ms), compute_stats(visible_latencies_ms), failures


def main() -> int:
    print("=" * 64)
    print("Workspace + Split + Bonsplit Tab Typing Lag Regression")
    print("=" * 64)

    target_socket = resolve_target_socket()
    client: Optional[cmux] = None
    sample_path: Optional[Path] = None
    pid: Optional[int] = None

    try:
        client = cmux(socket_path=target_socket)
        client.connect()
        print(f"Using socket: {client.socket_path}")

        pid = get_cmux_pid_for_socket(client.socket_path)
        if pid is None:
            print("SKIP: cmux process not found for socket")
            return 0

        with RawSocketClient(client.socket_path) as raw:
            baseline_shortcuts, baseline_visible, baseline_panel_id = run_baseline_scenario(client, raw)
            print(f"Baseline panel: {baseline_panel_id}")

            targets = create_surface_targets(client, TOTAL_WORKSPACES)
            print(f"Stress targets: {len(targets)} terminals")

            stress_shortcuts, stress_visible, failures = run_stress_scenario(client, raw, targets)

        print_stats("Baseline shortcut latency", baseline_shortcuts)
        print_stats("Stress shortcut latency", stress_shortcuts)
        print_stats("Baseline visible typing latency", baseline_visible)
        print_stats("Stress visible typing latency", stress_visible)

        shortcut_p95_ratio = stress_shortcuts.p95_ms / max(baseline_shortcuts.p95_ms, 0.001)
        shortcut_avg_ratio = stress_shortcuts.avg_ms / max(baseline_shortcuts.avg_ms, 0.001)
        shortcut_p95_delta_ms = stress_shortcuts.p95_ms - baseline_shortcuts.p95_ms
        shortcut_avg_delta_ms = stress_shortcuts.avg_ms - baseline_shortcuts.avg_ms
        visible_p95_ratio = stress_visible.p95_ms / max(baseline_visible.p95_ms, 0.001)
        visible_p95_delta_ms = stress_visible.p95_ms - baseline_visible.p95_ms

        enforce_shortcut_p95_ratio = baseline_shortcuts.p95_ms >= MIN_BASELINE_SHORTCUT_P95_MS_FOR_RATIO
        enforce_shortcut_avg_ratio = baseline_shortcuts.avg_ms >= MIN_BASELINE_SHORTCUT_AVG_MS_FOR_RATIO
        enforce_visible_p95_ratio = baseline_visible.p95_ms >= MIN_BASELINE_VISIBLE_P95_MS_FOR_RATIO

        print("\nComparison")
        print(
            f"  shortcut_p95_ratio: {shortcut_p95_ratio:.2f}x "
            f"(max {MAX_SHORTCUT_P95_RATIO:.2f}x, enabled when baseline p95 >= "
            f"{MIN_BASELINE_SHORTCUT_P95_MS_FOR_RATIO:.2f}ms)"
        )
        print(
            f"  shortcut_avg_ratio: {shortcut_avg_ratio:.2f}x "
            f"(max {MAX_SHORTCUT_AVG_RATIO:.2f}x, enabled when baseline avg >= "
            f"{MIN_BASELINE_SHORTCUT_AVG_MS_FOR_RATIO:.2f}ms)"
        )
        print(
            f"  shortcut_p95_delta_ms: {shortcut_p95_delta_ms:.2f} "
            f"(max {MAX_SHORTCUT_P95_DELTA_MS:.2f})"
        )
        print(
            f"  shortcut_avg_delta_ms: {shortcut_avg_delta_ms:.2f} "
            f"(max {MAX_SHORTCUT_AVG_DELTA_MS:.2f})"
        )
        print(
            f"  visible_p95_ratio: {visible_p95_ratio:.2f}x "
            f"(max {MAX_VISIBLE_P95_RATIO:.2f}x, enabled when baseline p95 >= "
            f"{MIN_BASELINE_VISIBLE_P95_MS_FOR_RATIO:.2f}ms)"
        )
        print(
            f"  visible_p95_delta_ms: {visible_p95_delta_ms:.2f} "
            f"(max {MAX_VISIBLE_P95_DELTA_MS:.2f})"
        )
        print(f"  stress_visible_p95_ms: {stress_visible.p95_ms:.2f} (max {MAX_VISIBLE_P95_MS:.2f})")
        print(f"  typing_failures: {len(failures)}")

        regressions: list[str] = []
        if failures:
            regressions.append(f"{len(failures)} terminals failed visibility or typing checks")
        if enforce_shortcut_p95_ratio and shortcut_p95_ratio > MAX_SHORTCUT_P95_RATIO:
            regressions.append(f"shortcut p95 ratio {shortcut_p95_ratio:.2f}x > {MAX_SHORTCUT_P95_RATIO:.2f}x")
        if enforce_shortcut_avg_ratio and shortcut_avg_ratio > MAX_SHORTCUT_AVG_RATIO:
            regressions.append(f"shortcut avg ratio {shortcut_avg_ratio:.2f}x > {MAX_SHORTCUT_AVG_RATIO:.2f}x")
        if shortcut_p95_delta_ms > MAX_SHORTCUT_P95_DELTA_MS:
            regressions.append(
                f"shortcut p95 delta {shortcut_p95_delta_ms:.2f}ms > {MAX_SHORTCUT_P95_DELTA_MS:.2f}ms"
            )
        if shortcut_avg_delta_ms > MAX_SHORTCUT_AVG_DELTA_MS:
            regressions.append(
                f"shortcut avg delta {shortcut_avg_delta_ms:.2f}ms > {MAX_SHORTCUT_AVG_DELTA_MS:.2f}ms"
            )
        if enforce_visible_p95_ratio and visible_p95_ratio > MAX_VISIBLE_P95_RATIO:
            regressions.append(f"visible p95 ratio {visible_p95_ratio:.2f}x > {MAX_VISIBLE_P95_RATIO:.2f}x")
        if visible_p95_delta_ms > MAX_VISIBLE_P95_DELTA_MS:
            regressions.append(
                f"visible p95 delta {visible_p95_delta_ms:.2f}ms > {MAX_VISIBLE_P95_DELTA_MS:.2f}ms"
            )
        if stress_visible.p95_ms > MAX_VISIBLE_P95_MS:
            regressions.append(f"stress visible p95 {stress_visible.p95_ms:.2f}ms > {MAX_VISIBLE_P95_MS:.2f}ms")

        if regressions:
            print("\nFAIL")
            for item in regressions:
                print(f"  - {item}")
            for item in failures[:12]:
                print(f"  - {item}")
            if CAPTURE_SAMPLE_ON_FAILURE:
                sample_path = maybe_write_sample(pid, "cmux_workspace_split_tab_typing_lag")
                if sample_path is not None:
                    print(f"  - sample: {sample_path}")
            return 1

        print("\nPASS: typing stayed responsive across visible workspace/split/tab churn")
        return 0
    finally:
        if client is not None:
            try:
                reset_to_fresh_workspace(client)
            except Exception:
                pass
            client.close()


if __name__ == "__main__":
    raise SystemExit(main())
