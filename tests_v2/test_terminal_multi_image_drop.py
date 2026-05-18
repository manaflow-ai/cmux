#!/usr/bin/env python3
"""Regression: multiple local image drops insert every materialized path."""

from __future__ import annotations

import base64
import hashlib
import os
import re
import secrets
import shlex
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _escape_for_shell_path(path: str) -> str:
    if "\n" in path or "\r" in path:
        return "'" + path.replace("'", "'\\''") + "'"
    result = path
    for char in "\\ ()[]{}<>\"'`!#$&;|*?\t":
        result = result.replace(char, "\\" + char)
    return result


def _focused_surface_id(client: cmux) -> str:
    ident = client.identify()
    surface_id = str((ident.get("focused") or {}).get("surface_id") or "")
    _must(bool(surface_id), f"Missing focused surface in identify payload: {ident}")
    return surface_id


def _wait_for_materialized_paths(client: cmux, surface_id: str, expected_count: int, timeout: float = 10.0) -> list[str]:
    pattern = re.compile(r"/[^\s%]*/clipboard-[^\s%]+\.png")
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        last = client.read_terminal_text(surface_id)
        paths: list[str] = []
        for line in last.replace("\r", "").splitlines():
            for match in pattern.findall(line):
                if match not in paths:
                    paths.append(match)
        if len(paths) >= expected_count:
            return paths[:expected_count]
        time.sleep(0.2)
    raise cmuxError(f"Timed out waiting for {expected_count} materialized image paths: {last[-1000:]!r}")


def _wait_for_terminal_text(client: cmux, surface_id: str, predicate, timeout: float = 10.0) -> str:
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        last = client.read_terminal_text(surface_id)
        if predicate(last):
            return last
        time.sleep(0.2)
    raise cmuxError(f"Timed out waiting for terminal predicate: {last[-1000:]!r}")


def _run_drop_case(client: cmux, expected_paths: list[str], payload: str) -> tuple[str, str]:
    workspace_id = client.new_workspace()
    client.select_workspace(workspace_id)
    surface_id = _focused_surface_id(client)
    client.simulate_terminal_file_drop(
        surface_id,
        expected_paths,
        route="terminal",
        payload=payload,
    )
    return workspace_id, surface_id


def _write_bracketed_paste_capture_script(temp_dir: Path, token: str) -> Path:
    script_path = temp_dir / f"capture-bracketed-paste-{token}.py"
    script_path.write_text(
        f"""
import os
import select
import sys
import termios
import time
import tty

token = {token!r}
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
data = b""
end_times = []
last_data_at = 0.0
try:
    sys.stdout.write("\\x1b[?2004hREADY-" + token + "\\r\\n")
    sys.stdout.flush()
    tty.setraw(fd)
    deadline = time.time() + 15.0
    while time.time() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.1)
        if readable:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            data += chunk
            last_data_at = time.time()
            while len(end_times) < data.count(b"\\x1b[201~"):
                end_times.append(last_data_at)
        if data.count(b"\\x1b[201~") >= 2:
            break
        if data and time.time() - last_data_at > 3.5:
            break
    timings = ",".join(f"{{value:.3f}}" for value in end_times)
    sys.stdout.write("\\r\\nPASTE-" + token + " " + data.hex() + " " + timings + "\\r\\n")
    sys.stdout.flush()
    time.sleep(2.0)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    sys.stdout.write("\\x1b[?2004l\\r\\n")
    sys.stdout.flush()
""".lstrip(),
        encoding="utf-8",
    )
    return script_path


def _run_bracketed_paste_case(client: cmux, expected_paths: list[str], payload: str, temp_dir: Path) -> tuple[str, bytes, list[float]]:
    token = f"{payload}-{secrets.token_hex(4)}"
    script_path = _write_bracketed_paste_capture_script(temp_dir, token)
    workspace_id = client.new_workspace()
    client.select_workspace(workspace_id)
    surface_id = _focused_surface_id(client)
    client.send_surface(surface_id, f"python3 {shlex.quote(str(script_path))}\\r")
    _wait_for_terminal_text(client, surface_id, lambda text: f"READY-{token}" in text)
    client.simulate_terminal_file_drop(
        surface_id,
        expected_paths,
        route="terminal",
        payload=payload,
    )
    terminal_text = _wait_for_terminal_text(
        client,
        surface_id,
        lambda text: f"PASTE-{token} " in text,
        timeout=12.0,
    )
    match = re.search(rf"PASTE-{re.escape(token)} ([0-9a-f]+) ([0-9.,]*)", terminal_text)
    _must(match is not None, f"missing paste capture line for {token}: {terminal_text[-1000:]!r}")
    timings = [
        float(value)
        for value in match.group(2).split(",")
        if value
    ]
    return workspace_id, bytes.fromhex(match.group(1)), timings


