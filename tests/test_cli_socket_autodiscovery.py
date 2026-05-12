#!/usr/bin/env python3
"""Regression tests for CLI socket discovery and stale-socket recovery."""

from __future__ import annotations

import glob
import os
import shutil
import socket
import subprocess
import threading
import tempfile


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


class PingServer:
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.ready = threading.Event()
        self.got_ping = threading.Event()
        self.error: Exception | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def wait_ready(self, timeout: float) -> bool:
        return self.ready.wait(timeout)

    def join(self, timeout: float) -> None:
        self._thread.join(timeout=timeout)

    def _run(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(self.socket_path):
                os.remove(self.socket_path)
            server.bind(self.socket_path)
            server.listen(1)
            server.settimeout(6.0)
            self.ready.set()

            # The CLI may probe candidate sockets with a connect-only check before
            # issuing the actual command, so handle more than one connection.
            for _ in range(4):
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(2.0)
                    data = b""
                    while b"\n" not in data:
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        data += chunk

                    if b"ping" in data:
                        self.got_ping.set()
                        conn.sendall(b"PONG\n")
                        return
            raise RuntimeError("Did not receive ping command on test socket")
        except Exception as exc:  # pragma: no cover - explicit surface on failure
            self.error = exc
            self.ready.set()
        finally:
            server.close()


def invoke_ping(cli_path: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [cli_path, "ping"],
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )


def run_with_server(socket_path: str, cli_path: str, env: dict[str, str]) -> tuple[subprocess.CompletedProcess[str] | None, str | None]:
    server = PingServer(socket_path)
    server.start()

    if not server.wait_ready(2.0):
        return None, "socket server did not become ready"

    if server.error is not None:
        return None, f"socket server failed to start: {server.error}"

    try:
        proc = invoke_ping(cli_path, env)
    except Exception as exc:
        return None, f"invoking cmux ping failed: {exc}"
    finally:
        server.join(timeout=2.0)
        try:
            os.remove(socket_path)
        except OSError:
            pass

    if server.error is not None:
        return proc, f"socket server error: {server.error}"
    return proc, None


def assert_pong(proc: subprocess.CompletedProcess[str] | None, error: str | None, label: str) -> bool:
    if error is not None:
        print(f"FAIL: {label}: {error}")
        return False
    assert proc is not None
    if proc.returncode != 0:
        print(f"FAIL: {label}: cmux ping returned non-zero status")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False
    if proc.stdout.strip() != "PONG":
        print(f"FAIL: {label}: cmux ping did not use expected socket")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False
    return True


def base_env() -> dict[str, str]:
    env = os.environ.copy()
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    return env


def test_tagged_socket_autodiscovery(cli_path: str) -> bool:
    tag = f"cli-autodiscover-{os.getpid()}"
    socket_path = f"/tmp/cmux-debug-{tag}.sock"
    env = base_env()
    env["CMUX_SOCKET_PATH"] = "/tmp/cmux.sock"
    env["CMUX_TAG"] = tag

    proc, error = run_with_server(socket_path, cli_path, env)
    if not assert_pong(proc, error, "tagged autodiscovery"):
        return False

    print("PASS: cmux ping auto-discovers tagged socket from CMUX_TAG")
    return True


def test_stale_inherited_socket_recovers_to_last_socket(cli_path: str) -> bool:
    with tempfile.TemporaryDirectory(prefix="cmux-cli-socket-home-") as home:
        socket_path = f"/tmp/cmux-recovery-{os.getpid()}.sock"
        app_support = os.path.join(home, "Library", "Application Support", "cmux")
        os.makedirs(app_support, mode=0o700)
        with open(os.path.join(app_support, "last-socket-path"), "w", encoding="utf-8") as handle:
            handle.write(socket_path + "\n")

        env = base_env()
        env["HOME"] = home
        env["CMUX_SOCKET_PATH"] = f"/tmp/cmux-dead-{os.getpid()}.sock"

        proc, error = run_with_server(socket_path, cli_path, env)
        if not assert_pong(proc, error, "stale inherited socket recovery"):
            return False

    print("PASS: stale inherited CMUX_SOCKET_PATH recovers to live last-socket hint")
    return True


def test_untagged_shell_does_not_grab_tagged_dev_socket(cli_path: str) -> bool:
    tag = f"cli-untagged-{os.getpid()}"
    socket_path = f"/tmp/cmux-debug-{tag}.sock"
    with tempfile.TemporaryDirectory(prefix="cmux-cli-untagged-home-") as home:
        env = base_env()
        env["HOME"] = home
        env.pop("CMUX_TAG", None)
        env.pop("CMUX_SOCKET_PATH", None)

        server = PingServer(socket_path)
        server.start()
        if not server.wait_ready(2.0):
            print("FAIL: untagged guard: socket server did not become ready")
            return False

        try:
            _ = invoke_ping(cli_path, env)
        except Exception as exc:
            print(f"FAIL: untagged guard: invoking cmux ping failed: {exc}")
            return False
        finally:
            server.join(timeout=0.5)
            try:
                os.remove(socket_path)
            except OSError:
                pass

        if server.got_ping.is_set():
            print("FAIL: untagged guard: cmux ping incorrectly used a tagged DEV socket")
            return False

    print("PASS: untagged cmux ping does not auto-discover arbitrary tagged DEV sockets")
    return True


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    checks = [
        test_tagged_socket_autodiscovery,
        test_stale_inherited_socket_recovers_to_last_socket,
        test_untagged_shell_does_not_grab_tagged_dev_socket,
    ]
    for check in checks:
        if not check(cli_path):
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
