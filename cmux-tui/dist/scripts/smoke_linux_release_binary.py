#!/usr/bin/env python3
"""Exercise one exact release-style cmux-tui binary on Linux."""

from __future__ import annotations

import argparse
import base64
import fcntl
import json
import os
import pathlib
import platform
import pty
import select
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import time
from typing import Any


TIMEOUT_SECONDS = 20.0
UNICODE_INPUT = "漢字 e\u0301 👩‍💻"
UNICODE_OUTPUT = f"UNICODE:<{UNICODE_INPUT}>"
PTY_MARKER = "PTY-MARKER"
RESTART_MARKER = "RESTART-READY"
FINAL_MARKER = "FINAL-BYTES"


def remaining(deadline: float) -> float:
    value = deadline - time.monotonic()
    if value <= 0:
        raise TimeoutError("deadline expired")
    return value


def hermetic_env(root: pathlib.Path) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(root / "home"),
            "SHELL": "/bin/sh",
            "TERM": "xterm-256color",
            "XDG_CACHE_HOME": str(root / "xdg-cache"),
            "XDG_CONFIG_HOME": str(root / "xdg-config"),
            "XDG_DATA_HOME": str(root / "xdg-data"),
            "XDG_STATE_HOME": str(root / "xdg-state"),
            "CMUX_TUI_CONFIG": str(root / "config.json"),
        }
    )
    for name in (
        "home",
        "xdg-cache",
        "xdg-config",
        "xdg-data",
        "xdg-state",
    ):
        (root / name).mkdir(parents=True, exist_ok=True)
    (root / "config.json").write_text("{}\n", encoding="utf-8")
    return env


def run_cli(
    binary: pathlib.Path,
    socket_path: pathlib.Path,
    env: dict[str, str],
    *args: str,
) -> subprocess.CompletedProcess[str]:
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
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"cmux-tui command failed ({result.returncode}): {result.args!r}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result


def result_value(result: subprocess.CompletedProcess[str]) -> dict[str, Any]:
    value: Any = json.loads(result.stdout)
    if isinstance(value, dict) and isinstance(value.get("value"), dict):
        value = value["value"]
    if not isinstance(value, dict):
        raise RuntimeError(f"cmux-tui returned an unexpected result: {result.stdout}")
    return value


def wait_for_server(
    server: subprocess.Popen[bytes], socket_path: pathlib.Path
) -> None:
    if server.stdout is None:
        raise AssertionError("server stdout was not captured")
    deadline = time.monotonic() + TIMEOUT_SECONDS
    output = bytearray()
    while True:
        if server.poll() is not None:
            output.extend(server.stdout.read() or b"")
            raise RuntimeError(
                f"server exited before readiness with {server.returncode}:\n"
                + output.decode("utf-8", errors="replace")
            )
        readable, _, _ = select.select(
            [server.stdout], [], [], remaining(deadline)
        )
        if not readable:
            raise TimeoutError(f"server did not publish {socket_path}")
        line = server.stdout.readline()
        if not line:
            continue
        output.extend(line)
        if b"control socket at " in line:
            if not socket_path.is_socket():
                raise AssertionError(
                    f"server announced a missing control socket: {socket_path}"
                )
            return