def main() -> int:
    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-local-multi-image-drop-"))
    workspace_ids: list[str] = []
    materialized_paths: list[str] = []
    try:
        first_image_path = temp_dir / f"dragged image one {secrets.token_hex(4)}.png"
        second_image_path = temp_dir / f"dragged image two {secrets.token_hex(4)}.png"
        first_image_path.write_bytes(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lS2cWQAAAABJRU5ErkJggg=="
        ))
        second_image_path.write_bytes(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        ))
        expected_paths = [str(first_image_path), str(second_image_path)]
        expected_shas = [
            hashlib.sha256(first_image_path.read_bytes()).hexdigest(),
            hashlib.sha256(second_image_path.read_bytes()).hexdigest(),
        ]
        with cmux(SOCKET_PATH) as client:
            workspace_id, surface_id = _run_drop_case(client, expected_paths, "image_data")
            workspace_ids.append(workspace_id)
            paths = _wait_for_materialized_paths(client, surface_id, expected_count=2)
            materialized_paths.extend(paths)

            materialized_shas = [
                hashlib.sha256(Path(path).read_bytes()).hexdigest()
                for path in paths
            ]
            _must(
                sorted(materialized_shas) == sorted(expected_shas),
                f"image_data materialized image hashes mismatch expected={sorted(expected_shas)} actual={sorted(materialized_shas)} paths={paths}",
            )

            escaped_paths = [_escape_for_shell_path(path) for path in expected_paths]
            workspace_id, surface_id = _run_drop_case(client, expected_paths, "file_urls")
            workspace_ids.append(workspace_id)
            terminal_text = _wait_for_terminal_text(
                client,
                surface_id,
                lambda text: all(path in text for path in escaped_paths),
            )
            for escaped_path in escaped_paths:
                _must(escaped_path in terminal_text, f"file URL image drop did not insert original path {escaped_path!r}: {terminal_text[-1000:]!r}")
            _must("/clipboard-" not in terminal_text, f"file URL image drop inserted temp clipboard path: {terminal_text[-1000:]!r}")

            for payload in ["image_data", "file_urls"]:
                workspace_id, raw_paste, paste_end_times = _run_bracketed_paste_case(client, expected_paths, payload, temp_dir)
                workspace_ids.append(workspace_id)
                if payload == "file_urls":
                    for escaped_path in escaped_paths:
                        _must(escaped_path.encode() in raw_paste, f"file URL paste did not include original path {escaped_path!r}: {raw_paste!r}")
                    _must(b"/clipboard-" not in raw_paste, f"file URL paste used temp clipboard path: {raw_paste!r}")
                paste_starts = raw_paste.count(b"\x1b[200~")
                paste_ends = raw_paste.count(b"\x1b[201~")
                _must(
                    paste_starts >= 2 and paste_ends >= 2,
                    f"{payload} drop should arrive as separate bracketed paste transactions; starts={paste_starts} ends={paste_ends} raw={raw_paste!r}",
                )
                _must(
                    len(paste_end_times) >= 2 and paste_end_times[1] - paste_end_times[0] >= 1.8,
                    f"{payload} paste transactions should be spaced for Claude image ingestion; timings={paste_end_times} raw={raw_paste!r}",
                )

        print(f"PASS: local image drop materialized {len(materialized_paths)} image_data images, preserved original file_urls, and used delayed paste transactions")
        return 0
    finally:
        if workspace_ids:
            try:
                with cmux(SOCKET_PATH) as client:
                    for workspace_id in workspace_ids:
                        client.close_workspace(workspace_id)
            except cmuxError:
                pass
        for path in materialized_paths:
            try:
                Path(path).unlink()
            except FileNotFoundError:
                pass
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
