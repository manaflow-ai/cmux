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
import json
import glob
import plistlib

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


def _preferred_worktree_slug():
    env_slug = os.environ.get("CMUX_TAG") or os.environ.get("CMUX_BRANCH_SLUG")
    if env_slug:
        return env_slug.strip().lower()

    cwd = os.getcwd()
    marker = "/worktrees/"
    if marker in cwd:
        tail = cwd.split(marker, 1)[1]
        slug = tail.split("/", 1)[0].strip().lower()
        if slug:
            return slug
    return ""


def _derived_app_candidates_for_current_worktree():
    project_path = os.path.realpath(os.path.join(os.getcwd(), "GhosttyTabs.xcodeproj"))
    info_paths = glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/GhosttyTabs-*/info.plist"
    ))
    matches = []
    for info_path in info_paths:
        try:
            with open(info_path, "rb") as f:
                info = plistlib.load(f)
        except Exception:
            continue
        workspace_path = info.get("WorkspacePath")
        if not workspace_path:
            continue
        if os.path.realpath(workspace_path) != project_path:
            continue
        derived_root = os.path.dirname(info_path)
        app_path = os.path.join(derived_root, "Build/Products/Debug/cmux DEV.app")
        if os.path.exists(app_path):
            matches.append(app_path)
    return matches


def _find_app():
    explicit = os.environ.get("CMUX_APP_PATH")
    if explicit and os.path.exists(explicit):
        return explicit

    preferred_slug = _preferred_worktree_slug()
    if preferred_slug:
        preferred_tmp = []
        preferred_tmp.extend(glob.glob(f"/tmp/cmux-{preferred_slug}/Build/Products/Debug/cmux DEV*.app"))
        preferred_tmp.extend(glob.glob(f"/private/tmp/cmux-{preferred_slug}/Build/Products/Debug/cmux DEV*.app"))
        preferred_tmp = [p for p in preferred_tmp if os.path.exists(p)]
        if preferred_tmp:
            preferred_tmp.sort(key=os.path.getmtime, reverse=True)
            return preferred_tmp[0]

    direct_matches = _derived_app_candidates_for_current_worktree()
    if direct_matches:
        direct_matches.sort(key=os.path.getmtime, reverse=True)
        return direct_matches[0]

    home = os.path.expanduser("~")
    derived_candidates = glob.glob(os.path.join(
        home, "Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV.app"
    ))
    tmp_candidates = []
    tmp_candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux DEV*.app"))
    tmp_candidates.extend(glob.glob("/private/tmp/cmux-*/Build/Products/Debug/cmux DEV*.app"))

    derived_candidates = [p for p in derived_candidates if os.path.exists(p)]
    tmp_candidates = [p for p in tmp_candidates if os.path.exists(p)]

    if preferred_slug:
        preferred_derived = [p for p in derived_candidates if preferred_slug in p.lower()]
        preferred_tmp = [p for p in tmp_candidates if preferred_slug in p.lower()]
        if preferred_derived:
            derived_candidates = preferred_derived
        if preferred_tmp:
            tmp_candidates = preferred_tmp

    if derived_candidates:
        derived_candidates.sort(key=os.path.getmtime, reverse=True)
        return derived_candidates[0]

    if tmp_candidates:
        tmp_candidates.sort(key=os.path.getmtime, reverse=True)
        return tmp_candidates[0]

    return ""


