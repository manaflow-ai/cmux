#!/usr/bin/env python3
"""Regression tests for CLI socket autodiscovery."""

from __future__ import annotations

import glob
import os
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time


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
        accept_timeout: float = 6.0,
    ):
        self.socket_path = socket_path
        self.response = response
        self.accept_timeout = accept_timeout
        self.ready = threading.Event()
        self._done = threading.Event()
        self.error: Exception | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._connection_threads: list[threading.Thread] = []

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
            server.listen(8)
            self.ready.set()

            # The CLI may probe candidate sockets with a connect-only check before
            # issuing the actual command, so keep accepting until the ping arrives
            # or the test socket times out.
            deadline = time.monotonic() + self.accept_timeout
            while not self._done.is_set():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return
                server.settimeout(min(0.2, remaining))
                try:
                    conn, _ = server.accept()
                # GitHub's macOS Python can report socket polling timeouts as
                # socket.timeout rather than built-in TimeoutError.
                except (socket.timeout, TimeoutError):
                    continue
                connection_thread = threading.Thread(
                    target=self._handle_connection,
                    args=(conn,),
                    daemon=True,
                )
                self._connection_threads.append(connection_thread)
                connection_thread.start()
        except Exception as exc:  # pragma: no cover - explicit surface on failure
            self.error = exc
            self.ready.set()
        finally:
            self._done.set()
            server.close()
            for connection_thread in self._connection_threads:
                connection_thread.join(timeout=1.0)

    def _handle_connection(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(2.0)
            data = b""
            try:
                while b"\n" not in data:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
            except (ConnectionResetError, socket.timeout, TimeoutError):
                return

            if b"ping" in data:
                conn.sendall(self.response)
                self._done.set()


def write_marker(home: str, marker_name: str, socket_path: str) -> None:
    app_support = os.path.join(home, ".local", "state", "cmux")
    os.makedirs(app_support, exist_ok=True)
    with open(os.path.join(app_support, marker_name), "w", encoding="utf-8") as f:
        f.write(f"{socket_path}\n")


def temporary_socket_home(prefix: str) -> tempfile.TemporaryDirectory:
    # Darwin caps Unix socket paths at a little over 100 bytes. Keep fake HOME
    # roots short because stable sockets live under ~/.local/state/cmux.
    return tempfile.TemporaryDirectory(prefix=prefix, dir="/tmp")


def copy_runtime_frameworks(cli_path: str, fixture_contents: str) -> None:
    frameworks_dir = os.path.join(fixture_contents, "Frameworks")
    os.makedirs(frameworks_dir, exist_ok=True)

    search_roots: list[str] = []
    current = os.path.dirname(cli_path)
    for _ in range(4):
        search_roots.append(os.path.join(current, "Frameworks"))
        search_roots.append(os.path.join(current, "PackageFrameworks"))
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent

    for search_root in search_roots:
        if not os.path.isdir(search_root):
            continue
        for framework_name in sorted(os.listdir(search_root)):
            if not framework_name.endswith(".framework"):
                continue
            source = os.path.join(search_root, framework_name)
            destination = os.path.join(frameworks_dir, framework_name)
            if os.path.isdir(source) and not os.path.exists(destination):
                shutil.copytree(source, destination, symlinks=True)


def bundled_cli_for_variant(cli_path: str, root: str, app_name: str, bundle_id: str) -> str:
    app_dir = os.path.join(root, f"{app_name}.app")
    contents_dir = os.path.join(app_dir, "Contents")
    bin_dir = os.path.join(app_dir, "Contents", "Resources", "bin")
    os.makedirs(bin_dir, exist_ok=True)
    bundled_cli = os.path.join(bin_dir, "cmux")
    shutil.copy2(cli_path, bundled_cli)
    os.chmod(bundled_cli, 0o755)
    copy_runtime_frameworks(cli_path, contents_dir)

    plist_path = os.path.join(contents_dir, "Info.plist")
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


def run_ping(
    cli_path: str,
    home: str,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["HOME"] = home
    env["CFFIXED_USER_HOME"] = home
    env.pop("CMUX_SOCKET_PATH", None)
    env.pop("CMUX_SOCKET", None)
    env.pop("CMUX_BUNDLE_ID", None)
    env.pop("CMUX_TAG", None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    if extra_env:
        env.update(extra_env)
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


def expect_ping_ignores_dev_tag(
    cli_path: str,
    home: str,
    expected_socket_path: str,
    rogue_socket_path: str,
    rogue_tag: str,
    label: str,
) -> bool:
    expected_server = PingServer(expected_socket_path)
    rogue_server = PingServer(rogue_socket_path, response=b"WRONG\n")
    expected_server.start()
    rogue_server.start()

    for server_label, server in [
        (label, expected_server),
        ("rogue dev", rogue_server),
    ]:
        if not server.wait_ready(2.0):
            print(f"FAIL: {server_label} socket server did not become ready")
            return False
        if server.error is not None:
            print(f"FAIL: {server_label} socket server failed to start: {server.error}")
            return False

    try:
        proc = run_ping(cli_path, home, extra_env={"CMUX_TAG": rogue_tag})
    except Exception as exc:
        print(f"FAIL: invoking {label} cmux ping failed: {exc}")
        return False
    finally:
        expected_server.join(timeout=2.0)
        rogue_server.join(timeout=2.0)
        for path in [expected_socket_path, rogue_socket_path]:
            try:
                os.remove(path)
            except OSError:
                pass

    if proc.returncode != 0:
        print(f"FAIL: {label} cmux ping returned non-zero status")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    if proc.stdout.strip() != "PONG":
        print(f"FAIL: {label} cmux ping followed CMUX_TAG to the rogue dev socket")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    return True


def expect_ping_does_not_use_socket(
    cli_path: str,
    home: str,
    socket_path: str,
    label: str,
) -> bool:
    os.makedirs(os.path.dirname(socket_path), exist_ok=True)
    server = PingServer(socket_path, response=b"WRONG\n", accept_timeout=1.0)
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
        print(f"FAIL: invoking {label} cmux ping failed unexpectedly: {exc}")
        return False
    finally:
        server.join(timeout=2.0)
        try:
            os.remove(socket_path)
        except OSError:
            pass

    if proc.stdout.strip() == "WRONG":
        print(f"FAIL: {label} cmux ping used the stable socket fallback")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    return True


def python_client_default_bundle_id(extra_env: dict[str, str]) -> str:
    env = os.environ.copy()
    env.pop("CMUX_SOCKET_PATH", None)
    env.pop("CMUX_SOCKET", None)
    env.pop("CMUX_BUNDLE_ID", None)
    env.pop("CMUX_TAG", None)
    env.update(extra_env)

    tests_dir = os.path.dirname(os.path.abspath(__file__))
    python_path = env.get("PYTHONPATH")
    env["PYTHONPATH"] = tests_dir if not python_path else f"{tests_dir}{os.pathsep}{python_path}"

    proc = subprocess.run(
        [sys.executable, "-c", "from cmux import cmux; print(cmux.default_bundle_id())"],
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"cmux.py bundle resolution failed: {proc.stderr!r}")
    return proc.stdout.strip()


def python_client_default_socket_path(extra_env: dict[str, str]) -> str:
    env = os.environ.copy()
    env.pop("CMUX_SOCKET_PATH", None)
    env.pop("CMUX_SOCKET", None)
    env.pop("CMUX_BUNDLE_ID", None)
    env.pop("CMUX_TAG", None)
    env.update(extra_env)

    tests_dir = os.path.dirname(os.path.abspath(__file__))
    python_path = env.get("PYTHONPATH")
    env["PYTHONPATH"] = tests_dir if not python_path else f"{tests_dir}{os.pathsep}{python_path}"

    proc = subprocess.run(
        [sys.executable, "-c", "from cmux import cmux; print(cmux.default_socket_path())"],
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"cmux.py socket resolution failed: {proc.stderr!r}")
    return proc.stdout.strip()


def test_python_client_ignores_unknown_bundle_env() -> bool:
    expected_tagged_debug = "com.cmuxterm.app.debug.variant.test.tag"
    actual = python_client_default_bundle_id({
        "CMUX_BUNDLE_ID": "com.example.stale.bundle",
        "CMUX_TAG": "variant-test-tag",
    })
    if actual != expected_tagged_debug:
        print("FAIL: python client trusted unknown CMUX_BUNDLE_ID over CMUX_TAG")
        print(f"expected={expected_tagged_debug!r}")
        print(f"actual={actual!r}")
        return False

    actual = python_client_default_bundle_id({
        "CMUX_BUNDLE_ID": "com.cmuxterm.app",
        "CMUX_TAG": "rogue-stable-tag",
    })
    if actual != "com.cmuxterm.app":
        print("FAIL: python client rejected known stable CMUX_BUNDLE_ID")
        print(f"actual={actual!r}")
        return False

    print("PASS: python client ignores unknown CMUX_BUNDLE_ID values")
    return True


def test_python_client_treats_stable_override_as_implicit() -> bool:
    tag = f"python-stale-stable-{os.getpid()}"
    expected_socket = f"/tmp/cmux-debug-{tag}.sock"

    with temporary_socket_home("cmux-py-") as home:
        app_support = os.path.join(home, ".local", "state", "cmux")
        os.makedirs(app_support, exist_ok=True)
        stable_socket = os.path.join(app_support, "cmux.sock")

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(stable_socket):
                os.remove(stable_socket)
            server.bind(stable_socket)
            server.listen(1)

            actual = python_client_default_socket_path({
                "HOME": home,
                "CFFIXED_USER_HOME": home,
                "CMUX_SOCKET_PATH": stable_socket,
                "CMUX_TAG": tag,
            })
        finally:
            server.close()
            try:
                os.remove(stable_socket)
            except OSError:
                pass

    if actual != expected_socket:
        print("FAIL: python client followed a stale stable CMUX_SOCKET_PATH")
        print(f"expected={expected_socket!r}")
        print(f"actual={actual!r}")
        return False

    print("PASS: python client treats stable socket overrides as implicit for tagged debug")
    return True


def test_variant_last_socket_markers(cli_path: str) -> bool:
    pid = os.getpid()
    stable_socket = f"/tmp/cmux-issue3542-stable-{pid}.sock"
    nightly_socket = f"/tmp/cmux-issue3542-nightly-{pid}.sock"
    dev_agent_socket = f"/tmp/cmux-issue3542-dev-agent-{pid}.sock"
    rogue_stable_socket = f"/tmp/cmux-debug-rogue-stable-{pid}.sock"
    rogue_stable_tag = f"rogue-stable-{pid}"
    rogue_nightly_socket = f"/tmp/cmux-debug-rogue-nightly-{pid}.sock"
    rogue_nightly_tag = f"rogue-nightly-{pid}"
    rogue_dev_agent_socket = f"/tmp/cmux-debug-rogue-dev-agent-{pid}.sock"
    rogue_dev_agent_tag = f"rogue-dev-agent-{pid}"

    with temporary_socket_home("cmux-home-") as home, \
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
        isolated_nightly_cli = bundled_cli_for_variant(
            cli_path,
            apps,
            "cmux NIGHTLY issue3542",
            "com.cmuxterm.app.nightly.issue3542",
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
            if not expect_ping_ignores_dev_tag(
                stable_cli,
                home,
                stable_socket,
                rogue_stable_socket,
                rogue_stable_tag,
                "stable with stray CMUX_TAG",
            ):
                return False
            if not expect_ping_ignores_dev_tag(
                nightly_cli,
                home,
                nightly_socket,
                rogue_nightly_socket,
                rogue_nightly_tag,
                "nightly with stray CMUX_TAG",
            ):
                return False
            if not expect_ping_ignores_dev_tag(
                dev_agent_cli,
                home,
                dev_agent_socket,
                rogue_dev_agent_socket,
                rogue_dev_agent_tag,
                "dev-agent with stray CMUX_TAG",
            ):
                return False

            stable_default_socket = os.path.join(
                home,
                ".local",
                "state",
                "cmux",
                "cmux.sock",
            )
            if not expect_ping_does_not_use_socket(
                isolated_nightly_cli,
                home,
                stable_default_socket,
                "isolated nightly without marker",
            ):
                return False
        finally:
            for path in [
                stable_socket,
                nightly_socket,
                dev_agent_socket,
                rogue_stable_socket,
                rogue_nightly_socket,
                rogue_dev_agent_socket,
            ]:
                try:
                    os.remove(path)
                except OSError:
                    pass

    print("PASS: bundled CLIs read variant-specific socket markers")
    return True


def test_base_debug_cli_discovers_cmux_tag(cli_path: str) -> bool:
    tag = f"cli-autodiscover-{os.getpid()}"
    socket_path = f"/tmp/cmux-debug-{tag}.sock"
    server = PingServer(socket_path)
    server.start()

    if not server.wait_ready(2.0):
        print("FAIL: socket server did not become ready")
        return False

    if server.error is not None:
        print(f"FAIL: socket server failed to start: {server.error}")
        return False

    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = "/tmp/cmux.sock"
    env["CMUX_TAG"] = tag
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

    try:
        with tempfile.TemporaryDirectory(prefix="cmux-cli-base-debug-app-") as apps:
            debug_cli = bundled_cli_for_variant(
                cli_path,
                apps,
                "cmux DEV issue3542",
                "com.cmuxterm.app.debug",
            )
            proc = subprocess.run(
                [debug_cli, "ping"],
                text=True,
                capture_output=True,
                env=env,
                timeout=8,
                check=False,
            )
    except Exception as exc:
        print(f"FAIL: invoking cmux ping failed: {exc}")
        return False
    finally:
        server.join(timeout=2.0)
        try:
            os.remove(socket_path)
        except OSError:
            pass

    if server.error is not None:
        print(f"FAIL: socket server error: {server.error}")
        return False

    if proc.returncode != 0:
        print("FAIL: cmux ping returned non-zero status")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    if proc.stdout.strip() != "PONG":
        print("FAIL: cmux ping did not use auto-discovered socket")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    return True


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    if not test_base_debug_cli_discovers_cmux_tag(cli_path):
        return 1

    if not test_variant_last_socket_markers(cli_path):
        return 1

    if not test_python_client_ignores_unknown_bundle_env():
        return 1

    if not test_python_client_treats_stable_override_as_implicit():
        return 1

    print("PASS: cmux ping auto-discovers tagged socket from CMUX_TAG")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