def start_server(
    binary: pathlib.Path,
    socket_path: pathlib.Path,
    state_path: pathlib.Path,
    env: dict[str, str],
) -> subprocess.Popen[bytes]:
    server = subprocess.Popen(
        [
            str(binary),
            "--headless",
            "--session",
            "release-behavior",
            "--socket",
            str(socket_path),
            "--state",
            str(state_path),
        ],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        wait_for_server(server, socket_path)
    except Exception:
        if server.poll() is None:
            server.kill()
            server.wait(timeout=TIMEOUT_SECONDS)
        raise
    return server


def stop_server(server: subprocess.Popen[bytes]) -> None:
    if server.poll() is None:
        server.send_signal(signal.SIGTERM)
    code = server.wait(timeout=TIMEOUT_SECONDS)
    if code != 0:
        output = b""
        if server.stdout is not None:
            output = server.stdout.read() or b""
        raise AssertionError(
            f"server SIGTERM exit was {code}:\n"
            + output.decode("utf-8", errors="replace")
        )


class LegacyClient:
    def __init__(self, socket_path: pathlib.Path, name: str | None = None) -> None:
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.connect(str(socket_path))
        self.buffer = bytearray()
        self.output = bytearray()
        self.next_id = 1
        if name is not None:
            self.request({"cmd": "set-client-info", "name": name, "kind": "tui"})

    def close(self) -> None:
        self.socket.close()

    def _message(self, deadline: float) -> dict[str, Any]:
        while b"\n" not in self.buffer:
            self.socket.settimeout(remaining(deadline))
            chunk = self.socket.recv(65536)
            if not chunk:
                raise EOFError("control socket closed")
            self.buffer.extend(chunk)
        line, _, tail = self.buffer.partition(b"\n")
        self.buffer = bytearray(tail)
        value = json.loads(line)
        if not isinstance(value, dict):
            raise AssertionError(f"non-object control message: {value!r}")
        return value

    def _record_event(self, value: dict[str, Any]) -> None:
        field = None
        if value.get("event") in {"output", "vt-state"}:
            field = "data"
        elif value.get("event") == "resized":
            field = "replay"
        if field is not None and isinstance(value.get(field), str):
            self.output.extend(base64.b64decode(value[field], validate=True))

    def request(self, payload: dict[str, Any]) -> Any:
        request_id = self.next_id
        self.next_id += 1
        message = dict(payload)
        message["id"] = request_id
        self.socket.sendall((json.dumps(message) + "\n").encode("utf-8"))
        deadline = time.monotonic() + TIMEOUT_SECONDS
        while True:
            value = self._message(deadline)
            self._record_event(value)
            if value.get("id") != request_id:
                continue
            if not value.get("ok"):
                raise RuntimeError(f"control request failed: {value!r}")
            return value.get("data")

    def attach(self, surface: int, cols: int, rows: int) -> None:
        self.request(
            {
                "cmd": "attach-surface",
                "surface": surface,
                "cols": cols,
                "rows": rows,
            }
        )

    def wait_output(self, marker: bytes) -> None:
        deadline = time.monotonic() + TIMEOUT_SECONDS
        try:
            while marker not in self.output:
                value = self._message(deadline)
                self._record_event(value)
        except (EOFError, TimeoutError) as error:
            raise AssertionError(
                f"attach stream did not contain {marker!r}: "
                f"{bytes(self.output[-4000:])!r}"
            ) from error


def legacy_request(socket_path: pathlib.Path, payload: dict[str, Any]) -> Any:
    client = LegacyClient(socket_path)
    try:
        return client.request(payload)
    finally:
        client.close()


def workspace_surface(socket_path: pathlib.Path, name: str) -> int:
    tree = legacy_request(socket_path, {"cmd": "list-workspaces"})
    for workspace in tree["workspaces"]:
        if workspace.get("name") != name:
            continue
        for screen in workspace["screens"]:
            for pane in screen["panes"]:
                for tab in pane["tabs"]:
                    surface = tab.get("surface")
                    if isinstance(surface, int):
                        return surface
    raise AssertionError(f"workspace {name!r} has no terminal surface: {tree!r}")


def terminal_write(
    binary: pathlib.Path,
    socket_path: pathlib.Path,
    env: dict[str, str],
    terminal: str,
    value: str,
) -> None:
    encoded = base64.b64encode(value.encode("utf-8")).decode("ascii")
    run_cli(
        binary,
        socket_path,
        env,
        "terminal",
        terminal,
        "write",
        "--bytes-base64",
        encoded,
    )


def terminal_wait(
    binary: pathlib.Path,
    socket_path: pathlib.Path,
    env: dict[str, str],
    terminal: str,
    pattern: str,
) -> None:
    run_cli(
        binary,
        socket_path,
        env,
        "terminal",
        terminal,
        "screen",
        "wait",
        "--pattern",
        pattern,
        "--timeout-ms",
        str(int(TIMEOUT_SECONDS * 1000)),
    )


def assert_two_clients(client: LegacyClient, surface: int) -> None:
    clients = client.request({"cmd": "list-clients"})
    by_name = {
        value.get("name"): value
        for value in clients
        if value.get("name") in {"release-a", "release-b"}
    }
    if set(by_name) != {"release-a", "release-b"}:
        raise AssertionError(f"simultaneous clients missing: {clients!r}")
    for name, value in by_name.items():
        if surface not in value.get("attached", []):
            raise AssertionError(f"{name} is not attached to {surface}: {value!r}")


def assert_exit(waited: dict[str, Any]) -> None:
    if waited.get("state") != "exited" or waited.get("lifecycle") != "exited":
        raise AssertionError(f"terminal process remained active: {waited!r}")
    if waited.get("outcome") != {"kind": "exit", "code": 23}:
        raise AssertionError(f"terminal process lost exit code 23: {waited!r}")


def verify_release_behavior(binary: pathlib.Path, root: pathlib.Path) -> None:
    env = hermetic_env(root)
    socket_path = root / "server.sock"
    state_path = root / "state"
    state_path.mkdir()
    server: subprocess.Popen[bytes] | None = None
    terminal: str | None = None
    clients: list[LegacyClient] = []
    try:
        server = start_server(binary, socket_path, state_path, env)
        created = result_value(
            run_cli(
                binary,
                socket_path,
                env,
                "workspace",
                "create",
                "--name",
                "release-behavior",
            )
        )
        terminal_value = created.get("terminal_id")
        if not isinstance(terminal_value, str):
            raise AssertionError(f"workspace creation omitted terminal id: {created!r}")
        terminal = terminal_value
        surface = workspace_surface(socket_path, "release-behavior")

        client_a = LegacyClient(socket_path, "release-a")
        client_a.attach(surface, 101, 37)
        clients.append(client_a)
        client_b = LegacyClient(socket_path, "release-b")
        client_b.attach(surface, 80, 24)
        clients.append(client_b)
        client_a.request(
            {
                "cmd": "set-client-sizing",
                "surface": surface,
                "enabled": True,
                "exclusive": True,
            }
        )
        assert_two_clients(client_a, surface)

        shell_program = (
            "printf 'PTY-%s\\n' MARKER; "
            "IFS= read -r payload; "
            "printf 'UNI%s:<%s>\\n' CODE \"$payload\"; "
            "printf 'SIZE:'; stty size; "
            "printf 'RESTART-%s\\n' READY; "
            "IFS= read -r gate; "
            "if [ \"$gate\" = finish ]; then "
            "printf 'FINAL-%s\\n' BYTES; exit 23; fi; exit 97\r"
        )
        terminal_write(binary, socket_path, env, terminal, shell_program)
        terminal_wait(binary, socket_path, env, terminal, PTY_MARKER)
        terminal_write(binary, socket_path, env, terminal, UNICODE_INPUT + "\r")
        terminal_wait(binary, socket_path, env, terminal, UNICODE_OUTPUT)
        terminal_wait(binary, socket_path, env, terminal, "SIZE:37 101")
        terminal_wait(binary, socket_path, env, terminal, RESTART_MARKER)

        expected = UNICODE_OUTPUT.encode("utf-8")
        for client in clients:
            client.wait_output(PTY_MARKER.encode("ascii"))
            client.wait_output(expected)
            client.wait_output(b"SIZE:37 101")

        for client in clients:
            client.close()
        clients.clear()
        stop_server(server)
        server = None

        server = start_server(binary, socket_path, state_path, env)
        terminal_wait(binary, socket_path, env, terminal, RESTART_MARKER)
        restored_surface = workspace_surface(socket_path, "release-behavior")
        restored = LegacyClient(socket_path, "release-after-restart")
        restored.attach(restored_surface, 101, 37)
        clients.append(restored)
        terminal_write(binary, socket_path, env, terminal, "finish\r")
        restored.wait_output(FINAL_MARKER.encode("ascii"))

        waited = result_value(
            run_cli(
                binary,
                socket_path,
                env,
                "terminal",
                terminal,
                "process",
                "wait",
                "--timeout-ms",
                str(int(TIMEOUT_SECONDS * 1000)),
            )
        )
        assert_exit(waited)
        for client in clients:
            client.close()
        clients.clear()
        stop_server(server)
        server = None

        server = start_server(binary, socket_path, state_path, env)
        persisted_exit = result_value(
            run_cli(
                binary,
                socket_path,
                env,
                "terminal",
                terminal,
                "process",
                "wait",
                "--timeout-ms",
                "0",
            )
        )
        assert_exit(persisted_exit)
    finally:
        for client in clients:
            client.close()
        if server is not None and server.poll() is None:
            if terminal is not None:
                try:
                    run_cli(
                        binary,
                        socket_path,
                        env,
                        "terminal",
                        terminal,
                        "close",
                        "--idempotency-key",
                        "release-behavior-cleanup",
                    )
                except Exception as error:
                    print(f"cleanup terminal close failed: {error}", flush=True)
            try:
                run_cli(binary, socket_path, env, "session", "current", "shutdown")
                server.wait(timeout=TIMEOUT_SECONDS)
            except Exception:
                server.kill()
                server.wait(timeout=TIMEOUT_SECONDS)


def wait_for_interactive_ready(
    process: subprocess.Popen[bytes], master_fd: int, slave_fd: int
) -> None:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    raw_mask = termios.ECHO | termios.ICANON | termios.ISIG
    output = bytearray()
    while True:
        raw = not termios.tcgetattr(slave_fd)[3] & raw_mask
        if raw and b"\x1b[?1049h" in output:
            return
        if process.poll() is not None:
            raise AssertionError(
                f"interactive TUI exited before alternate-screen raw mode with "
                f"{process.returncode}: {bytes(output[-2000:])!r}"
            )
        readable, _, _ = select.select(
            [master_fd], [], [], min(0.5, remaining(deadline))
        )
        if readable:
            try:
                output.extend(os.read(master_fd, 65536))
            except OSError as error:
                raise AssertionError("interactive TUI closed its PTY") from error


def wait_for_interactive_exit(
    process: subprocess.Popen[bytes], master_fd: int
) -> int:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while process.poll() is None:
        readable, _, _ = select.select(
            [master_fd], [], [], min(0.5, remaining(deadline))
        )
        if readable:
            try:
                os.read(master_fd, 65536)
            except OSError:
                break
    return process.wait(timeout=remaining(deadline))


def verify_sigterm_restores_tty(binary: pathlib.Path, root: pathlib.Path) -> None:
    env = hermetic_env(root)
    master_fd, slave_fd = pty.openpty()
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    original = termios.tcgetattr(slave_fd)

    def claim_controlling_tty() -> None:
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        [
            str(binary),
            "--session",
            "release-sigterm",
            "--socket",
            str(root / "sigterm.sock"),
            "--ephemeral",
        ],
        env=env,
        cwd=root,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        preexec_fn=claim_controlling_tty,
    )
    try:
        wait_for_interactive_ready(process, master_fd, slave_fd)
        process.send_signal(signal.SIGTERM)
        wait_for_interactive_exit(process, master_fd)
        restored = termios.tcgetattr(slave_fd)
        if restored != original:
            raise AssertionError(
                f"interactive SIGTERM did not restore tty state:\n"
                f"before={original!r}\nafter={restored!r}"
            )
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=TIMEOUT_SECONDS)
        os.close(master_fd)
        os.close(slave_fd)


