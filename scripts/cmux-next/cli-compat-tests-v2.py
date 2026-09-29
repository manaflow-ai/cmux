#!/usr/bin/env python3
"""Runs tests_v2/test_*.py against a tagged cmux-next socket and prints a
pass/fail table (plans/cmux-next/cli-compat.md).

Usage:
  scripts/cmux-next/cli-compat-tests-v2.py --socket /tmp/cmux-debug-<tag>.sock \
      --cli "<tagged app>/Contents/Resources/bin/cmux" [--timeout 90] [--only test_x.py ...]

Never targets the default socket (/tmp/cmux-debug.sock, the user's app).
Afterwards (unless --keep-daemon) ends every terminal of the tag's daemon
with `shutdown-daemon end_terminals` and exits 1 if a PTY outlives it.
Each file runs in a clean environment: the caller's CMUX_* variables are
dropped so tests never inherit another cmux's workspace or surface ids.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "tests_v2"

# Not run: they drive the user's GUI through osascript, measure the
# release app by process name, or need SSH hosts / Cloud VMs.
EXCLUDED = {
    "test_ctrl_interactive.py": "interactive; the upstream runner skips it too",
    "test_cpu_notifications.py": "falls back to osascript keystrokes",
    "test_ctrl_enter_keybind.py": "drives the app through osascript",
    "test_cpu_usage.py": "measures the running cmux by process name, not the tagged socket",
}
INFRA_PREFIXES = {"test_ssh_": "needs CMUX_SSH_TEST_HOST", "test_cloud_": "needs CMUX_TEST_VM_ID"}


def teardown(cli: str, socket_path: str) -> tuple[bool, str]:
    """`shutdown-daemon end_terminals` on the tag's daemon (daemon_teardown.py);
    fails when a terminal host (PTY) outlives it."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from daemon_teardown import end_terminals
    name = os.path.basename(socket_path)
    if not (name.startswith("cmux-debug-") and name.endswith(".sock")):
        return False, f"cannot derive the tag from {socket_path}"
    tag = name[len("cmux-debug-"):-len(".sock")]
    binary = os.path.join(os.path.dirname(cli), "cmux-tui")
    result = end_terminals(binary, tag)
    ok = not result["error"] and not result["hosts_leaked"]
    return ok, json.dumps(result)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--only", nargs="*")
    parser.add_argument("--keep-daemon", action="store_true", help="skip the shutdown-daemon end_terminals teardown")
    args = parser.parse_args()
    if os.path.realpath(args.socket) in {"/tmp/cmux-debug.sock", "/private/tmp/cmux-debug.sock"}:
        print("refusing the default socket; pass a tagged /tmp/cmux-debug-<tag>.sock", file=sys.stderr)
        return 2
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
    env.update({"CMUX_SOCKET_PATH": args.socket, "CMUX_SOCKET": args.socket, "CMUXTERM_CLI": args.cli, "CMUX_QUIET": "1"})
    files = sorted(p.name for p in TESTS.glob("test_*.py"))
    if args.only:
        files = [f for f in files if f in set(args.only)]
    counts = {"pass": 0, "fail": 0, "skip": 0, "timeout": 0, "not-run": 0}
    for name in files:
        reason = EXCLUDED.get(name) or next((r for p, r in INFRA_PREFIXES.items() if name.startswith(p)), None)
        if reason:
            counts["not-run"] += 1
            print(f"| {name} | not-run | {reason} |", flush=True)
            continue
        if not os.path.exists(args.socket):
            counts["not-run"] += 1
            print(f"| {name} | not-run | tagged socket is gone (app exited) |", flush=True)
            continue
        started = time.monotonic()
        try:
            proc = subprocess.run([sys.executable, str(TESTS / name)], cwd=ROOT, env=env, capture_output=True, text=True,
                                  timeout=args.timeout)
            output = (proc.stdout + "\n" + proc.stderr).strip()
            lines = [line for line in output.splitlines() if line.strip()]
            last = lines[-1] if lines else ""
            skipped = "SKIP" in output.upper() and proc.returncode == 0 and "PASS" not in output.upper()
            status = "skip" if skipped else ("pass" if proc.returncode == 0 else "fail")
        except subprocess.TimeoutExpired:
            status, last = "timeout", f"exceeded {args.timeout:.0f}s"
        counts[status] += 1
        detail = last.replace("|", "/")[:160]
        print(f"| {name} | {status} ({time.monotonic() - started:.1f}s) | {detail} |", flush=True)
    print("\n" + ", ".join(f"{k}={v}" for k, v in counts.items()))
    if not args.keep_daemon:
        ok, detail = teardown(args.cli, args.socket)
        print(f"teardown end_terminals: {'ok' if ok else 'FAILED'} {detail}")
        if not ok:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
