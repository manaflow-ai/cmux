#!/usr/bin/env python3
"""
Terminal stress test for cmuxterm.

- Opens multiple tabs
- Runs a mix of common terminal commands
- Samples cmuxterm/cmuxd RSS before/after

Run after launching cmuxterm:
    python3 tests/test_terminal_stress.py
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from typing import Dict, List, Optional

from cmux import cmux, cmuxError

# Default stress parameters (override with env vars)
TAB_COUNT = int(os.environ.get("CMUX_STRESS_TABS", "4"))
ITERATIONS = int(os.environ.get("CMUX_STRESS_ITERATIONS", "3"))
COMMAND_DELAY = float(os.environ.get("CMUX_STRESS_COMMAND_DELAY", "0.08"))
SETTLE_DELAY = float(os.environ.get("CMUX_STRESS_SETTLE", "0.5"))

COMMON_COMMANDS: List[str] = [
    "pwd",
    "whoami",
    "uname -a",
    "date",
    "ls -la",
    "ps -ax | head -n 5",
    "top -l 1 | head -n 5",
    "command -v python3 >/dev/null && python3 -c 'print(\"py ok\")' || true",
    "command -v git >/dev/null && git -C /Users/cmux/GhosttyTabs status -sb 2>/dev/null || true",
    "command -v rg >/dev/null && rg --version | head -n 1 || true",
    "stty -a",
    "tput colors || true",
    "printf '\\033]0;cmuxterm-stress\\007'",
    "printf 'OSC52 test: ' && printf '\\033]52;c;Y21veC1zdHJlc3M=\\007'",
]


def _pgrep_first(pattern: str) -> Optional[int]:
    result = subprocess.run([
        "pgrep",
        "-f",
        pattern,
    ], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    for line in result.stdout.strip().split("\n"):
        line = line.strip()
        if line:
            try:
                return int(line)
            except ValueError:
                continue
    return None


def _default_socket_path() -> str:
    override = os.environ.get("CMUX_SOCKET_PATH")
    if override:
        return override
    candidates = ["/tmp/cmuxterm-debug.sock", "/tmp/cmuxterm.sock"]
    for path in candidates:
        if os.path.exists(path):
            return path
    return candidates[0]


def _pid_from_socket(socket_path: str) -> Optional[int]:
    result = subprocess.run(
        ["lsof", "-n", "-t", socket_path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    for line in result.stdout.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            return int(line)
        except ValueError:
            continue
    return None


def _rss_kb(pid: int) -> Optional[int]:
    result = subprocess.run([
        "ps",
        "-p",
        str(pid),
        "-o",
        "rss=",
    ], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


def _memory_snapshot() -> Dict[str, Optional[int]]:
    cmuxterm_pid = (
        _pgrep_first(r"cmuxterm DEV\.app/Contents/MacOS/cmuxterm")
        or _pgrep_first(r"cmuxterm\.app/Contents/MacOS/cmuxterm")
    )
    cmuxd_pid = _pgrep_first(r"cmuxd$")
    if cmuxd_pid is None:
        cmuxd_pid = _pid_from_socket(_default_socket_path())
    return {
        "cmuxterm_pid": cmuxterm_pid,
        "cmuxterm_rss_kb": _rss_kb(cmuxterm_pid) if cmuxterm_pid else None,
        "cmuxd_pid": cmuxd_pid,
        "cmuxd_rss_kb": _rss_kb(cmuxd_pid) if cmuxd_pid else None,
    }


def _fmt_kb(value: Optional[int]) -> str:
    if value is None:
        return "n/a"
    return f"{value / 1024.0:.1f} MB"


def run_stress(client: cmux) -> None:
    print(f"Creating {TAB_COUNT} tabs...")
    tabs: List[str] = []
    for _ in range(TAB_COUNT):
        tabs.append(client.new_tab())
        time.sleep(0.05)

    print(f"Running {ITERATIONS} iterations of {len(COMMON_COMMANDS)} commands...")
    for iteration in range(ITERATIONS):
        print(f"Iteration {iteration + 1}/{ITERATIONS}")
        for index, tab_id in enumerate(tabs):
            client.select_tab(tab_id)
            time.sleep(0.05)
            for cmd in COMMON_COMMANDS:
                client.send_line(cmd)
                time.sleep(COMMAND_DELAY)
            # Mark end of batch
            client.send_line(f"echo __CMUX_STRESS_DONE_{iteration}_{index}__")
            time.sleep(SETTLE_DELAY)


def main() -> int:
    print("=" * 60)
    print("cmuxterm Terminal Stress Test")
    print("=" * 60)

    before = _memory_snapshot()
    print("\nMemory before:")
    print(f"  cmuxterm pid: {before['cmuxterm_pid']}")
    print(f"  cmuxterm rss: {_fmt_kb(before['cmuxterm_rss_kb'])}")
    print(f"  cmuxd pid:    {before['cmuxd_pid']}")
    print(f"  cmuxd rss:    {_fmt_kb(before['cmuxd_rss_kb'])}")

    try:
        with cmux() as client:
            if not client.ping():
                print("\nFAIL: cmux ping failed")
                return 1
            run_stress(client)
    except cmuxError as exc:
        print(f"\nFAIL: cmux error: {exc}")
        return 1

    # Let the UI and daemon settle
    time.sleep(1.5)

    after = _memory_snapshot()
    print("\nMemory after:")
    print(f"  cmuxterm pid: {after['cmuxterm_pid']}")
    print(f"  cmuxterm rss: {_fmt_kb(after['cmuxterm_rss_kb'])}")
    print(f"  cmuxd pid:    {after['cmuxd_pid']}")
    print(f"  cmuxd rss:    {_fmt_kb(after['cmuxd_rss_kb'])}")

    print("\nPASS: Stress test completed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