def verify_runtime(runtime_family: str, architecture: str) -> None:
    machine = platform.machine().lower()
    expected_machines = {
        "x64": {"x86_64", "amd64"},
        "arm64": {"aarch64", "arm64"},
    }
    if machine not in expected_machines[architecture]:
        raise AssertionError(
            f"{architecture} row used non-native host architecture {machine!r}"
        )
    marker = {
        "glibc": pathlib.Path("/etc/debian_version"),
        "musl": pathlib.Path("/etc/alpine-release"),
    }[runtime_family]
    if not marker.is_file():
        raise AssertionError(
            f"{runtime_family} row ran in the wrong image; missing {marker}"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=pathlib.Path, required=True)
    parser.add_argument("--runtime-family", choices=("glibc", "musl"), required=True)
    parser.add_argument("--architecture", choices=("x64", "arm64"), required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise SystemExit(f"release binary is not executable: {binary}")

    verify_runtime(args.runtime_family, args.architecture)
    with tempfile.TemporaryDirectory(prefix="cmux-linux-release-behavior-") as temp:
        root = pathlib.Path(temp)
        verify_release_behavior(binary, root / "server")
        verify_sigterm_restores_tty(binary, root / "sigterm")
    print(
        f"release behavior passed: {args.runtime_family} {args.architecture}",
        flush=True,
    )


if __name__ == "__main__":
    main()
