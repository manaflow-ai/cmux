#!/usr/bin/env python3
"""Regression tests for CLI socket autodiscovery."""

from __future__ import annotations

import glob
import os
import plistlib
import shutil
import socket
import subprocess
import tempfile
import threading


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
                        conn.sendall(b"PONG\n")
                        return
            raise RuntimeError("Did not receive ping command on test socket")
        except Exception as exc:  # pragma: no cover - explicit surface on failure
            self.error = exc
            self.ready.set()
        finally:
            server.close()


def write_marker(home: str, marker_name: str, socket_path: str) -> None:
    app_support = os.path.join(home, "Library", "Application Support", "cmux")
    os.makedirs(app_support, exist_ok=True)
    with open(os.path.join(app_support, marker_name), "w", encoding="utf-8") as f:
        f.write(f"{socket_path}\n")


def bundled_cli_for_variant(cli_path: str, root: str, app_name: str, bundle_id: str) -> str:
    app_dir = os.path.join(root, f"{app_name}.app")
    bin_dir = os.path.join(app_dir, "Contents", "Resources", "bin")
    os.makedirs(bin_dir, exist_ok=True)
    bundled_cli = os.path.join(bin_dir, "cmux")
    shutil.copy2(cli_path, bundled_cli)
    os.chmod(bundled_cli, 0o755)

    plist_path = os.path.join(app_dir, "Contents", "Info.plist")
    os.makedirs(os.path.dirname(plist_path), exist_ok=True)
    with open(plist_path, "wb") as f:
        plistlib.dump(
            {
                "CFBundleIdentifier": bundle_id,
                "CFBundleName": app_name,
                "CFBundleDisplayName": app_name,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.0-test",
                "CFBundleVersion": "1",
            },
            f,
        )
    return bundled_cli


def run_ping(cli_path: str, home: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["HOME"] = home
    env.pop("CMUX_SOCKET_PATH", None)
    env.pop("CMUX_SOCKET", None)
    env.pop("CMUX_BUNDLE_ID", None)
    env.pop("CMUX_TAG", None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    return subprocess.run(
        [cli_path, "ping"],
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )


def expect_ping_uses_socket(cli_path: str, home: str, socket_path: str, label: str) -> bool:
    server = PingServer(socket_path)
    server.start()

    if not server.wait_ready(2.0):
        print(f"FAIL: {label} socket server did not become ready")
        return False

    if server.error is not None:
        print(f"FAIL: {label} socket server failed to start: {server.error}")
        return False

    try:
        proc = run_ping(cli_path, home)
    except Exception as exc:
        print(f"FAIL: invoking {label} cmux ping failed: {exc}")
        return False
    finally:
        server.join(timeout=2.0)
        try:
            os.remove(socket_path)
        except OSError:
            pass

    if server.error is not None:
        print(f"FAIL: {label} socket server error: {server.error}")
        return False

    if proc.returncode != 0:
        print(f"FAIL: {label} cmux ping returned non-zero status")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    if proc.stdout.strip() != "PONG":
        print(f"FAIL: {label} cmux ping did not use the expected socket")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    return True


def test_variant_last_socket_markers(cli_path: str) -> bool:
    pid = os.getpid()
    stable_socket = f"/tmp/cmux-issue3542-stable-{pid}.sock"
    nightly_socket = f"/tmp/cmux-issue3542-nightly-{pid}.sock"
    dev_agent_socket = f"/tmp/cmux-issue3542-dev-agent-{pid}.sock"

    with tempfile.TemporaryDirectory(prefix="cmux-cli-variant-home-") as home, \
            tempfile.TemporaryDirectory(prefix="cmux-cli-variant-apps-") as apps:
        stable_cli = bundled_cli_for_variant(
            cli_path,
            apps,
            "cmux",
            "com.cmuxterm.app",
        )
        nightly_cli = bundled_cli_for_variant(
            cli_path,
            apps,
            "cmux NIGHTLY",
            "com.cmuxterm.app.nightly",
        )
        dev_agent_cli = bundled_cli_for_variant(
            cli_path,
            apps,
            "cmux DEV agent",
            "com.cmuxterm.app.debug.agent",
        )

        write_marker(home, "last-socket-path", stable_socket)
        write_marker(home, "nightly-last-socket-path", nightly_socket)
        write_marker(home, "dev-agent-last-socket-path", dev_agent_socket)

        try:
            if not expect_ping_uses_socket(stable_cli, home, stable_socket, "stable"):
                return False
            if not expect_ping_uses_socket(nightly_cli, home, nightly_socket, "nightly"):
                return False
            if not expect_ping_uses_socket(dev_agent_cli, home, dev_agent_socket, "dev-agent"):
                return False
        finally:
            for path in [stable_socket, nightly_socket, dev_agent_socket]:
                try:
                    os.remove(path)
                except OSError:
                    pass

    print("PASS: bundled CLIs read variant-specific socket markers")
    return True


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    tag = f"cli-autodiscover-{os.getpid()}"
    socket_path = f"/tmp/cmux-debug-{tag}.sock"
    server = PingServer(socket_path)
    server.start()

    if not server.wait_ready(2.0):
        print("FAIL: socket server did not become ready")
        return 1

    if server.error is not None:
        print(f"FAIL: socket server failed to start: {server.error}")
        return 1

    env = os.environ.copy()
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
        server.join(timeout=2.0)
        try:
            os.remove(socket_path)
        except OSError:
            pass

    if server.error is not None:
        print(f"FAIL: socket server error: {server.error}")
        return 1

    if proc.returncode != 0:
        print("FAIL: cmux ping returned non-zero status")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return 1

    if proc.stdout.strip() != "PONG":
        print("FAIL: cmux ping did not use auto-discovered socket")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return 1

    if not test_variant_last_socket_markers(cli_path):
        return 1

    print("PASS: cmux ping auto-discovers tagged socket from CMUX_TAG")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
