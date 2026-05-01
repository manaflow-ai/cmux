#!/usr/bin/env python3
"""Regression: desktop local terminal sessions should be shared through the local daemon."""

from __future__ import annotations

import glob
import os
import pty
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _require_env(name: str) -> str:
    value = (os.environ.get(name) or "").strip()
    if not value:
        raise cmuxError(f"{name} is required")
    return value


SOCKET_PATH = _require_env("CMUX_SOCKET")
DAEMON_SOCKET = _require_env("CMUXD_UNIX_PATH")
DAEMON_BIN = _require_env("CMUX_REMOTE_DAEMON_BINARY")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"),
        recursive=True,
    )
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: list[str]) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)
    env.pop("CMUX_PANEL_ID", None)

    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    return (proc.stdout or "").strip()


def _wait_for_text(
    client: cmux,
    workspace_id: str,
    needle: str,
    *,
    timeout_s: float = 12.0,
    scrollback: bool = True,
) -> str:
    deadline = time.time() + timeout_s
    last_text = ""
    while time.time() < deadline:
        payload = client._call(
            "surface.read_text",
            {"workspace_id": workspace_id, "scrollback": scrollback, "lines": 400},
        ) or {}
        last_text = str(payload.get("text") or "")
        if needle in last_text:
            return last_text
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for {needle!r} in app text: {last_text!r}")


def _wait_for_surface_text_metrics(
    client: cmux,
    workspace_id: str,
    predicate,
    *,
    timeout_s: float = 12.0,
) -> dict:
    deadline = time.time() + timeout_s
    last = _surface_text_metrics(client, workspace_id)
    while time.time() < deadline:
        last = _surface_text_metrics(client, workspace_id)
        if predicate(last):
            return last
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for visible text predicate in {workspace_id}, last={last!r}")


def _probe_zsh_env(cli: str, client: cmux, workspace_id: str) -> None:
    probe_token = f"zprobe_{int(time.time() * 1000)}"
    probe_command = (
        f"print -r -- PROBE:{probe_token}:$TERM:$COLORTERM; "
        "whence -w compdef compinit _complete"
    )

    _run_cli(cli, ["send", "--workspace", workspace_id, probe_command])
    _run_cli(cli, ["send-key", "--workspace", workspace_id, "enter"])
    text = _wait_for_text(client, workspace_id, f"PROBE:{probe_token}:xterm-ghostty:truecolor")
    _must(
        f"PROBE:{probe_token}:xterm-ghostty:truecolor" in text,
        f"Daemon-backed shell did not expose Ghostty term env: {text!r}",
    )
    _must(
        "compdef: function" in text and "compinit: function" in text and "_complete: function" in text,
        f"Daemon-backed shell did not expose zsh completion functions: {text!r}",
    )


