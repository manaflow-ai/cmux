#!/usr/bin/env python3
"""
Two-minute Task Manager memory leak guard.

This exercises the leak class fixed for 0.64.8: Task Manager refreshes mutate a
snapshot every three seconds while a lazy row tree is rendered. If rows miss the
snapshot boundary/equatable cache, repeated refreshes produce sustained app RSS
growth. The detector self-check below proves the guard rejects that growth shape.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import plistlib
import socket
import statistics
import subprocess
import sys
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


DEFAULT_DURATION_SECONDS = 120.0
DEFAULT_SAMPLE_INTERVAL_SECONDS = 3.0
DEFAULT_WARMUP_SECONDS = 15.0
DEFAULT_WORKSPACE_COUNT = 10
DEFAULT_MAX_GROWTH_MB = 128.0
DEFAULT_MAX_SLOPE_MB_PER_MIN = 64.0


@dataclass(frozen=True)
class MemorySample:
    elapsed_seconds: float
    rss_bytes: int


@dataclass(frozen=True)
class TrendResult:
    failed: bool
    reason: str
    baseline_mb: float
    final_mb: float
    growth_mb: float
    slope_mb_per_min: float
    peak_mb: float
    sample_count: int


class SocketClient:
    def __init__(self, path: str, response_timeout: float = 5.0) -> None:
        self.path = path
        self.response_timeout = response_timeout

    def send_line(self, line: str) -> str:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(self.response_timeout)
            sock.connect(self.path)
            sock.sendall((line + "\n").encode("utf-8"))
            chunks: list[bytes] = []
            while True:
                chunk = sock.recv(1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
                if len(chunk) < 1024 * 1024:
                    break
        return b"".join(chunks).decode("utf-8", errors="replace").strip()

    def v2(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        frame = {
            "id": str(uuid.uuid4()),
            "method": method,
            "params": params or {},
        }
        raw = self.send_line(json.dumps(frame, separators=(",", ":")))
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"{method} returned invalid JSON: {raw!r}") from exc
        if not payload.get("ok"):
            raise RuntimeError(f"{method} failed: {payload}")
        result = payload.get("result")
        return result if isinstance(result, dict) else {}


def resolve_app_path(explicit: str | None) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    for key in ("CMUX_MEMORY_GUARD_APP", "CMUX_APP_PATH"):
        value = os.environ.get(key)
        if value:
            candidates.append(Path(value).expanduser())
    candidates.extend(Path.cwd().glob("build-memory-leak/Build/Products/Debug/cmux DEV.app"))
    candidates.extend(Path.cwd().glob("build*/Build/Products/Debug/cmux DEV.app"))
    candidates.extend(Path.home().glob("Library/Developer/Xcode/DerivedData/cmux-*/Build/Products/Debug/cmux DEV*.app"))

    existing = [path for path in candidates if path.exists()]
    if not existing:
        raise RuntimeError("Unable to find built cmux app. Pass --app or set CMUX_APP_PATH.")
    existing.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    return existing[0]


def executable_for_app(app_path: Path) -> Path:
    if app_path.suffix != ".app":
        if os.access(app_path, os.X_OK):
            return app_path
        raise RuntimeError(f"{app_path} is not an executable or .app bundle")

    plist_path = app_path / "Contents" / "Info.plist"
    with plist_path.open("rb") as handle:
        info = plistlib.load(handle)
    executable_name = info.get("CFBundleExecutable")
    if not executable_name:
        raise RuntimeError(f"{plist_path} is missing CFBundleExecutable")
    executable = app_path / "Contents" / "MacOS" / str(executable_name)
    if not executable.exists():
        raise RuntimeError(f"App executable not found at {executable}")
    return executable


def launch_app(app_path: Path, socket_path: str, cmuxd_socket: str, log_path: str, tag: str) -> subprocess.Popen[str]:
    executable = executable_for_app(app_path)
    env = dict(os.environ)
    for key in (
        "CMUX_SOCKET",
        "CMUX_SOCKET_PATH",
        "CMUX_SOCKET_PASSWORD",
        "CMUX_SOCKET_MODE",
        "CMUX_TAB_ID",
        "CMUX_PANEL_ID",
        "CMUX_SURFACE_ID",
        "CMUX_WORKSPACE_ID",
        "CMUXD_UNIX_PATH",
        "CMUX_DEBUG_LOG",
    ):
        env.pop(key, None)

    env.update(
        {
            "CMUX_UI_TEST_MODE": "1",
            "CMUX_SOCKET_MODE": "allowAll",
            "CMUX_SOCKET_PATH": socket_path,
            "CMUXD_UNIX_PATH": cmuxd_socket,
            "CMUX_DISABLE_SESSION_RESTORE": "1",
            "CMUX_DEBUG_LOG": log_path,
            "CMUX_TAG": tag,
        }
    )
    args = [
        str(executable),
        "-AppleLanguages",
        "(en)",
        "-AppleLocale",
        "en_US",
        "-ApplePersistenceIgnoreState",
        "YES",
        "-NSQuitAlwaysKeepsWindows",
        "NO",
        "-menuBarOnly",
        "false",
    ]
    return subprocess.Popen(
        args,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
        text=True,
    )


def wait_for_socket(client: SocketClient, proc: subprocess.Popen[str], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    last_error = ""
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"cmux exited before socket became ready, exit={proc.returncode}")
        try:
            if client.send_line("ping") == "PONG":
                return
        except OSError as exc:
            last_error = str(exc)
        time.sleep(0.1)
    raise RuntimeError(f"socket did not answer ping at {client.path}: {last_error}")


def terminal_surface(name: str) -> dict[str, Any]:
    return {"type": "terminal", "name": name}


def pane(name: str) -> dict[str, Any]:
    return {
        "pane": {
            "surfaces": [
                terminal_surface(f"{name}-a"),
                terminal_surface(f"{name}-b"),
            ]
        }
    }


def four_pane_layout(prefix: str) -> dict[str, Any]:
    return {
        "direction": "horizontal",
        "children": [
            {
                "direction": "vertical",
                "children": [
                    pane(f"{prefix}-tl"),
                    pane(f"{prefix}-bl"),
                ],
            },
            {
                "direction": "vertical",
                "children": [
                    pane(f"{prefix}-tr"),
                    pane(f"{prefix}-br"),
                ],
            },
        ],
    }


def seed_workspaces(client: SocketClient, count: int) -> list[str]:
    workspace_ids: list[str] = []
    for index in range(count):
        result = client.v2(
            "workspace.create",
            {
                "title": f"Memory Guard {index + 1:02d}",
                "focus": False,
                "layout": four_pane_layout(f"mem-{index + 1:02d}"),
            },
        )
        workspace_id = result.get("workspace_id")
        if isinstance(workspace_id, str):
            workspace_ids.append(workspace_id)
    if len(workspace_ids) != count:
        raise RuntimeError(f"created {len(workspace_ids)} workspaces, expected {count}")
    return workspace_ids


def rss_bytes(pid: int) -> int:
    result = subprocess.run(
        ["/bin/ps", "-o", "rss=", "-p", str(pid)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ps failed for pid {pid}: {result.stderr.strip()}")
    text = result.stdout.strip()
    if not text:
        raise RuntimeError(f"ps returned no RSS for pid {pid}")
    return int(text.splitlines()[-1].strip()) * 1024


def collect_samples(pid: int, duration: float, interval: float) -> list[MemorySample]:
    samples: list[MemorySample] = []
    started = time.monotonic()
    next_sample = started
    while True:
        now = time.monotonic()
        if now < next_sample:
            time.sleep(next_sample - now)
            continue
        elapsed = time.monotonic() - started
        samples.append(MemorySample(elapsed_seconds=elapsed, rss_bytes=rss_bytes(pid)))
        if elapsed >= duration:
            return samples
        next_sample += interval


def median_mb(values: list[int]) -> float:
    return statistics.median(values) / (1024 * 1024)


def slope_mb_per_minute(samples: list[MemorySample]) -> float:
    if len(samples) < 2:
        return 0.0
    xs = [sample.elapsed_seconds / 60.0 for sample in samples]
    ys = [sample.rss_bytes / (1024 * 1024) for sample in samples]
    mean_x = statistics.mean(xs)
    mean_y = statistics.mean(ys)
    denominator = sum((x - mean_x) ** 2 for x in xs)
    if denominator <= 0:
        return 0.0
    return sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys)) / denominator


def classify_trend(samples: list[MemorySample], max_growth_mb: float, max_slope_mb_per_min: float) -> TrendResult:
    if len(samples) < 8:
        return TrendResult(
            failed=True,
            reason=f"not enough samples ({len(samples)} < 8)",
            baseline_mb=0,
            final_mb=0,
            growth_mb=0,
            slope_mb_per_min=0,
            peak_mb=0,
            sample_count=len(samples),
        )

    window = min(5, max(2, len(samples) // 5))
    baseline_mb = median_mb([sample.rss_bytes for sample in samples[:window]])
    final_mb = median_mb([sample.rss_bytes for sample in samples[-window:]])
    growth_mb = final_mb - baseline_mb
    slope = slope_mb_per_minute(samples)
    peak_mb = max(sample.rss_bytes for sample in samples) / (1024 * 1024)

    reasons: list[str] = []
    if growth_mb > max_growth_mb:
        reasons.append(f"growth {growth_mb:.1f} MB > {max_growth_mb:.1f} MB")
    if slope > max_slope_mb_per_min and growth_mb > max_growth_mb * 0.5:
        reasons.append(f"slope {slope:.1f} MB/min > {max_slope_mb_per_min:.1f} MB/min")
    failed = bool(reasons)
    return TrendResult(
        failed=failed,
        reason="; ".join(reasons) if reasons else "within memory growth limits",
        baseline_mb=baseline_mb,
        final_mb=final_mb,
        growth_mb=growth_mb,
        slope_mb_per_min=slope,
        peak_mb=peak_mb,
        sample_count=len(samples),
    )


def detector_self_check(max_growth_mb: float, max_slope_mb_per_min: float) -> None:
    stable = [
        MemorySample(elapsed_seconds=float(index * 3), rss_bytes=int((620 + math.sin(index / 2) * 3) * 1024 * 1024))
        for index in range(41)
    ]
    stable_result = classify_trend(stable, max_growth_mb, max_slope_mb_per_min)
    if stable_result.failed:
        raise RuntimeError(f"detector rejected stable synthetic trend: {stable_result}")

    leak = [
        MemorySample(elapsed_seconds=float(index * 3), rss_bytes=int((620 + index * 5.0) * 1024 * 1024))
        for index in range(41)
    ]
    leak_result = classify_trend(leak, max_growth_mb, max_slope_mb_per_min)
    if not leak_result.failed:
        raise RuntimeError(f"detector failed to reject synthetic leak trend: {leak_result}")
    print(
        "PASS: detector rejects leak-shaped growth "
        f"(synthetic growth={leak_result.growth_mb:.1f} MB, slope={leak_result.slope_mb_per_min:.1f} MB/min)"
    )


def write_artifacts(artifacts_dir: Path | None, samples: list[MemorySample], trend: TrendResult) -> None:
    if artifacts_dir is None:
        return
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    (artifacts_dir / "task-manager-memory-samples.json").write_text(
        json.dumps(
            {
                "trend": asdict(trend),
                "samples": [asdict(sample) for sample in samples],
            },
            indent=2,
            sort_keys=True,
        ),
        encoding="utf-8",
    )


def tail_file(path: Path, line_count: int = 80) -> str:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        return ""
    return "\n".join(lines[-line_count:])


def run_guard(args: argparse.Namespace) -> int:
    detector_self_check(args.max_growth_mb, args.max_slope_mb_per_min)

    app_path = resolve_app_path(args.app)
    run_id = uuid.uuid4().hex[:8]
    tag = f"memci-{run_id}"
    socket_path = f"/tmp/cmux-memory-guard-{run_id}.sock"
    cmuxd_socket = f"/tmp/cmux-memory-guard-{run_id}-cmuxd.sock"
    log_path = f"/tmp/cmux-memory-guard-{run_id}.log"
    artifacts_dir = Path(args.artifacts).expanduser() if args.artifacts else None

    for path in (socket_path, cmuxd_socket):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass

    proc = launch_app(app_path, socket_path, cmuxd_socket, log_path, tag)
    client = SocketClient(socket_path, response_timeout=10.0)
    samples: list[MemorySample] = []
    trend = TrendResult(True, "not run", 0, 0, 0, 0, 0, 0)
    try:
        wait_for_socket(client, proc, timeout=20.0)
        workspace_ids = seed_workspaces(client, args.workspace_count)
        show_result = client.v2("debug.task_manager.show")
        print(
            "Task Manager memory guard setup: "
            f"pid={proc.pid} app={app_path} workspaces={len(workspace_ids)} visible={show_result.get('visible')}"
        )
        time.sleep(args.warmup_seconds)
        samples = collect_samples(proc.pid, args.duration_seconds, args.sample_interval_seconds)
        trend = classify_trend(samples, args.max_growth_mb, args.max_slope_mb_per_min)
        write_artifacts(artifacts_dir, samples, trend)
        print(
            "Task Manager memory guard result: "
            f"baseline={trend.baseline_mb:.1f} MB final={trend.final_mb:.1f} MB "
            f"growth={trend.growth_mb:.1f} MB slope={trend.slope_mb_per_min:.1f} MB/min "
            f"peak={trend.peak_mb:.1f} MB samples={trend.sample_count}"
        )
        if trend.failed:
            print(f"FAIL: {trend.reason}")
            print("--- cmux debug log tail ---")
            print(tail_file(Path(log_path)))
            return 1
        print(f"PASS: {trend.reason}")
        return 0
    finally:
        write_artifacts(artifacts_dir, samples, trend)
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5.0)
        for path in (socket_path, cmuxd_socket):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", help="Path to cmux .app or executable. Defaults to latest built Debug app.")
    parser.add_argument("--duration-seconds", type=float, default=DEFAULT_DURATION_SECONDS)
    parser.add_argument("--sample-interval-seconds", type=float, default=DEFAULT_SAMPLE_INTERVAL_SECONDS)
    parser.add_argument("--warmup-seconds", type=float, default=DEFAULT_WARMUP_SECONDS)
    parser.add_argument("--workspace-count", type=int, default=DEFAULT_WORKSPACE_COUNT)
    parser.add_argument("--max-growth-mb", type=float, default=DEFAULT_MAX_GROWTH_MB)
    parser.add_argument("--max-slope-mb-per-min", type=float, default=DEFAULT_MAX_SLOPE_MB_PER_MIN)
    parser.add_argument("--artifacts", help="Directory for JSON samples.")
    parser.add_argument("--self-check-only", action="store_true", help="Only validate the leak detector thresholds.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.duration_seconds <= 0:
        raise SystemExit("--duration-seconds must be positive")
    if args.sample_interval_seconds <= 0:
        raise SystemExit("--sample-interval-seconds must be positive")
    if args.workspace_count <= 0:
        raise SystemExit("--workspace-count must be positive")
    if args.self_check_only:
        detector_self_check(args.max_growth_mb, args.max_slope_mb_per_min)
        return 0
    return run_guard(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
