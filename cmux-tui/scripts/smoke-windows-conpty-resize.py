#!/usr/bin/env python3
"""Verify that a Windows ConPTY resize reaches the attached terminal."""

from __future__ import annotations

import argparse
import base64
from collections import deque
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
OUTPUT_READ_CHUNK_SIZE = 8192
MAX_PENDING_OUTPUT_CHUNKS = 64
MAX_OUTPUT_TAIL_CHUNKS = 8
MAX_OUTPUT_TAIL_BYTES = 64 * 1024
MAX_STARTUP_OUTPUT_BYTES = 64 * 1024

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


def decode_cli_value(result: subprocess.CompletedProcess[str]) -> object:
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"cmux-tui returned invalid JSON: {result.stdout!r}") from error
    if isinstance(value, dict):
        return value.get("value", value)
    return value


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


class PtyOutputReader:
    """Read startup output with backpressure, then retain only a bounded tail."""

    def __init__(self, pty: PtyProcess) -> None:
        self.events: queue.Queue[str | BaseException | None] = queue.Queue(
            maxsize=MAX_PENDING_OUTPUT_CHUNKS
        )
        self.stop_event = threading.Event()
        self.startup_complete = threading.Event()
        self.done_event = threading.Event()
        self.tail: deque[str] = deque(maxlen=MAX_OUTPUT_TAIL_CHUNKS)
        self._tail_bytes = 0
        self._tail_lock = threading.Lock()
        self._pty = pty
        self._thread = threading.Thread(target=self._read, name="conpty-resize-reader", daemon=True)
        self._thread.start()

    def get(self, timeout: float | None = None) -> str | BaseException | None:
        return self.events.get(timeout=timeout)

    def qsize(self) -> int:
        return self.events.qsize()

    @property
    def tail_bytes(self) -> int:
        with self._tail_lock:
            return self._tail_bytes

    def request_stop(self) -> None:
        self.stop_event.set()
        self.startup_complete.set()

    def mark_startup_complete(self) -> None:
        """Switch from lossless startup delivery to bounded tail capture."""
        self.startup_complete.set()
        self._drain_pending()

    def close(self) -> None:
        """Stop and join after the caller has closed the PTY."""
        self.request_stop()
        self._thread.join()
        self._drain_pending()

    def _append_tail(self, chunk: str) -> None:
        if not chunk:
            return
        with self._tail_lock:
            if len(chunk) > MAX_OUTPUT_TAIL_BYTES:
                chunk = chunk[-MAX_OUTPUT_TAIL_BYTES:]
            while self._tail_bytes + len(chunk) > MAX_OUTPUT_TAIL_BYTES and self.tail:
                self._tail_bytes -= len(self.tail.popleft())
            self.tail.append(chunk)
            self._tail_bytes += len(chunk)

    def _drain_pending(self) -> None:
        while True:
            try:
                event = self.events.get_nowait()
            except queue.Empty:
                return
            if isinstance(event, str):
                self._append_tail(event)

    def _enqueue(self, event: str | BaseException | None) -> None:
        # Before startup completes, backpressure preserves every chunk. Once
        # the marker has been observed, later chunks go to bounded tail
        # diagnostics instead of an unbounded queue. stop_event releases a
        # producer blocked on a full queue during cleanup.
        if self.startup_complete.is_set():
            if isinstance(event, str):
                self._append_tail(event)
            return
        while not self.stop_event.is_set() and not self.startup_complete.is_set():
            try:
                self.events.put(event, timeout=0.05)
                return
            except queue.Full:
                continue
        if isinstance(event, str):
            self._append_tail(event)

    def _read(self) -> None:
        try:
            while not self.stop_event.is_set():
                chunk = self._pty.read(OUTPUT_READ_CHUNK_SIZE)
                if not chunk:
                    self._enqueue(None)
                    return
                self._enqueue(chunk)
        except (EOFError, OSError) as error:
            if not self.stop_event.is_set():
                self._enqueue(error)
        except BaseException as error:
            if not self.stop_event.is_set():
                self._enqueue(error)
        finally:
            self.done_event.set()


def start_output_reader(pty: PtyProcess) -> PtyOutputReader:
    return PtyOutputReader(pty)


def wait_for_tui_start(reader: PtyOutputReader) -> str:
    output = ""
    deadline = time.monotonic() + TIMEOUT_SECONDS
    post_probe_marker = "\x1b[>1s"
    startup_complete = False
    try:
        while post_probe_marker not in output:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"attach did not finish terminal setup: {output!r}")
            event = reader.get(timeout=remaining)
            if isinstance(event, BaseException):
                raise event
            if event is None:
                raise RuntimeError(f"attach closed during terminal setup: {output!r}")
            output += event
            if len(output) > MAX_STARTUP_OUTPUT_BYTES:
                raise RuntimeError("terminal setup output exceeded its bounded startup buffer")
        startup_complete = True
        return output
    finally:
        if startup_complete:
            reader.mark_startup_complete()
        else:
            reader.request_stop()


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
        value = decode_cli_value(screen)
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
            output_reader = None
            try:
                wait_for_socket(server, socket_path, stdout_path, stderr_path)
                created = run_cli(
                    binary, socket_path, env, "workspace", "create", "--name", "resize-check"
                )
                value = decode_cli_value(created)
                terminal = value.get("terminal_id") if isinstance(value, dict) else None
                if not isinstance(terminal, str):
                    raise RuntimeError(f"workspace creation had no terminal id: {created.stdout}")

                pty = PtyProcess.spawn(
                    [str(binary), "attach", "--socket", str(socket_path), "--terminal", terminal],
                    cwd=str(root),
                    env=env,
                    dimensions=(24, 80),
                )
                output_reader = start_output_reader(pty)
                startup_output = wait_for_tui_start(output_reader)
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
                unicode_value = decode_cli_value(unicode_screen)
                unicode_text = (
                    unicode_value
                    if isinstance(unicode_value, str)
                    else json.dumps(unicode_value, ensure_ascii=False)
                )
                if unicode_result not in unicode_text:
                    raise AssertionError(unicode_text)
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
                screen_value = decode_cli_value(screen)
                screen_text = (
                    screen_value
                    if isinstance(screen_value, str)
                    else json.dumps(screen_value, ensure_ascii=False)
                )
                if "RESIZE_101x33" not in screen_text:
                    raise AssertionError(screen_text)
            except Exception as error:
                raise RuntimeError(
                    f"{error}\n{server_diagnostics(stdout_path, stderr_path)}"
                ) from error
            finally:
                try:
                    if pty is not None and pty.isalive():
                        pty.terminate(force=True)
                finally:
                    if output_reader is not None:
                        output_reader.close()
                if server.poll() is None:
                    try:
                        run_cli(binary, socket_path, env, "session", "current", "shutdown")
                        server.wait(timeout=TIMEOUT_SECONDS)
                    except Exception:
                        server.kill()
                        server.wait()


if __name__ == "__main__":
    main()
