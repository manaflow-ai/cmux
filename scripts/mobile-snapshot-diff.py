#!/usr/bin/env python3
"""Side-by-side diff of what the Mac terminal shows vs what the mobile
snapshot RPC returns. Use to flush out edge cases where iOS sees a
different visible state than the Mac.

Usage:
  scripts/mobile-snapshot-diff.py                  # one-shot
  scripts/mobile-snapshot-diff.py --watch          # repoll every 500ms
  scripts/mobile-snapshot-diff.py --send "echo hi" # send input then diff
  scripts/mobile-snapshot-diff.py --suite          # walk the canned test suite
"""

import argparse
import json
import os
import subprocess
import sys
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
CMUX_TAG = os.environ.get("CMUX_TAG", "mobile")
DEBUG_CLI = os.path.join(REPO_ROOT, "scripts", "cmux-debug-cli.sh")


def run_cli(*args):
    env = os.environ.copy()
    env["CMUX_TAG"] = CMUX_TAG
    result = subprocess.run(
        [DEBUG_CLI, *args],
        env=env,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
    )
    return result.stdout


def list_workspaces():
    raw = run_cli("rpc", "mobile.workspace.list", "{}")
    return json.loads(raw).get("workspaces", [])


def selected_workspace_and_terminal():
    for ws in list_workspaces():
        if ws.get("is_selected"):
            term = (ws.get("terminals") or [None])[0]
            return ws["id"], (term or {}).get("id")
    raise RuntimeError("no selected workspace")


def mac_visible_lines(workspace_id: str, terminal_id: str, lines: int = 45):
    """The Mac side via `cmux read-screen`, the canonical CLI used by
    other automation. Returns the last `lines` trimmed lines from the
    visible viewport."""
    raw = run_cli(
        "read-screen",
        "--workspace", workspace_id,
        "--surface", terminal_id,
    ).decode("utf-8", errors="replace")
    return [line.rstrip() for line in raw.split("\n")[-lines:]]


def mobile_snapshot(workspace_id: str, terminal_id: str):
    payload = json.dumps({
        "workspace_id": workspace_id,
        "surface_id": terminal_id,
        "max_scrollback_rows": 0,
    })
    raw = run_cli("rpc", "mobile.terminal.snapshot", payload)
    return json.loads(raw)


def cells_to_text(cells):
    out = []
    for cell in cells:
        if isinstance(cell, dict):
            out.append(cell.get("text", "") or "")
    return "".join(out).rstrip()


def mobile_visible_lines(snap):
    s = snap.get("snapshot") or snap
    return [cells_to_text(r.get("cells", [])) for r in s.get("visibleRows", [])]


def cursor_row_col(snap):
    s = snap.get("snapshot") or snap
    c = s.get("cursor") or {}
    return c.get("row"), c.get("column"), c.get("isVisible")


def diff(mac_lines, mobile_lines, cursor_row, cursor_col, fidelity):
    width = max((len(line) for line in mac_lines + mobile_lines), default=0)
    width = min(width, 60)
    header = f"{'#':>3}  {'mac':<{width}}  =  {'mobile':<{width}}"
    print(header)
    print("-" * len(header))
    total = max(len(mac_lines), len(mobile_lines))
    mismatches = 0
    for i in range(total):
        mac = mac_lines[i] if i < len(mac_lines) else ""
        mob = mobile_lines[i] if i < len(mobile_lines) else ""
        match = mac == mob
        flag = "  " if match else "!="
        cursor_flag = " <" if i == cursor_row else ""
        print(f"{i:>3}  {mac[:width]:<{width}}  {flag}  {mob[:width]:<{width}}{cursor_flag}")
        if not match:
            mismatches += 1
    print(f"\nfidelity={fidelity}  cursor=({cursor_row},{cursor_col})  mismatched_rows={mismatches}/{total}")
    return mismatches


def send_input(text: str):
    # Use the cmux debug CLI to send raw input to the selected terminal.
    workspace_id, terminal_id = selected_workspace_and_terminal()
    subprocess.run(
        [DEBUG_CLI, "send", "--workspace", workspace_id, "--surface", terminal_id, text],
        env={**os.environ, "CMUX_TAG": CMUX_TAG},
        check=True,
        timeout=10,
    )


def snapshot_once():
    ws_id, term_id = selected_workspace_and_terminal()
    mac_lines = mac_visible_lines(ws_id, term_id)
    snap = mobile_snapshot(ws_id, term_id)
    mob_lines = mobile_visible_lines(snap)
    cur_row, cur_col, _ = cursor_row_col(snap)
    fidelity = (snap or {}).get("fidelity")
    return mac_lines, mob_lines, cur_row, cur_col, fidelity


def run_suite():
    suite = [
        ("blank-clear", ["clear\n"]),
        ("single-echo", ["clear\n", "echo hello\n"]),
        ("multi-line-ls", ["clear\n", "ls /usr/bin | head -5\n"]),
        ("colored-ls", ["clear\n", "ls --color=always /usr/bin | head -3\n"]),
        ("multi-line-cmd", ["clear\n", "for i in 1 2 3; do echo line-$i; done\n"]),
        ("backspace", ["clear\n", "echo abc\b\b\bxyz\n"]),
        ("cursor-positioning", ["clear\n", "printf '\\033[5;3HXYZ\\033[10;1H'\n"]),
    ]
    failures = []
    for name, inputs in suite:
        print(f"\n=== {name} ===")
        for chunk in inputs:
            send_input(chunk)
        time.sleep(1.0)
        mac, mob, cur_row, cur_col, fidelity = snapshot_once()
        mis = diff(mac, mob, cur_row, cur_col, fidelity)
        if mis:
            failures.append((name, mis))
    print("\n=== SUITE SUMMARY ===")
    if not failures:
        print("all cases identical (mac == mobile per visibleRows)")
    else:
        for name, mis in failures:
            print(f"  FAIL {name}: {mis} mismatched rows")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--send")
    parser.add_argument("--suite", action="store_true")
    args = parser.parse_args()

    if args.suite:
        run_suite()
        return

    if args.send:
        send_input(args.send if args.send.endswith("\n") else args.send + "\n")
        time.sleep(0.6)

    if args.watch:
        try:
            while True:
                sys.stdout.write("\x1b[2J\x1b[H")
                sys.stdout.flush()
                mac, mob, cur_row, cur_col, fidelity = snapshot_once()
                diff(mac, mob, cur_row, cur_col, fidelity)
                time.sleep(0.5)
        except KeyboardInterrupt:
            return

    mac, mob, cur_row, cur_col, fidelity = snapshot_once()
    diff(mac, mob, cur_row, cur_col, fidelity)


if __name__ == "__main__":
    main()
