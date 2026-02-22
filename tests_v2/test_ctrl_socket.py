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

    try:
        marker.unlink(missing_ok=True)

        # Start a long sleep
        client.send("sleep 30\n")
        time.sleep(0.8)

        # Send Ctrl+C to interrupt
        client.send_ctrl_c()
        time.sleep(0.8)

        # If Ctrl+C worked, shell should accept new command
        for attempt in range(3):
            client.send(f"touch {marker}\n")
            for _ in range(10):
                if marker.exists():
                    break
                time.sleep(0.2)
            if marker.exists():
                break
            # try another Ctrl+C in case the process swallowed the signal
            client.send_ctrl_c()
            time.sleep(0.6)

        if marker.exists():
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

    try:
        marker.unlink(missing_ok=True)

        # Run cat (waits for input)
        client.send("cat\n")
        time.sleep(0.6)

        # Send Ctrl+D (EOF)
        client.send_ctrl_d()
        time.sleep(0.4)

        # If Ctrl+D worked, cat should exit and we can run another command
        client.send(f"touch {marker}\n")
        for _ in range(10):
            if marker.exists():
                break
            time.sleep(0.2)

        if marker.exists():
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

    try:
        marker.unlink(missing_ok=True)

        # Start Python that loops forever
        client.send("python3 -c 'import time; [time.sleep(1) for _ in iter(int, 1)]'\n")
        time.sleep(1.5)  # Give Python time to start

        # Send Ctrl+C
        client.send_ctrl_c()
        time.sleep(0.8)

        # If Ctrl+C worked, shell should accept new command. This can race with
        # Python process teardown, so retry with additional Ctrl+C if needed.
        for attempt in range(3):
            client.send(f"touch {marker}\n")
            for _ in range(15):
                if marker.exists():
                    break
                time.sleep(0.2)
            if marker.exists():
                break
            client.send_ctrl_c()
            time.sleep(0.6)

        if marker.exists():
            result.success("Ctrl+C interrupted Python process")
            marker.unlink(missing_ok=True)
        else:
            result.failure("Python not interrupted by Ctrl+C")

    except Exception as e:
        result.failure(f"Exception: {type(e).__name__}: {e}")
        marker.unlink(missing_ok=True)

    return result


def test_cmd_c_does_not_interrupt_foreground_process(client: cmux) -> TestResult:
    """
    Regression: Cmd+C (copy shortcut) must not be forwarded as terminal SIGINT.
    """
    result = TestResult("Cmd+C does not send SIGINT")

    marker = Path(tempfile.gettempdir()) / f"cmux_cmdc_signal_{os.getpid()}"

    try:
        marker.unlink(missing_ok=True)
        client.activate_app()

        command = (
            "python3 -c 'import pathlib,signal,sys,time;"
            f"p=pathlib.Path(\"{marker}\");"
            "signal.signal(signal.SIGINT, lambda *_: (p.write_text(\"INT\"), sys.exit(130)));"
            "time.sleep(1.4);"
            "p.write_text(\"DONE\")'"
        )

        client.send(command + "\n")
        time.sleep(0.35)  # Let the process enter sleep before shortcut dispatch.

        client.simulate_shortcut("cmd+c")

        # Immediate failure signal: command received SIGINT.
        for _ in range(12):
            if marker.exists():
                state = marker.read_text().strip()
                if state == "INT":
                    result.failure("Cmd+C propagated to terminal as SIGINT")
                    marker.unlink(missing_ok=True)
                    return result
            time.sleep(0.08)

        # Process should complete naturally and write DONE.
        for _ in range(30):
            if marker.exists():
                break
            time.sleep(0.1)

        if not marker.exists():
            result.failure("Foreground process did not finish after Cmd+C check")
            return result

        state = marker.read_text().strip()
        if state == "DONE":
            result.success("Cmd+C stayed in shortcut/menu path; process completed")
        else:
            result.failure(f"Unexpected process marker state: {state!r}")

        marker.unlink(missing_ok=True)
    except Exception as e:
        result.failure(f"Exception: {type(e).__name__}: {e}")
        marker.unlink(missing_ok=True)
        # Ensure no long-running child lingers if test failed mid-flight.
        try:
            client.send_ctrl_c()
        except Exception:
            pass

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
            time.sleep(0.2)
            client.send(command + "\n")

            for _ in range(20):
                if env_path.exists():
                    break
                time.sleep(0.2)

            if env_path.exists():
                break

            # Small backoff before retrying send in case the surface isn't ready yet.
            time.sleep(0.3 * (attempt + 1))

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
                client.new_workspace()
                time.sleep(0.6)
                client.focus_surface(0)
                time.sleep(0.2)
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

            time.sleep(0.5)

            # Test Ctrl+D
            print("Testing Ctrl+D (EOF)...")
            results.append(test_ctrl_d(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()

            time.sleep(0.5)

            # Test Ctrl+C in Python
            print("Testing Ctrl+C in Python process...")
            results.append(test_ctrl_c_python(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()

            time.sleep(0.5)

            # Regression: Cmd+C shortcut should not interrupt foreground process
            print("Testing Cmd+C shortcut does not send SIGINT...")
            results.append(test_cmd_c_does_not_interrupt_foreground_process(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()

            time.sleep(0.5)

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
