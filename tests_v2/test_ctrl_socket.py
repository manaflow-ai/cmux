#!/usr/bin/env python3
"""
Automated tests for Ctrl+C and Ctrl+D using the cmux socket interface.

Usage:
    python3 test_ctrl_socket.py

Requirements:
    - cmux must be running with the socket controller enabled
"""

import json
import os
import sys
import time
import tempfile
from pathlib import Path

# Add the directory containing cmux.py to the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError, wait_until


def _started(marker: Path) -> Path:
    """A file the shell touches right before it runs the foreground process under test."""
    path = marker.with_name(marker.name + "_started")
    path.unlink(missing_ok=True)
    return path


def _type_until(client: cmux, marker: Path, attempts: int = 3, timeout_s: float = 3.0) -> bool:
    """Type `touch marker` until it appears; between tries send another Ctrl+C in
    case the process swallowed the first one."""
    for attempt in range(attempts):
        client.send(f"touch {marker}\n")
        if wait_until(marker.exists, timeout_s):
            return True
        if attempt + 1 < attempts:
            client.send_ctrl_c()
    return False


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


def test_connection(client: cmux) -> TestResult:
    """Test that we can connect and ping the server"""
    result = TestResult("Connection")
    try:
        if client.ping():
            result.success("Connected and received PONG")
        else:
            result.failure("Ping failed")
    except Exception as e:
        result.failure(str(e))
    return result


def test_ctrl_c(client: cmux) -> TestResult:
    """
    Test Ctrl+C by:
    1. Starting sleep command
    2. Sending Ctrl+C
    3. Verifying shell responds to next command
    """
    result = TestResult("Ctrl+C (SIGINT)")

    marker = Path(tempfile.gettempdir()) / f"ghostty_ctrlc_{os.getpid()}"
    started = _started(marker)

    try:
        marker.unlink(missing_ok=True)

        # Start a long sleep, and wait until the shell is running it.
        client.send(f"touch {started} && sleep 30\n")
        if not wait_until(started.exists, 10.0):
            result.failure("Shell never started the sleep")
            return result
        started.unlink(missing_ok=True)

        # Send Ctrl+C to interrupt
        client.send_ctrl_c()

        # If Ctrl+C worked, shell should accept new command
        if _type_until(client, marker):
            result.success("Ctrl+C interrupted sleep, shell responsive")
            marker.unlink(missing_ok=True)
        else:
            result.failure("Shell not responsive after Ctrl+C")

    except Exception as e:
        result.failure(f"Exception: {e}")
        marker.unlink(missing_ok=True)

    return result


def test_ctrl_d(client: cmux) -> TestResult:
    """
    Test Ctrl+D by:
    1. Running cat command
    2. Sending Ctrl+D
    3. Verifying cat exits and next command runs
    """
    result = TestResult("Ctrl+D (EOF)")

    marker = Path(tempfile.gettempdir()) / f"ghostty_ctrld_{os.getpid()}"
    started = _started(marker)

    try:
        marker.unlink(missing_ok=True)

        # Run cat (waits for input), and wait until the shell is running it.
        client.send(f"touch {started} && cat\n")
        if not wait_until(started.exists, 10.0):
            result.failure("Shell never started cat")
            return result
        started.unlink(missing_ok=True)

        # Send Ctrl+D (EOF)
        client.send_ctrl_d()

        # If Ctrl+D worked, cat should exit and we can run another command
        if _type_until(client, marker, attempts=1):
            result.success("Ctrl+D sent EOF, cat exited")
            marker.unlink(missing_ok=True)
        else:
            result.failure("cat did not exit after Ctrl+D")

    except Exception as e:
        result.failure(f"Exception: {e}")
        marker.unlink(missing_ok=True)

    return result


def test_ctrl_c_python(client: cmux) -> TestResult:
    """
    Test Ctrl+C with Python process
    """
    result = TestResult("Ctrl+C in Python")

    marker = Path(tempfile.gettempdir()) / f"ghostty_pyctrlc_{os.getpid()}"
    started = _started(marker)

    try:
        marker.unlink(missing_ok=True)

        # Start Python that loops forever; it touches `started` once it is running.
        client.send(
            f"python3 -c 'import pathlib, time; pathlib.Path(\"{started}\").touch(); "
            "[time.sleep(1) for _ in iter(int, 1)]'\n"
        )
        if not wait_until(started.exists, 10.0):
            result.failure("Python never started")
            return result
        started.unlink(missing_ok=True)

        # Send Ctrl+C
        client.send_ctrl_c()

        # If Ctrl+C worked, shell should accept new command. This can race with
        # Python process teardown, so retry with additional Ctrl+C if needed.
        if _type_until(client, marker):
            result.success("Ctrl+C interrupted Python process")
            marker.unlink(missing_ok=True)
        else:
            result.failure("Python not interrupted by Ctrl+C")

    except Exception as e:
        result.failure(f"Exception: {type(e).__name__}: {e}")
        marker.unlink(missing_ok=True)

    return result


