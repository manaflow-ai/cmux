#!/usr/bin/env python3
"""Behavioral guard for the CI xcodebuild prompt wrapper."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "xcodebuild_noninteractive.py"
PROMPT = "Press space to interact, D to debug, or any other key to quit"


def test_prompt_dismissal() -> bool:
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
        return False
    if result.stdout.count("received=q") != 2:
        print(result.stdout, end="")
        print("FAIL: helper did not answer each crash prompt with q")
        return False

    print("PASS: xcodebuild noninteractive helper dismisses crash prompts")
    return True


def test_signal_forwarding() -> bool:
    with tempfile.TemporaryDirectory() as temp_dir:
        marker = Path(temp_dir) / "terminated"
        child = textwrap.dedent(
            f"""
            import signal
            import sys
            import time
            from pathlib import Path

            marker = Path({str(marker)!r})

            def handle_term(_signum, _frame):
                marker.write_text("terminated", encoding="utf-8")
                raise SystemExit(0)

            signal.signal(signal.SIGTERM, handle_term)
            print("ready", flush=True)
            while True:
                time.sleep(0.1)
            """
        )
        process = subprocess.Popen(
            [sys.executable, str(HELPER), sys.executable, "-c", child],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            assert process.stdout is not None
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if "ready" in process.stdout.readline():
                    break
            else:
                process.kill()
                print("FAIL: wrapped command did not become ready")
                return False

            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
            print(stdout, end="")
            print(stderr, end="", file=sys.stderr)
            print("FAIL: helper did not exit after SIGTERM")
            return False

        if process.returncode != 143:
            print(stdout, end="")
            print(stderr, end="", file=sys.stderr)
            print(f"FAIL: expected helper exit 143 after SIGTERM, got {process.returncode}")
            return False
        if marker.read_text(encoding="utf-8") != "terminated":
            print("FAIL: helper did not forward SIGTERM to wrapped command")
            return False

    print("PASS: xcodebuild noninteractive helper forwards termination")
    return True


def main() -> int:
    if not test_prompt_dismissal():
        return 1
    if not test_signal_forwarding():
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
