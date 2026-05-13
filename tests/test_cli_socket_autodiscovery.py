#!/usr/bin/env python3
"""Regression test: CLI should auto-discover tagged debug sockets from CMUX_TAG."""

from __future__ import annotations

import glob
import os
import shutil
import socket
import subprocess
import tempfile
import threading
from pathlib import Path


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
    def __init__(
        self,
        socket_path: str,
        response: bytes = b"PONG\n",
        max_ping_requests: int = 1,
    ):
        self.socket_path = socket_path
        self.response = response
        self.max_ping_requests = max_ping_requests
        self.ready = threading.Event()
        self.error: Exception | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def wait_ready(self, timeout: float) -> bool:
        return self.ready.wait(timeout)

    def join(self, timeout: float) -> None:
        self._thread.join(timeout=timeout)

    def stop(self) -> None:
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(0.2)
            client.connect(self.socket_path)
            client.sendall(b"ping\n")
            try:
                client.recv(1024)
            except OSError:
                pass
            client.close()
        except OSError:
            pass
        self.join(timeout=2.0)

    def _run(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            os.makedirs(os.path.dirname(self.socket_path), exist_ok=True)
            if os.path.exists(self.socket_path):
                os.remove(self.socket_path)
            server.bind(self.socket_path)
            server.listen(1)
            server.settimeout(6.0)
            self.ready.set()

            # The CLI probes candidate sockets with a real ping before issuing
            # the command, so tests can opt into serving both requests.
            handled_pings = 0
            for _ in range(max(4, self.max_ping_requests + 2)):
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
                        conn.sendall(self.response)
                        handled_pings += 1
                        if handled_pings >= self.max_ping_requests:
                            return
            raise RuntimeError("Did not receive ping command on test socket")
        except Exception as exc:  # pragma: no cover - explicit surface on failure
            self.error = exc
            self.ready.set()
        finally:
            server.close()


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-cli-autodiscover-home-") as temp_home:
        tag = f"cli-autodiscover-{os.getpid()}"
        app_support_dir = Path(temp_home) / "Library/Application Support/cmux"
        socket_path = str(app_support_dir / f"com.cmuxterm.app.dev.{tag}.sock")
        release_socket_path = str(app_support_dir / "com.cmuxterm.app.sock")
        server = PingServer(socket_path, max_ping_requests=2)
        release_server = PingServer(release_socket_path, response=b"RELEASE\n")
        server.start()
        release_server.start()

        if not server.wait_ready(2.0) or not release_server.wait_ready(2.0):
            print("FAIL: socket server did not become ready")
            return 1

        if server.error is not None or release_server.error is not None:
            print(f"FAIL: socket server failed to start: {server.error or release_server.error}")
            return 1

        env = os.environ.copy()
        env["HOME"] = temp_home
        env["CMUX_SOCKET_PATH"] = "/tmp/cmux.sock"
        env["CMUX_TAG"] = tag
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        try:
            proc = subprocess.run(
                [cli_path, "ping"],
                text=True,
                capture_output=True,
                env=env,
                timeout=8,
                check=False,
            )
        except Exception as exc:
            print(f"FAIL: invoking cmux ping failed: {exc}")
            return 1
        finally:
            server.stop()
            release_server.stop()

        if server.error is not None:
            print(f"FAIL: socket server error: {server.error}")
            return 1

        if proc.returncode != 0:
            print("FAIL: cmux ping returned non-zero status")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            return 1

        if proc.stdout.strip() != "PONG":
            print("FAIL: cmux ping did not use auto-discovered tagged socket")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            return 1

    with tempfile.TemporaryDirectory(prefix="cmux-cli-autodiscover-home-") as temp_home:
        app_support_dir = Path(temp_home) / "Library/Application Support/cmux"
        default_socket_path = str(app_support_dir / "com.cmuxterm.app.sock")
        fallback_socket_path = str(app_support_dir / "com.cmuxterm.app.501.sock")
        app_support_dir.mkdir(parents=True, exist_ok=True)
        (app_support_dir / "last-socket-path").write_text(fallback_socket_path + "\n", encoding="utf-8")

        squatter_server = PingServer(default_socket_path, response=b"NOT_CMUX\n")
        fallback_server = PingServer(fallback_socket_path, max_ping_requests=2)
        squatter_server.start()
        fallback_server.start()

        if not squatter_server.wait_ready(2.0) or not fallback_server.wait_ready(2.0):
            print("FAIL: squatter/fallback socket server did not become ready")
            return 1

        if squatter_server.error is not None or fallback_server.error is not None:
            print(f"FAIL: socket server failed to start: {squatter_server.error or fallback_server.error}")
            return 1

        env = os.environ.copy()
        env["HOME"] = temp_home
        env.pop("CMUX_SOCKET_PATH", None)
        env.pop("CMUX_SOCKET", None)
        env.pop("CMUX_TAG", None)
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        try:
            proc = subprocess.run(
                [cli_path, "ping"],
                text=True,
                capture_output=True,
                env=env,
                timeout=8,
                check=False,
            )
        except Exception as exc:
            print(f"FAIL: invoking cmux ping for fallback failed: {exc}")
            return 1
        finally:
            squatter_server.stop()
            fallback_server.stop()

        if squatter_server.error is not None:
            print(f"FAIL: squatter socket server error: {squatter_server.error}")
            return 1
        if fallback_server.error is not None:
            print(f"FAIL: fallback socket server error: {fallback_server.error}")
            return 1

        if proc.returncode != 0:
            print("FAIL: cmux ping fallback returned non-zero status")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            return 1

        if proc.stdout.strip() != "PONG":
            print("FAIL: cmux ping did not skip non-cmux default socket")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            return 1

    with tempfile.TemporaryDirectory(prefix="cmux-cli-autodiscover-home-") as temp_home:
        app_support_dir = Path(temp_home) / "Library/Application Support/cmux"
        fallback_socket_path = str(app_support_dir / "com.cmuxterm.app.501.sock")
        variant_socket_paths = [
            str(app_support_dir / "com.cmuxterm.app.staging.sock"),
            str(app_support_dir / "com.cmuxterm.app.nightly.sock"),
            str(app_support_dir / "com.cmuxterm.app.dev.sock"),
        ]
        app_support_dir.mkdir(parents=True, exist_ok=True)
        (app_support_dir / "last-socket-path").write_text(fallback_socket_path + "\n", encoding="utf-8")

        variant_servers = [
            PingServer(path, max_ping_requests=1)
            for path in variant_socket_paths
        ]
        fallback_server = PingServer(fallback_socket_path, max_ping_requests=2)
        for server in variant_servers:
            server.start()
        fallback_server.start()

        if not all(server.wait_ready(2.0) for server in [*variant_servers, fallback_server]):
            print("FAIL: variant/fallback socket server did not become ready")
            return 1

        first_error = next((server.error for server in [*variant_servers, fallback_server] if server.error is not None), None)
        if first_error is not None:
            print(f"FAIL: socket server failed to start: {first_error}")
            return 1

        env = os.environ.copy()
        env["HOME"] = temp_home
        env.pop("CMUX_SOCKET_PATH", None)
        env.pop("CMUX_SOCKET", None)
        env.pop("CMUX_TAG", None)
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        try:
            proc = subprocess.run(
                [cli_path, "ping"],
                text=True,
                capture_output=True,
                env=env,
                timeout=8,
                check=False,
            )
        except Exception as exc:
            print(f"FAIL: invoking cmux ping for variant isolation failed: {exc}")
            return 1
        finally:
            for server in variant_servers:
                server.stop()
            fallback_server.stop()

        first_error = next((server.error for server in [*variant_servers, fallback_server] if server.error is not None), None)
        if first_error is not None:
            print(f"FAIL: socket server error: {first_error}")
            return 1

        if proc.returncode != 0:
            print("FAIL: cmux ping variant isolation returned non-zero status")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            return 1

        if proc.stdout.strip() != "PONG":
            print("FAIL: cmux ping did not skip non-release variant sockets")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            return 1

    print("PASS: cmux ping auto-discovers tagged and protocol-verified fallback sockets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