def test_environment_paths(client: cmux) -> TestResult:
    """
    Verify that TERMINFO points to a real terminfo directory and that
    XDG_DATA_DIRS includes the app resources path (and defaults when unset).
    """
    result = TestResult("Environment Paths")
    env_path = Path(tempfile.gettempdir()) / f"cmux_env_{os.getpid()}.json"
    env_path.unlink(missing_ok=True)

    try:
        command = (
            "python3 -c 'import json,os;"
            f"open(\"{env_path}\",\"w\").write("
            "json.dumps({"
            "\"TERMINFO\": os.environ.get(\"TERMINFO\", \"\"),"
            "\"XDG_DATA_DIRS\": os.environ.get(\"XDG_DATA_DIRS\", \"\"),"
            "}))'"
        )

        for attempt in range(3):
            env_path.unlink(missing_ok=True)
            # Reset any partial prompt state (e.g., unmatched quotes) before retrying.
            client.send_ctrl_c()
            time.sleep(0.2)  # keep: the shell's SIGINT handling can flush input typed right behind ^C
            client.send(command + "\n")

            if wait_until(env_path.exists, 4.0):
                break

        if not env_path.exists():
            result.failure("Env dump file was not created")
            return result

        data = json.loads(env_path.read_text())
        terminfo = data.get("TERMINFO", "")
        xdg_data_dirs = data.get("XDG_DATA_DIRS", "")

        if not terminfo:
            result.failure("TERMINFO is empty")
            return result

        terminfo_path = Path(terminfo)
        if not terminfo_path.exists():
            result.failure(f"TERMINFO path does not exist: {terminfo}")
            return result

        xterm_entry = terminfo_path / "78" / "xterm-ghostty"
        if not xterm_entry.exists():
            result.failure(f"Missing terminfo entry: {xterm_entry}")
            return result

        if not xdg_data_dirs:
            result.failure("XDG_DATA_DIRS is empty")
            return result

        xdg_entries = xdg_data_dirs.split(":")
        resources_dir = terminfo_path.parent
        if resources_dir.as_posix() not in xdg_entries:
            result.failure(f"XDG_DATA_DIRS missing resources path: {resources_dir}")
            return result

        if not os.environ.get("XDG_DATA_DIRS"):
            if "/usr/local/share" not in xdg_entries or "/usr/share" not in xdg_entries:
                result.failure(
                    "XDG_DATA_DIRS missing standard defaults (/usr/local/share:/usr/share)"
                )
                return result

        result.success("TERMINFO and XDG_DATA_DIRS paths look correct")
        env_path.unlink(missing_ok=True)
        return result
    except Exception as e:
        env_path.unlink(missing_ok=True)
        result.failure(f"Exception: {type(e).__name__}: {e}")
        return result


def run_tests():
    """Run all tests"""
    print("=" * 60)
    print("cmux Ctrl+C/D Automated Tests")
    print("=" * 60)
    print()

    socket_path = cmux.DEFAULT_SOCKET_PATH
    if not os.path.exists(socket_path):
        print(f"Error: Socket not found at {socket_path}")
        print("Please make sure cmux is running.")
        return 1

    results = []

    try:
        with cmux() as client:
            # Test connection
            print("Testing connection...")
            results.append(test_connection(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()

            if not results[-1].passed:
                return 1

            # Ensure we start from a focused terminal surface (tests can be run
            # after other scripts that leave focus in a browser panel).
            try:
                workspace = client.new_workspace()
                client.select_workspace(workspace)
                wait_until(lambda: client.current_workspace() == workspace and client.list_surfaces(), 5.0)
                client.focus_surface(0)
                wait_until(lambda: any(focused for index, _sid, focused in client.list_surfaces() if index == 0), 3.0)
            except Exception as e:
                # Continue; individual tests will report a clearer failure.
                print(f"  ⚠️  Setup warning (could not focus terminal): {e}")
                print()

            # Test Ctrl+C
            print("Testing Ctrl+C (SIGINT)...")
            results.append(test_ctrl_c(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()

            # Test Ctrl+D
            print("Testing Ctrl+D (EOF)...")
            results.append(test_ctrl_d(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()

            # Test Ctrl+C in Python
            print("Testing Ctrl+C in Python process...")
            results.append(test_ctrl_c_python(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()

            # Test environment paths
            print("Testing TERMINFO/XDG_DATA_DIRS paths...")
            results.append(test_environment_paths(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()

    except cmuxError as e:
        print(f"Error: {e}")
        return 1

    # Summary
    print("=" * 60)
    print("Test Results Summary")
    print("=" * 60)

    passed = sum(1 for r in results if r.passed)
    total = len(results)

    for r in results:
        status = "✅ PASS" if r.passed else "❌ FAIL"
        print(f"  {r.name}: {status}")
        if not r.passed and r.message:
            print(f"      {r.message}")

    print()
    print(f"Passed: {passed}/{total}")

    if passed == total:
        print("\n🎉 All tests passed!")
        return 0
    else:
        print(f"\n⚠️  {total - passed} test(s) failed")
        return 1


if __name__ == "__main__":
    sys.exit(run_tests())
