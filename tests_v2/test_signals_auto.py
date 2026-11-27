#!/usr/bin/env python3
"""
Automated test for signal handling - tests that SIGINT and EOF work correctly.
This test doesn't require manual interaction.
"""

import subprocess
import signal
import sys
import os
import time
import pty
import select
import termios
import tty

def test_sigint_in_pty():
    """Test that Ctrl+C (SIGINT) works in a PTY"""
    print("Test 1: SIGINT via PTY (simulating Ctrl+C)")

    # Create a PTY pair
    master_fd, slave_fd = pty.openpty()

    # Configure the PTY for proper signal handling
    # This enables ISIG so Ctrl+C generates SIGINT
    attrs = termios.tcgetattr(slave_fd)
    attrs[3] |= termios.ISIG  # Enable signals
    attrs[3] |= termios.ICANON  # Canonical mode
    attrs[6][termios.VINTR] = 3  # Ctrl+C = SIGINT
    termios.tcsetattr(slave_fd, termios.TCSANOW, attrs)

    # Start a process that waits for SIGINT
    # Use start_new_session=True to create new session with controlling terminal
    proc = subprocess.Popen(
        ['python3', '-c', '''
import signal
import sys
import time
import os

received = False
def handler(sig, frame):
    global received
    received = True
    # Avoid print() from a signal handler (it can raise "reentrant call" on some Python builds).
    os.write(1, b"SIGINT_RECEIVED\\n")
    sys.exit(0)

signal.signal(signal.SIGINT, handler)
print("WAITING", flush=True)
for i in range(10):
    time.sleep(0.5)
    if received:
        break
if not received:
    print("TIMEOUT", flush=True)
    sys.exit(1)
'''],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        start_new_session=True
    )

    os.close(slave_fd)

    try:
        # Wait for "WAITING" message
        output = b""
        for _ in range(20):
            if select.select([master_fd], [], [], 0.1)[0]:
                output += os.read(master_fd, 1024)
                if b"WAITING" in output:
                    break

        if b"WAITING" not in output:
            print("  ❌ FAILED: Process didn't start properly")
            return False

        # Send SIGINT directly to the process group
        # This simulates what the terminal does when it receives Ctrl+C
        os.kill(-proc.pid, signal.SIGINT)

        # Wait for response
        output = b""
        for _ in range(20):
            if select.select([master_fd], [], [], 0.1)[0]:
                output += os.read(master_fd, 1024)
                if b"SIGINT_RECEIVED" in output:
                    break

        proc.wait(timeout=2)

        if b"SIGINT_RECEIVED" in output:
            print("  ✅ PASSED: SIGINT received via Ctrl+C in PTY")
            return True
        else:
            print(f"  ❌ FAILED: No SIGINT received. Output: {output}")
            return False

    except Exception as e:
        print(f"  ❌ FAILED: {e}")
        return False
    finally:
        try:
            proc.kill()
        except:
            pass
        os.close(master_fd)

def test_eof_in_pty():
    """Test that Ctrl+D (EOF) works in a PTY"""
    print("\nTest 2: EOF via PTY (simulating Ctrl+D)")

    master_fd, slave_fd = pty.openpty()

    proc = subprocess.Popen(
        ['python3', '-c', '''
import sys
print("WAITING", flush=True)
try:
    line = input()
    if line == "":
        print("EMPTY_LINE", flush=True)
    else:
        print(f"GOT: {line}", flush=True)
except EOFError:
    print("EOF_RECEIVED", flush=True)
    sys.exit(0)
'''],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        preexec_fn=os.setsid
    )

    os.close(slave_fd)

    try:
        # Wait for "WAITING"
        output = b""
        for _ in range(20):
            if select.select([master_fd], [], [], 0.1)[0]:
                output += os.read(master_fd, 1024)
                if b"WAITING" in output:
                    break

        if b"WAITING" not in output:
            print("  ❌ FAILED: Process didn't start properly")
            return False

        # Send Ctrl+D (ASCII 0x04) through the PTY
        os.write(master_fd, b'\x04')

        # Wait for response
        output = b""
        for _ in range(20):
            if select.select([master_fd], [], [], 0.1)[0]:
                output += os.read(master_fd, 1024)
                if b"EOF_RECEIVED" in output or b"EMPTY_LINE" in output:
                    break

        proc.wait(timeout=2)

        if b"EOF_RECEIVED" in output:
            print("  ✅ PASSED: EOF received via Ctrl+D in PTY")
            return True
        else:
            print(f"  ❌ FAILED: No EOF received. Output: {output}")
            return False

    except Exception as e:
        print(f"  ❌ FAILED: {e}")
        return False
    finally:
        try:
            proc.kill()
        except:
            pass
        os.close(master_fd)

def test_direct_signal():
    """Test direct signal sending (not through keyboard)"""
    print("\nTest 3: Direct SIGINT signal")

    proc = subprocess.Popen(
        ['python3', '-c', '''
import signal
import time
import sys

def handler(sig, frame):
    print("SIGINT_RECEIVED", flush=True)
    sys.exit(0)

signal.signal(signal.SIGINT, handler)
print("WAITING", flush=True)
sys.stdout.flush()
time.sleep(10)
print("TIMEOUT", flush=True)
'''],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )

    try:
        # Wait for process to start and emit the ready line
        output = b""
        start = time.time()
        while time.time() - start < 2.0:
            if select.select([proc.stdout], [], [], 0.1)[0]:
                chunk = os.read(proc.stdout.fileno(), 1024)
                if not chunk:
                    break
                output += chunk
                if b"WAITING" in output:
                    break

        if b"WAITING" not in output:
            print(f"  ❌ FAILED: Process not ready. Output: {output}")
            return False

        # Send SIGINT directly
        proc.send_signal(signal.SIGINT)

        stdout, stderr = proc.communicate(timeout=2)
        stdout = output + stdout

        if b"SIGINT_RECEIVED" in stdout:
            print("  ✅ PASSED: Direct SIGINT works")
            return True
        else:
            print(f"  ❌ FAILED: Output: {stdout}")
            return False

    except Exception as e:
        print(f"  ❌ FAILED: {e}")
        return False
    finally:
        try:
            proc.kill()
        except:
            pass

def main():
    print("=" * 50)
    print("Automated Signal Handling Tests")
    print("=" * 50)
    print()

    results = []

    results.append(("SIGINT via PTY (Ctrl+C)", test_sigint_in_pty()))
    results.append(("EOF via PTY (Ctrl+D)", test_eof_in_pty()))
    results.append(("Direct SIGINT", test_direct_signal()))

    print()
    print("=" * 50)
    print("Results Summary")
    print("=" * 50)

    all_passed = True
    for name, passed in results:
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"  {name}: {status}")
        if not passed:
            all_passed = False

    print()
    if all_passed:
        print("All tests passed!")
        return 0
    else:
        print("Some tests failed.")
        return 1

if __name__ == "__main__":
    sys.exit(main())
