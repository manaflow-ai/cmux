#!/usr/bin/env python3
"""
Tests for socket access control (process ancestry check).

In cmuxOnly mode (default), only processes descended from the cmux
app process can connect. External processes (e.g., SSH) are rejected.

Test strategy:
  Phase 1: cmuxOnly — external processes get rejected
  Phase 2: cmuxOnly — internal process CAN connect (inject via shell rc)
  Phase 3: allowAll env override — existing test commands still work

Usage:
    python3 test_socket_access.py
"""

import os
import socket
import subprocess
import sys
import tempfile
import time
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmux import cmux, cmuxError


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


def _find_socket_path():
    return cmux().socket_path


def _raw_connect(socket_path: str, timeout: float = 3.0):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(socket_path)
    return sock


def _raw_send(sock, command: str, timeout: float = 3.0) -> str:
    sock.sendall((command + "\n").encode())
    data = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
        except socket.timeout:
            break
    return data.decode().strip()


def _find_app():
    r = subprocess.run(
        ["find", "/Users/cmux/Library/Developer/Xcode/DerivedData",
         "-path", "*/Build/Products/Debug/cmux DEV.app", "-print", "-quit"],
        capture_output=True, text=True, timeout=10
    )
    return r.stdout.strip()


def _wait_for_socket(socket_path: str, timeout: float = 10.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(socket_path):
            return True
        time.sleep(0.5)
    return False


def _kill_cmux():
    subprocess.run(["pkill", "-x", "cmux DEV"], capture_output=True)
    time.sleep(1.5)


def _launch_cmux(app_path: str, socket_path: str, mode: str = None):
    env_args = []
    if mode:
        env_args = ["--env", f"CMUX_SOCKET_MODE={mode}"]
    subprocess.Popen(["open", "-a", app_path] + env_args)
    if not _wait_for_socket(socket_path):
        raise RuntimeError(f"Socket {socket_path} not created after launch")
    time.sleep(8)


def _external_ping_response(socket_path: str) -> Optional[str]:
    try:
        sock = _raw_connect(socket_path, timeout=2.0)
        try:
            return _raw_send(sock, "ping", timeout=2.0)
        finally:
            sock.close()
    except Exception:
        return None


def _is_external_allowed(socket_path: str) -> bool:
    return _external_ping_response(socket_path) == "PONG"


# ---------------------------------------------------------------------------
# External rejection tests (Phase 1)
# ---------------------------------------------------------------------------

def test_external_rejected(socket_path: str) -> TestResult:
    result = TestResult("External process rejected")
    try:
        sock = _raw_connect(socket_path)
        try:
            response = _raw_send(sock, "ping")
            if "Access denied" in response:
                result.success(f"Correctly rejected")
            elif response == "PONG":
                result.failure("External allowed — ancestry check not working")
            else:
                result.failure(f"Unexpected: {response!r}")
        finally:
            sock.close()
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


def test_connection_closed_after_reject(socket_path: str) -> TestResult:
    result = TestResult("Connection closed after rejection")
    try:
        sock = _raw_connect(socket_path)
        try:
            _raw_send(sock, "ping")
            try:
                sock.sendall(b"list_tabs\n")
                time.sleep(0.3)
                data = sock.recv(4096)
                if data:
                    result.failure(f"Got response after rejection: {data.decode().strip()!r}")
                else:
                    result.success("Connection properly closed")
            except (BrokenPipeError, ConnectionResetError, OSError):
                result.success("Connection properly closed")
        finally:
            sock.close()
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


def test_rapid_reconnect(socket_path: str) -> TestResult:
    result = TestResult("Rapid reconnect all rejected")
    try:
        for i in range(20):
            try:
                sock = _raw_connect(socket_path, timeout=2.0)
                response = _raw_send(sock, "ping", timeout=1.0)
                sock.close()
            except (BrokenPipeError, ConnectionResetError, OSError):
                # Server closed connection before we could read — counts as rejection
                continue
            if "Access denied" not in response and "ERROR" not in response:
                result.failure(f"Iteration {i}: not rejected: {response!r}")
                return result
        result.success("All 20 rejected")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


def test_subprocess_rejected(socket_path: str) -> TestResult:
    result = TestResult("Subprocess of external rejected")
    try:
        script = f"""
import socket, sys, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(3)
sock.connect("{socket_path}")
sock.sendall(b"ping\\n")
data = b""
deadline = time.time() + 3
while time.time() < deadline:
    try:
        chunk = sock.recv(4096)
        if not chunk: break
        data += chunk
        if b"\\n" in data: break
    except socket.timeout: break
sock.close()
resp = data.decode().strip()
if "Access denied" in resp or "ERROR" in resp:
    print("REJECTED"); sys.exit(0)
else:
    print("ALLOWED:" + resp); sys.exit(1)
"""
        proc = subprocess.run(
            [sys.executable, "-c", script],
            capture_output=True, text=True, timeout=10
        )
        if proc.returncode == 0 and "REJECTED" in proc.stdout:
            result.success("Child process rejected")
        else:
            result.failure(f"exit={proc.returncode} out={proc.stdout!r}")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


# ---------------------------------------------------------------------------
# Internal process test (Phase 2)
# ---------------------------------------------------------------------------

def test_internal_process_allowed(socket_path: str, app_path: str) -> TestResult:
    """
    Verify a cmux-spawned terminal process CAN connect in cmuxOnly mode.
    Inject a test via the shell rc file, then launch cmux in cmuxOnly mode.
    The shell (a descendant of cmux) runs the test on startup.
    """
    result = TestResult("Internal process can connect (cmuxOnly)")
    marker = os.path.join(tempfile.gettempdir(), f"cmux_internal_{os.getpid()}")
    hook_file = os.path.join(tempfile.gettempdir(), f"cmux_rc_hook_{os.getpid()}.sh")
    zprofile_path = os.path.expanduser("~/.zprofile")

    try:
        for f in [marker, hook_file]:
            if os.path.exists(f):
                os.unlink(f)

        # Write test script: connects to socket, sends ping, writes result
        with open(hook_file, "w") as f:
            f.write(f"""#!/bin/bash
# One-shot test hook — self-removes after running
RESULT=$(echo "ping" | nc -U "{socket_path}" 2>/dev/null | head -1)
if [ "$RESULT" = "PONG" ]; then
    echo "OK" > "{marker}"
else
    echo "FAIL:$RESULT" > "{marker}"
fi
""")
        os.chmod(hook_file, 0o755)

        # Append hook to .zprofile (runs on terminal startup)
        zprofile_backup = None
        if os.path.exists(zprofile_path):
            with open(zprofile_path) as f:
                zprofile_backup = f.read()

        hook_line = f'\n[ -f "{hook_file}" ] && bash "{hook_file}" && rm -f "{hook_file}"\n'
        with open(zprofile_path, "a") as f:
            f.write(hook_line)

        # Kill existing cmux, launch in cmuxOnly mode (default)
        _kill_cmux()
        _launch_cmux(app_path, socket_path)

        # Wait for marker (the shell sources .zprofile on startup)
        for _ in range(40):
            if os.path.exists(marker):
                break
            time.sleep(0.5)

        if not os.path.exists(marker):
            result.failure("Marker not created — hook didn't run in terminal")
            return result

        with open(marker) as f:
            content = f.read().strip()

        if content == "OK":
            result.success("Internal process pinged socket successfully in cmuxOnly mode")
        else:
            result.failure(f"Internal process got: {content!r}")

    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    finally:
        # Restore .zprofile
        if zprofile_backup is not None:
            with open(zprofile_path, "w") as f:
                f.write(zprofile_backup)
        elif os.path.exists(zprofile_path):
            # Remove the hook line we added
            with open(zprofile_path) as f:
                content = f.read()
            content = content.replace(hook_line, "")
            if content.strip():
                with open(zprofile_path, "w") as f:
                    f.write(content)
            else:
                os.unlink(zprofile_path)

        for f in [marker, hook_file]:
            try:
                os.unlink(f)
            except OSError:
                pass

    return result


# ---------------------------------------------------------------------------
# allowAll mode test (Phase 3)
# ---------------------------------------------------------------------------

def test_allowall_mode_works(socket_path: str, app_path: str) -> TestResult:
    """Verify CMUX_SOCKET_MODE=allowAll bypasses ancestry check."""
    result = TestResult("allowAll mode allows external")
    try:
        _kill_cmux()
        _launch_cmux(app_path, socket_path, mode="allowAll")

        sock = _raw_connect(socket_path)
        response = _raw_send(sock, "ping")
        sock.close()

        if response == "PONG":
            result.success("External process allowed in allowAll mode")
        else:
            result.failure(f"Unexpected response: {response!r}")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run_tests():
    print("=" * 60)
    print("cmux Socket Access Control Tests")
    print("=" * 60)
    print()

    app_path = _find_app()
    if not app_path:
        print("Error: Could not find cmux DEV.app in DerivedData")
        return 1
    print(f"App: {app_path}")

    socket_path = _find_socket_path()
    print(f"Socket: {socket_path}")
    print()

    # Preserve caller intent when provided, otherwise detect current behavior
    # so this test doesn't leak socket mode changes into subsequent tests.
    env_socket_mode = os.environ.get("CMUX_SOCKET_MODE", "").strip()
    if env_socket_mode == "allowAll":
        restore_mode = "allowAll"
    else:
        restore_mode = "allowAll" if _is_external_allowed(socket_path) else None
    print(f"Restore mode after test: {restore_mode or 'cmuxOnly'}")
    print()

    results = []

    def run_test(test_fn, *args):
        name = test_fn.__name__.replace("test_", "").replace("_", " ").title()
        print(f"  Testing {name}...")
        r = test_fn(*args)
        results.append(r)
        status = "\u2705" if r.passed else "\u274c"
        print(f"    {status} {r.message}")

    # ── Phase 1: cmuxOnly — external rejection ──
    print("Phase 1: cmuxOnly mode — external rejection")
    print("-" * 50)

    # Ensure cmux is running in cmuxOnly mode
    _kill_cmux()
    print("  Launching cmux in cmuxOnly mode...")
    _launch_cmux(app_path, socket_path)

    run_test(test_external_rejected, socket_path)
    run_test(test_connection_closed_after_reject, socket_path)
    run_test(test_rapid_reconnect, socket_path)
    run_test(test_subprocess_rejected, socket_path)
    print()

    # ── Phase 2: cmuxOnly — internal process CAN connect ──
    print("Phase 2: cmuxOnly mode — internal process allowed")
    print("-" * 50)

    run_test(test_internal_process_allowed, socket_path, app_path)
    print()

    # ── Phase 3: allowAll env override ──
    print("Phase 3: allowAll mode — env override bypasses check")
    print("-" * 50)

    run_test(test_allowall_mode_works, socket_path, app_path)
    print()

    # ── Cleanup: restore detected mode for downstream tests ──
    _kill_cmux()
    _launch_cmux(app_path, socket_path, mode=restore_mode)

    restore_result = TestResult("Socket mode restored after test")
    final_response = _external_ping_response(socket_path)
    expected_allow = restore_mode == "allowAll"
    if final_response is None:
        restore_result.failure("No response while validating restored socket mode")
    elif expected_allow and final_response == "PONG":
        restore_result.success("Restored to allowAll")
    elif not expected_allow and "Access denied" in final_response:
        restore_result.success("Restored to cmuxOnly")
    else:
        restore_result.failure(
            f"Unexpected post-restore response {final_response!r} for mode {restore_mode or 'cmuxOnly'}"
        )
    results.append(restore_result)

    # ── Summary ──
    print("=" * 60)
    print("Summary")
    print("=" * 60)

    passed = sum(1 for r in results if r.passed)
    total = len(results)

    for r in results:
        status = "\u2705 PASS" if r.passed else "\u274c FAIL"
        print(f"  {r.name}: {status}")
        if not r.passed and r.message:
            print(f"      {r.message}")

    print()
    print(f"Passed: {passed}/{total}")

    if passed == total:
        print("\n\U0001f389 All tests passed!")
        return 0
    else:
        print(f"\n\u26a0\ufe0f  {total - passed} test(s) failed")
        return 1


if __name__ == "__main__":
    sys.exit(run_tests())
