#!/usr/bin/env python3
"""Verify that a Windows ConPTY resize reaches the attached terminal."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
import uuid

from winpty import PtyProcess


TIMEOUT_SECONDS = 20.0
CREATE_NEW_PROCESS_GROUP = 0x00000200

# OpenConsole emits these sequences while it initializes the ConPTY host. They
# are host-to-terminal queries, not output from the cmux-tui child. The
# optional window-visibility report is emitted when the host inherits the
# cursor state.
CONPTY_STARTUP_PREFIX = "\x1b[c\x1b[?1004h\x1b[?9001h"
CONPTY_STARTUP_PREFIX_WITH_VISIBILITY = f"\x1b[1t{CONPTY_STARTUP_PREFIX}"


def run_cli(binary: Path, socket_path: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(binary), "--socket", str(socket_path), "--json", *args],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=TIMEOUT_SECONDS,
        check=False,
        creationflags=CREATE_NEW_PROCESS_GROUP,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"cmux-tui command failed ({result.returncode}): {result.args!r}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result


def read_log(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def server_diagnostics(stdout_path: Path, stderr_path: Path) -> str:
    return f"server stdout:\n{read_log(stdout_path)}\nserver stderr:\n{read_log(stderr_path)}"


def wait_for_socket(
    server: subprocess.Popen[bytes], socket_path: Path, stdout_path: Path, stderr_path: Path
) -> None:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if socket_path.exists():
            return
        code = server.poll()
        if code is not None:
            raise RuntimeError(
                f"server exited before socket publication with code {code}\n"
                f"{server_diagnostics(stdout_path, stderr_path)}"
            )
        time.sleep(0.01)
    raise TimeoutError(f"server did not publish {socket_path}")


def start_output_reader(pty: PtyProcess) -> queue.Queue[str | BaseException | None]:
    events: queue.Queue[str | BaseException | None] = queue.Queue()

    def read() -> None:
        try:
            while True:
                chunk = pty.read(8192)
                if not chunk:
                    events.put(None)
                    return
                events.put(chunk)
        except BaseException as error:
            events.put(error)

    threading.Thread(target=read, name="conpty-resize-reader", daemon=True).start()
    return events


def wait_for_tui_start(events: queue.Queue[str | BaseException | None]) -> str:
    output = ""
    deadline = time.monotonic() + TIMEOUT_SECONDS
    post_probe_marker = "\x1b[>1s"
    while post_probe_marker not in output:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"attach did not finish terminal setup: {output!r}")
        event = events.get(timeout=remaining)
        if isinstance(event, BaseException):
            raise event
        if event is None:
            raise RuntimeError(f"attach closed during terminal setup: {output!r}")
        output += event
    return output


def split_conpty_startup_prefix(output: str) -> tuple[str, str]:
    """Return the documented OpenConsole prefix and cmux-tui output."""
    for prefix in (CONPTY_STARTUP_PREFIX_WITH_VISIBILITY, CONPTY_STARTUP_PREFIX):
        if output.startswith(prefix):
            return prefix, output[len(prefix) :]
    raise AssertionError(f"unexpected ConPTY startup prefix: {output!r}")


def verify_no_unread_startup_queries(output: str) -> None:
    conpty_prefix, cmux_output = split_conpty_startup_prefix(output)
    forbidden = {
        "window pixel query": "\x1b[14t",
        "Kitty graphics query": "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\",
        "primary device attributes query": "\x1b[c",
    }
    for name, query in forbidden.items():
        if query in cmux_output:
            raise AssertionError(
                f"Windows attach emitted unread {name} after ConPTY prefix "
                f"{conpty_prefix!r}: {output!r}"
            )


def wait_for_screen_size(
    binary: Path,
    socket_path: Path,
    env: dict[str, str],
    terminal: str,
    cols: int,
    rows: int,
) -> None:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    last_screen = None
    while time.monotonic() < deadline:
        screen = run_cli(binary, socket_path, env, "terminal", terminal, "screen", "read")
        value = json.loads(screen.stdout)
        if isinstance(value, dict):
            value = value.get("value", value)
        last_screen = value
        if isinstance(value, dict) and value.get("cols") == cols and value.get("rows") == rows:
            return
        time.sleep(0.01)
    raise TimeoutError(f"screen did not reach {cols}x{rows}: {last_screen!r}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()

    with tempfile.TemporaryDirectory(prefix="cmux-conpty-resize-") as temporary:
        root = Path(temporary)
        state = root / "state"
        state.mkdir()
        (state / "machine-id").write_bytes(f"machine_{uuid.uuid4().hex}\n".encode())
        (state / "resource-effect-pepper").write_bytes(os.urandom(32))
        socket_path = root / "server.sock"
        config = root / "config.json"
        stdout_path = root / "server.stdout.log"
        stderr_path = root / "server.stderr.log"
        config.write_text("{}\n", encoding="utf-8")
        env = os.environ.copy()
        env["CMUX_TUI_CONFIG"] = str(config)
        with stdout_path.open("wb") as server_stdout, stderr_path.open("wb") as server_stderr:
            server = subprocess.Popen(
                [
                    str(binary),
                    "--headless",
                    "--session",
                    "windows-conpty-resize",
                    "--socket",
                    str(socket_path),
                    "--state",
                    str(state),
                ],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=server_stdout,
                stderr=server_stderr,
                creationflags=CREATE_NEW_PROCESS_GROUP,
            )
            pty = None
            try:
                wait_for_socket(server, socket_path, stdout_path, stderr_path)
                created = run_cli(
                    binary, socket_path, env, "workspace", "create", "--name", "resize-check"
                )
                value = json.loads(created.stdout)
                if isinstance(value, dict):
                    value = value.get("value", value)
                terminal = value.get("terminal_id") if isinstance(value, dict) else None
                if not isinstance(terminal, str):
                    raise RuntimeError(f"workspace creation had no terminal id: {created.stdout}")

                pty = PtyProcess.spawn(
                    [str(binary), "attach", "--socket", str(socket_path), "--terminal", terminal],
                    cwd=str(root),
                    env=env,
                    dimensions=(24, 80),
                )
                output_events = start_output_reader(pty)
                startup_output = wait_for_tui_start(output_events)
                verify_no_unread_startup_queries(startup_output)
                pty.setwinsize(33, 101)
                wait_for_screen_size(binary, socket_path, env, terminal, 101, 33)
                unicode_result = "CMUX_UTF8_RESULT_界_é"
                pty.write("$m='界_é'; Write-Output ('CMUX_UTF8_RESULT_' + $m)\r")
                run_cli(
                    binary,
                    socket_path,
                    env,
                    "terminal",
                    terminal,
                    "screen",
                    "wait",
                    "--pattern",
                    unicode_result,
                    "--timeout-ms",
                    "10000",
                )
                unicode_screen = run_cli(
                    binary, socket_path, env, "terminal", terminal, "screen", "read"
                )
                if unicode_result not in unicode_screen.stdout:
                    raise AssertionError(unicode_screen.stdout)
                command = (
                    "Write-Output ('RESIZE_' + $Host.UI.RawUI.WindowSize.Width + "
                    "'x' + $Host.UI.RawUI.WindowSize.Height)\r"
                )
                encoded = base64.b64encode(command.encode("utf-8")).decode("ascii")
                run_cli(
                    binary, socket_path, env, "terminal", terminal, "write", "--bytes-base64", encoded
                )
                run_cli(
                    binary,
                    socket_path,
                    env,
                    "terminal",
                    terminal,
                    "screen",
                    "wait",
                    "--pattern",
                    "RESIZE_101x33",
                    "--timeout-ms",
                    "10000",
                )
                screen = run_cli(binary, socket_path, env, "terminal", terminal, "screen", "read")
                if "RESIZE_101x33" not in screen.stdout:
                    raise AssertionError(screen.stdout)
            except Exception as error:
                raise RuntimeError(
                    f"{error}\n{server_diagnostics(stdout_path, stderr_path)}"
                ) from error
            finally:
                if pty is not None and pty.isalive():
                    pty.terminate(force=True)
                if server.poll() is None:
                    try:
                        run_cli(binary, socket_path, env, "session", "current", "shutdown")
                        server.wait(timeout=TIMEOUT_SECONDS)
                    except Exception:
                        server.kill()
                        server.wait()


if __name__ == "__main__":
    main()