def _wait_for_history(session_id: str, needle: str, timeout_s: float = 12.0) -> str:
    deadline = time.time() + timeout_s
    last = ""
    while time.time() < deadline:
        proc = subprocess.run(
            [DAEMON_BIN, "session", "history", session_id, "--socket", DAEMON_SOCKET],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            last = proc.stdout or ""
            if needle in last:
                return last
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for {needle!r} in daemon history: {last!r}")


def _session_status(session_id: str) -> tuple[int, int]:
    proc = subprocess.run(
        [DAEMON_BIN, "session", "status", session_id, "--socket", DAEMON_SOCKET],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"session status failed for {session_id}: {merged}")

    parts = (proc.stdout or "").strip().split()
    if len(parts) < 2 or "x" not in parts[1]:
        raise cmuxError(f"unexpected session status output: {proc.stdout!r}")
    dims = parts[1].split("x", 1)
    return int(dims[0]), int(dims[1])


def _current_window_id(client: cmux) -> str:
    payload = client._call("window.current", {}) or {}
    window_id = str(payload.get("window_id") or "")
    _must(bool(window_id), f"window.current returned no window_id: {payload!r}")
    return window_id


def _set_window_frame(client: cmux, window_id: str, bounds: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    payload = client._call(
        "debug.window.set_frame",
        {
            "window_id": window_id,
            "x": bounds[0],
            "y": bounds[1],
            "width": bounds[2] - bounds[0],
            "height": bounds[3] - bounds[1],
        },
    ) or {}
    width = int(payload.get("width") or 0)
    height = int(payload.get("height") or 0)
    _must(width > 0 and height > 0, f"debug.window.set_frame returned invalid payload: {payload!r}")
    x = int(payload.get("x") or 0)
    y = int(payload.get("y") or 0)
    return (x, y, x + width, y + height)


def _grow_window_dimension(
    client: cmux,
    window_id: str,
    bounds: tuple[int, int, int, int],
    *,
    axis: str,
    minimum_delta: int,
    preferred_deltas: list[int],
) -> tuple[int, int, int, int]:
    current_width = bounds[2] - bounds[0]
    current_height = bounds[3] - bounds[1]
    requested_deltas = [delta for delta in preferred_deltas if delta > 0]
    if minimum_delta not in requested_deltas:
        requested_deltas.append(minimum_delta)

    last = bounds
    for delta in requested_deltas:
        if axis == "width":
            target = (bounds[0], bounds[1], bounds[0] + current_width + delta, bounds[3])
        else:
            target = (bounds[0], bounds[1], bounds[2], bounds[1] + current_height + delta)
        actual = _set_window_frame(client, window_id, target)
        last = actual
        new_width = actual[2] - actual[0]
        new_height = actual[3] - actual[1]
        if axis == "width" and new_width >= current_width + minimum_delta:
            return actual
        if axis == "height" and new_height >= current_height + minimum_delta:
            return actual

    raise cmuxError(
        f"Window {axis} never grew enough from {bounds} after resize attempts, last={last}"
    )


def _wait_for_session_size_change(session_id: str, previous: tuple[int, int], *, timeout_s: float = 8.0) -> tuple[int, int]:
    deadline = time.time() + timeout_s
    last = previous
    while time.time() < deadline:
        last = _session_status(session_id)
        if last != previous:
            return last
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for daemon session size to change from {previous}, last={last}")


def _wait_for_session_size(session_id: str, predicate, *, timeout_s: float = 8.0) -> tuple[int, int]:
    deadline = time.time() + timeout_s
    last = _session_status(session_id)
    while time.time() < deadline:
        last = _session_status(session_id)
        if predicate(last):
            return last
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for daemon session size predicate, last={last}")


def _panel_snapshot(client: cmux, surface_id: str, label: str) -> dict:
    payload = client._call(
        "debug.panel_snapshot",
        {
            "surface_id": surface_id,
            "label": label,
        },
    ) or {}
    width = int(payload.get("width") or 0)
    height = int(payload.get("height") or 0)
    _must(width > 0 and height > 0, f"debug.panel_snapshot returned invalid payload: {payload!r}")
    return {
        "width": width,
        "height": height,
        "changed_pixels": int(payload.get("changed_pixels") or -1),
        "path": str(payload.get("path") or ""),
    }


def _surface_text_metrics(client: cmux, workspace_id: str, *, tail_lines: int | None = None) -> dict:
    payload = client._call(
        "surface.read_text",
        {"workspace_id": workspace_id, "scrollback": False, "lines": 400},
    ) or {}
    text = str(payload.get("text") or "")
    lines = text.splitlines()
    if tail_lines is not None and tail_lines > 0:
        lines = lines[-tail_lines:]
        text = "\n".join(lines)
    return {
        "text": text,
        "line_count": len(lines),
        "max_line_length": max((len(line) for line in lines), default=0),
    }


def _send_line(cli: str, workspace_id: str, line: str) -> None:
    if line:
        _run_cli(cli, ["send", "--workspace", workspace_id, line])
    _run_cli(cli, ["send-key", "--workspace", workspace_id, "enter"])


def _resize_probe_lines() -> list[str]:
    script_lines = [
        "cat >/tmp/cmux_resize_probe.py <<'PY'",
        "import os",
        "import signal",
        "import sys",
        "import time",
        "",
        "def render_line(prefix: str, cols: int, fill: str) -> str:",
        "    if cols <= 0:",
        "        return ''",
        "    if len(prefix) >= cols:",
        "        return prefix[:cols]",
        "    return prefix + (fill * (cols - len(prefix)))",
        "",
        "def redraw(*_args):",
        "    size = os.get_terminal_size()",
        "    cols = size.columns",
        "    rows = size.lines",
        "    top = render_line(f'TOP:{cols}x{rows}:', cols, '#')",
        "    mid = render_line(f'MID:{cols}x{rows}:', cols, '.')",
        "    bot = render_line(f'BOT:{cols}x{rows}:', cols, '#')",
        "    lines = [top]",
        "    for _ in range(max(rows - 2, 0)):",
        "        lines.append(mid)",
        "    if rows > 1:",
        "        lines.append(bot)",
        "    esc = chr(27)",
        "    sys.stdout.write(f'{esc}[H{esc}[2J{esc}[3J')",
        "    sys.stdout.write(chr(10).join(lines))",
        "    sys.stdout.flush()",
        "",
        "signal.signal(signal.SIGWINCH, redraw)",
        "redraw()",
        "while True:",
        "    time.sleep(1)",
        "PY",
        "/usr/bin/python3 /tmp/cmux_resize_probe.py",
    ]
    return script_lines


def _reset_panel_snapshot(client: cmux, surface_id: str) -> None:
    client._call("debug.panel_snapshot.reset", {"surface_id": surface_id})


def _wait_for_panel_snapshot(client: cmux, surface_id: str, predicate, *, timeout_s: float = 8.0, label_prefix: str) -> dict:
    deadline = time.time() + timeout_s
    last: dict = {}
    while time.time() < deadline:
        last = _panel_snapshot(client, surface_id, f"{label_prefix}_{int(time.time() * 1000)}")
        if predicate(last):
            return last
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for panel snapshot predicate, last={last!r}")


def _attach_and_send(session_id: str, text: str, timeout_s: float = 12.0) -> str:
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(
            DAEMON_BIN,
            [
                DAEMON_BIN,
                "session",
                "attach",
                session_id,
                "--socket",
                DAEMON_SOCKET,
            ],
        )

    captured = bytearray()
    deadline = time.time() + timeout_s
    detached = False
    os.set_blocking(fd, False)
    try:
        time.sleep(0.5)
        os.write(fd, text.encode("utf-8"))
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if not ready:
                continue
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                chunk = b""
            if chunk:
                captured.extend(chunk)
            if text.strip() and text.strip().encode("utf-8") in captured:
                break

        os.write(fd, b"\x1c")
        detached = True
    finally:
        if not detached:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass

        _, status = os.waitpid(pid, 0)
        try:
            os.close(fd)
        except OSError:
            pass

    _must(os.WIFEXITED(status), f"attach process did not exit cleanly: {status}")
    _must(os.WEXITSTATUS(status) == 0, f"attach process failed with {os.WEXITSTATUS(status)}")
    return captured.decode("utf-8", errors="replace")


def main() -> int:
    cli = _find_cli_binary()
    baseline_workspace = ""
    created_workspaces: list[str] = []

    try:
        with cmux(SOCKET_PATH) as client:
            baseline_workspace = client.current_workspace()
            resize_lines = _resize_probe_lines()
            resize_result = _run_cli(cli, ["new-workspace"])
            _must(
                resize_result.startswith("OK "),
                f"resize workspace expected OK response, got: {resize_result!r}",
            )
            resize_workspace = resize_result.removeprefix("OK ").strip()
            _must(bool(resize_workspace), f"resize workspace returned no workspace handle: {resize_result!r}")
            created_workspaces.append(resize_workspace)

            client.select_workspace(resize_workspace)
            for line in resize_lines:
                _send_line(cli, resize_workspace, line)
            _wait_for_surface_text_metrics(
                client,
                resize_workspace,
                lambda metrics: (
                    metrics["max_line_length"] >= 20
                    and metrics["line_count"] >= 8
                    and "TOP:" in metrics["text"]
                    and "BOT:" in metrics["text"]
                ),
            )
            print("resize_probe_started", {"workspace_id": resize_workspace}, flush=True)
            window_id = _current_window_id(client)

            resize_listed = client._call("surface.list", {"workspace_id": resize_workspace}) or {}
            resize_rows = list(resize_listed.get("surfaces") or [])
            resize_terminal_row = next(
                (row for row in resize_rows if str(row.get("type") or "") == "terminal"),
                None,
            )
            _must(
                resize_terminal_row is not None,
                f"Expected a terminal surface in resize workspace: {resize_rows}",
            )
            resize_surface_id = str(resize_terminal_row.get("id") or "")
            _must(bool(resize_surface_id), f"resize surface.list returned no surface id: {resize_terminal_row}")
            size_before = _wait_for_session_size(
                resize_surface_id,
                lambda size: size[0] > 0 and size[1] > 0,
                timeout_s=12.0,
            )
            print(
                "daemon_backed",
                {"workspace_id": resize_workspace, "surface_id": resize_surface_id, "size": size_before},
                flush=True,
            )

            baseline_bounds = _set_window_frame(client, window_id, (120, 120, 920, 760))
            time.sleep(1.0)
            _reset_panel_snapshot(client, resize_surface_id)
            snapshot_before = _panel_snapshot(client, resize_surface_id, "baseline")
            content_before = _surface_text_metrics(client, resize_workspace)

            width_bounds = _grow_window_dimension(
                client,
                window_id,
                baseline_bounds,
                axis="width",
                minimum_delta=160,
                preferred_deltas=[240, 320, 400, 520],
            )
            size_after_width_resize = _wait_for_session_size(
                resize_surface_id,
                lambda size: size[0] != size_before[0],
            )
            _must(
                size_after_width_resize[0] != size_before[0],
                "Horizontal resize did not change daemon session columns: "
                f"bounds={baseline_bounds}->{width_bounds} sizes={size_before}->{size_after_width_resize}",
            )
            snapshot_after_width_resize = _wait_for_panel_snapshot(
                client,
                resize_surface_id,
                lambda snapshot: snapshot["width"] != snapshot_before["width"],
                label_prefix="width_resize",
            )
            _must(
                snapshot_after_width_resize["width"] != snapshot_before["width"],
                "Horizontal resize did not change rendered panel width: "
                f"bounds={baseline_bounds}->{width_bounds} snapshots={snapshot_before}->{snapshot_after_width_resize}",
            )
            content_after_width_resize = _surface_text_metrics(client, resize_workspace)
            _must(
                content_after_width_resize["max_line_length"] > content_before["max_line_length"],
                "Horizontal resize did not expand rendered terminal text width: "
                f"bounds={baseline_bounds}->{width_bounds} "
                f"content={content_before}->{content_after_width_resize} "
                f"snapshots={snapshot_before}->{snapshot_after_width_resize}",
            )
            print(
                "width_resize_ok",
                {
                    "workspace_id": resize_workspace,
                    "surface_id": resize_surface_id,
                    "before": size_before,
                    "after": size_after_width_resize,
                },
                flush=True,
            )

            height_bounds = _grow_window_dimension(
                client,
                window_id,
                width_bounds,
                axis="height",
                minimum_delta=120,
                preferred_deltas=[160, 220, 280, 360],
            )
            size_after_height_resize = _wait_for_session_size(
                resize_surface_id,
                lambda size: size[1] != size_after_width_resize[1],
            )
            _must(
                size_after_height_resize[1] != size_after_width_resize[1],
                "Vertical resize did not change daemon session rows: "
                f"bounds={width_bounds}->{height_bounds} sizes={size_after_width_resize}->{size_after_height_resize}",
            )
            snapshot_after_height_resize = _wait_for_panel_snapshot(
                client,
                resize_surface_id,
                lambda snapshot: snapshot["height"] != snapshot_after_width_resize["height"],
                label_prefix="height_resize",
            )
            _must(
                snapshot_after_height_resize["height"] != snapshot_after_width_resize["height"],
                "Vertical resize did not change rendered panel height: "
                f"bounds={width_bounds}->{height_bounds} snapshots={snapshot_after_width_resize}->{snapshot_after_height_resize}",
            )
            content_after_height_resize = _surface_text_metrics(client, resize_workspace)
            _must(
                content_after_height_resize["line_count"] > content_after_width_resize["line_count"],
                "Vertical resize did not expand rendered terminal text height: "
                f"bounds={width_bounds}->{height_bounds} "
                f"content={content_after_width_resize}->{content_after_height_resize} "
                f"snapshots={snapshot_after_width_resize}->{snapshot_after_height_resize}",
            )
            print(
                "height_resize_ok",
                {
                    "workspace_id": resize_workspace,
                    "surface_id": resize_surface_id,
                    "after": size_after_height_resize,
                },
                flush=True,
            )

            print(
                "resize_sizes",
                {
                    "baseline_bounds": baseline_bounds,
                    "width_bounds": width_bounds,
                    "height_bounds": height_bounds,
                    "before": size_before,
                    "after_width_resize": size_after_width_resize,
                    "after_height_resize": size_after_height_resize,
                    "resize_surface_id": resize_surface_id,
                    "snapshot_before": snapshot_before,
                    "snapshot_after_width_resize": snapshot_after_width_resize,
                    "snapshot_after_height_resize": snapshot_after_height_resize,
                    "content_before": content_before,
                    "content_after_width_resize": content_after_width_resize,
                    "content_after_height_resize": content_after_height_resize,
                },
            )

            client.select_workspace(baseline_workspace)
    finally:
        for workspace_id in reversed(created_workspaces):
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: desktop local workspace is shared through cmuxd-remote")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