def _find_cli(preferred_app_path: str = ""):
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    if preferred_app_path:
        debug_dir = os.path.dirname(preferred_app_path)
        sibling = os.path.join(debug_dir, "cmux")
        if os.path.exists(sibling) and os.access(sibling, os.X_OK):
            return sibling

    candidates = []
    home = os.path.expanduser("~")
    candidates.extend(glob.glob(os.path.join(
        home, "Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux"
    )))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates.extend(glob.glob("/private/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if not candidates:
        return ""

    preferred_slug = _preferred_worktree_slug()
    if preferred_slug:
        preferred = [p for p in candidates if preferred_slug in p.lower()]
        if preferred:
            candidates = preferred

    candidates.sort(key=os.path.getmtime, reverse=True)
    return candidates[0]


def _wait_for_socket(socket_path: str, timeout: float = 10.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(socket_path):
            try:
                sock = _raw_connect(socket_path, timeout=0.3)
                sock.close()
                return True
            except Exception:
                pass
        time.sleep(0.5)
    return False


def _kill_cmux(app_path: str = None):
    if app_path:
        exe = os.path.join(app_path, "Contents/MacOS/cmux DEV")
        subprocess.run(["pkill", "-f", exe], capture_output=True)
    else:
        subprocess.run(["pkill", "-x", "cmux DEV"], capture_output=True)
    time.sleep(1.5)


def _launch_cmux(app_path: str, socket_path: str, mode: str = None, extra_env: dict = None):
    if os.path.exists(socket_path):
        try:
            os.unlink(socket_path)
        except OSError:
            pass

    env_args = []
    if mode:
        env_args = ["--env", f"CMUX_SOCKET_MODE={mode}"]
    launch_env = {
        "CMUX_SOCKET_PATH": socket_path,
        "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
    }
    if extra_env:
        launch_env.update(extra_env)
    for key, value in launch_env.items():
        env_args.extend(["--env", f"{key}={value}"])
    subprocess.Popen(["open", "-na", app_path] + env_args)
    if not _wait_for_socket(socket_path):
        raise RuntimeError(f"Socket {socket_path} not created after launch")
    time.sleep(8)


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
        _kill_cmux(app_path)
        _launch_cmux(app_path, socket_path, mode="cmuxOnly")

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
        _kill_cmux(app_path)
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


def test_password_mode_requires_auth(socket_path: str, app_path: str) -> TestResult:
    """Verify password mode rejects unauthenticated commands."""
    result = TestResult("Password mode requires auth")
    password = f"cmux-pass-{os.getpid()}"
    try:
        _kill_cmux(app_path)
        _launch_cmux(
            app_path,
            socket_path,
            mode="password",
            extra_env={"CMUX_SOCKET_PASSWORD": password}
        )

        sock = _raw_connect(socket_path)
        response = _raw_send(sock, "ping")
        sock.close()

        if "Authentication required" in response:
            result.success("Unauthenticated command rejected in password mode")
        else:
            result.failure(f"Unexpected response without auth: {response!r}")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


def test_password_mode_v1_auth_flow(socket_path: str, app_path: str) -> TestResult:
    """Verify v1 auth command unlocks the connection only with correct password."""
    result = TestResult("Password mode v1 auth flow")
    password = f"cmux-pass-{os.getpid()}"
    try:
        _kill_cmux(app_path)
        _launch_cmux(
            app_path,
            socket_path,
            mode="password",
            extra_env={"CMUX_SOCKET_PASSWORD": password}
        )

        sock = _raw_connect(socket_path)
        try:
            wrong = _raw_send(sock, "auth wrong-password")
            if "Invalid password" not in wrong:
                result.failure(f"Expected invalid password error, got: {wrong!r}")
                return result

            ok = _raw_send(sock, f"auth {password}")
            if "OK: Authenticated" not in ok:
                result.failure(f"Expected auth success, got: {ok!r}")
                return result

            pong = _raw_send(sock, "ping")
            if pong != "PONG":
                result.failure(f"Expected PONG after auth, got: {pong!r}")
                return result
        finally:
            sock.close()

        result.success("v1 auth gate works")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


def test_password_mode_v2_auth_flow(socket_path: str, app_path: str) -> TestResult:
    """Verify v2 auth.login unlocks subsequent v2 requests."""
    result = TestResult("Password mode v2 auth flow")
    password = f"cmux-pass-{os.getpid()}"
    try:
        _kill_cmux(app_path)
        _launch_cmux(
            app_path,
            socket_path,
            mode="password",
            extra_env={"CMUX_SOCKET_PASSWORD": password}
        )

        sock = _raw_connect(socket_path)
        try:
            unauth = _raw_send(sock, json.dumps({
                "id": "1",
                "method": "system.ping",
                "params": {}
            }))
            unauth_obj = json.loads(unauth)
            if unauth_obj.get("error", {}).get("code") != "auth_required":
                result.failure(f"Expected auth_required, got: {unauth!r}")
                return result

            login = _raw_send(sock, json.dumps({
                "id": "2",
                "method": "auth.login",
                "params": {"password": password}
            }))
            login_obj = json.loads(login)
            if not login_obj.get("ok"):
                result.failure(f"Expected auth.login success, got: {login!r}")
                return result

            pong = _raw_send(sock, json.dumps({
                "id": "3",
                "method": "system.ping",
                "params": {}
            }))
            pong_obj = json.loads(pong)
            pong_value = pong_obj.get("result", {}).get("pong")
            if pong_value is not True:
                result.failure(f"Expected pong=true after auth.login, got: {pong!r}")
                return result
        finally:
            sock.close()

        result.success("v2 auth.login gate works")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


def test_password_mode_cli_exit_code(socket_path: str, app_path: str) -> TestResult:
    """Verify CLI exits non-zero on auth-required and succeeds with --password."""
    result = TestResult("Password mode CLI exit code")
    password = f"cmux-pass-{os.getpid()}"
    try:
        cli_path = _find_cli(preferred_app_path=app_path)
        if not cli_path:
            result.failure("Could not find cmux CLI binary")
            return result

        _kill_cmux(app_path)
        _launch_cmux(
            app_path,
            socket_path,
            mode="password",
            extra_env={"CMUX_SOCKET_PASSWORD": password}
        )

        no_auth = subprocess.run(
            [cli_path, "--socket", socket_path, "ping"],
            capture_output=True,
            text=True,
            timeout=10
        )
        combined = f"{no_auth.stdout}\n{no_auth.stderr}"
        if no_auth.returncode == 0:
            result.failure("CLI ping without password exited 0 in password mode")
            return result
        if "Authentication required" not in combined:
            result.failure(f"Unexpected unauthenticated CLI output: {combined!r}")
            return result

        with_auth = subprocess.run(
            [cli_path, "--socket", socket_path, "--password", password, "ping"],
            capture_output=True,
            text=True,
            timeout=10
        )
        if with_auth.returncode != 0:
            result.failure(
                f"CLI ping with password failed: exit={with_auth.returncode} "
                f"stdout={with_auth.stdout!r} stderr={with_auth.stderr!r}"
            )
            return result
        if "PONG" not in with_auth.stdout:
            result.failure(f"Expected PONG with password, got: {with_auth.stdout!r}")
            return result

        result.success("CLI exits non-zero for auth_required and succeeds with --password")
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

    socket_path = f"/tmp/cmux-test-socket-access-{os.getpid()}.sock"
    try:
        os.unlink(socket_path)
    except OSError:
        pass
    print(f"Socket: {socket_path}")
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
    _kill_cmux(app_path)
    print("  Launching cmux in cmuxOnly mode...")
    _launch_cmux(app_path, socket_path, mode="cmuxOnly")

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

    # ── Phase 4: password mode auth gate ──
    print("Phase 4: password mode — auth required + login flow")
    print("-" * 50)

    run_test(test_password_mode_requires_auth, socket_path, app_path)
    run_test(test_password_mode_v1_auth_flow, socket_path, app_path)
    run_test(test_password_mode_v2_auth_flow, socket_path, app_path)
    run_test(test_password_mode_cli_exit_code, socket_path, app_path)
    print()

    # ── Cleanup: leave cmux in cmuxOnly mode ──
    _kill_cmux(app_path)
    _launch_cmux(app_path, socket_path, mode="cmuxOnly")

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
