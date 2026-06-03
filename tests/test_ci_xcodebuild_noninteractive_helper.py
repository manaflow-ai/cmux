#!/usr/bin/env python3
"""Behavioral guard for the CI xcodebuild prompt wrapper."""

from __future__ import annotations

import select
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "xcodebuild_noninteractive.py"
PROMPT = "Press space to interact, D to debug, or any other key to quit"


def main() -> int:
    signal_result = test_signal_forwarding()
    if signal_result != 0:
        return signal_result

    child = textwrap.dedent(
        f"""
        import sys
        import termios
        import tty

        prompt = {PROMPT!r}
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        tty.setraw(fd)
        try:
            for _ in range(2):
                print(prompt, flush=True)
                ch = sys.stdin.read(1)
                print('received=' + ch, flush=True)
                termios.tcflush(fd, termios.TCIFLUSH)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        raise SystemExit(7)
        """
    )
    result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    if result.returncode != 7:
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        print(f"FAIL: expected wrapped command exit 7, got {result.returncode}")
        return 1
    if result.stdout.count("received=q") != 2:
        print(result.stdout, end="")
        print("FAIL: helper did not answer each crash prompt with q")
        return 1

    print("PASS: xcodebuild noninteractive helper dismisses crash prompts")
    return 0


def test_signal_forwarding() -> int:
    with tempfile.TemporaryDirectory() as tmp_dir:
        marker = Path(tmp_dir) / "terminated"
        child = textwrap.dedent(
            f"""
            import signal
            import time
            from pathlib import Path

            marker = Path({str(marker)!r})

            def handle_term(signum, frame):
                marker.write_text("terminated", encoding="utf-8")
                raise SystemExit(0)

            signal.signal(signal.SIGTERM, handle_term)
            print("ready", flush=True)
            while True:
                time.sleep(1)
            """
        )

        process = subprocess.Popen(
            [sys.executable, str(HELPER), sys.executable, "-c", child],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert process.stdout is not None

        deadline = time.monotonic() + 5
        output = ""
        while time.monotonic() < deadline and "ready" not in output:
            readable, _, _ = select.select([process.stdout], [], [], 0.1)
            if process.stdout in readable:
                output += process.stdout.readline()

        if "ready" not in output:
            process.kill()
            stdout, stderr = process.communicate()
            print(output + stdout, end="")
            print(stderr, end="", file=sys.stderr)
            print("FAIL: helper child did not become ready")
            return 1

        process.send_signal(signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
            print(output + stdout, end="")
            print(stderr, end="", file=sys.stderr)
            print("FAIL: helper did not exit after SIGTERM")
            return 1

        if process.returncode not in (0, 128 + signal.SIGTERM):
            print(output + stdout, end="")
            print(stderr, end="", file=sys.stderr)
            print(f"FAIL: expected helper SIGTERM exit, got {process.returncode}")
            return 1

        if not marker.exists():
            print(output + stdout, end="")
            print(stderr, end="", file=sys.stderr)
            print("FAIL: helper did not forward SIGTERM to its child")
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
