#!/usr/bin/env python3
"""Focused end-to-end check: 40 representative `cmux …` commands against a
tagged cmux-next app, asserting outputs (plans/cmux-next/cli-compat.md).

Usage:
  scripts/cmux-next/cli-compat-e2e.py --socket /tmp/cmux-debug-<tag>.sock \
      --cli "<tagged app>/Contents/Resources/bin/cmux"

Creates its own workspace and closes it at the end, then (unless
--keep-daemon) ends every terminal of the tag's daemon with
`shutdown-daemon end_terminals` and fails if a PTY outlives it. Refuses the
default socket. Runs every command in a clean environment (no inherited CMUX_*).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid

UUID_RE = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")


class Runner:
    def __init__(self, cli: str, socket: str) -> None:
        self.cli = cli
        self.socket = socket
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
        self.env["CMUX_QUIET"] = "1"
        self.results: list[tuple[str, bool, str]] = []

    def raw(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        merged = dict(self.env, **(env or {}))
        return subprocess.run([self.cli, "--socket", self.socket, *args], capture_output=True, text=True, env=merged, timeout=30)

    def check(self, label: str, args: list[str], predicate, *, env: dict[str, str] | None = None, expect_fail: bool = False):
        proc = self.raw(*args, env=env)
        out = (proc.stdout or "").strip()
        err = (proc.stderr or "").strip()
        ok_exit = (proc.returncode != 0) if expect_fail else (proc.returncode == 0)
        try:
            ok = ok_exit and bool(predicate(out if not expect_fail else err or out))
        except Exception as error:  # noqa: BLE001 - report, keep going
            ok = False
            err = f"{err} predicate error: {error}"
        detail = (out or err).replace("\n", " / ")[:140]
        self.results.append((f"cmux {' '.join(args)}", ok, detail))
        print(f"{'PASS' if ok else 'FAIL'}  {label:<28} cmux {' '.join(args)[:70]}  -> {detail}", flush=True)
        return out

    def json(self, args: list[str]) -> dict:
        proc = self.raw(*args, "--json")
        return json.loads(proc.stdout or "{}")


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
    parser.add_argument("--keep-daemon", action="store_true", help="skip the shutdown-daemon end_terminals teardown")
    args = parser.parse_args()
    if os.path.realpath(args.socket) in {"/tmp/cmux-debug.sock", "/private/tmp/cmux-debug.sock"}:
        print("refusing the default socket", file=sys.stderr)
        return 2
    r = Runner(args.cli, args.socket)
    marker = f"compat-{uuid.uuid4().hex[:6]}"

    r.check("ping", ["ping"], lambda o: o == "PONG")
    r.check("capabilities", ["capabilities", "--json"], lambda o: "surface.send_text" in json.loads(o)["methods"])
    r.check("identify", ["identify", "--json"], lambda o: json.loads(o)["focused"]["workspace_ref"].startswith("workspace:"))
    r.check("list-windows", ["list-windows"], lambda o: re.search(r"\d+: [0-9A-F-]{36} selected_workspace=", o))
    r.check("current-window", ["current-window"], lambda o: UUID_RE.match(o))
    created = r.check("new-workspace", ["new-workspace", "--cwd", "/tmp"], lambda o: re.match(r"OK workspace:\d+", o))
    ws = created.split()[1] if created.startswith("OK ") else "workspace:0"
    r.check("list-workspaces", ["list-workspaces"], lambda o: ws in o)
    r.check("rename-workspace", ["rename-workspace", "--workspace", ws, marker], lambda o: o.startswith("OK"))
    r.check("list-workspaces --json", ["list-workspaces", "--json"],
            lambda o: any(w["title"] == marker for w in json.loads(o)["workspaces"]))
    r.check("select-workspace", ["select-workspace", "--workspace", ws], lambda o: o.startswith("OK"))
    r.check("current-workspace", ["current-workspace"], lambda o: o == ws)
    r.check("tree", ["tree"], lambda o: marker in o and "surface:" in o)
    r.check("tree --json", ["tree", "--json"], lambda o: json.loads(o)["windows"][0]["workspaces"])
    split = r.check("new-split right", ["new-split", "right", "--workspace", ws], lambda o: re.match(r"OK surface:\d+", o))
    right = split.split()[1] if split.startswith("OK ") else "surface:0"
    r.check("list-panes", ["list-panes", "--workspace", ws], lambda o: len([l for l in o.splitlines() if "pane:" in l]) == 2)
    r.check("new-pane down", ["new-pane", "--direction", "down", "--workspace", ws], lambda o: re.match(r"OK surface:\d+ pane:\d+", o))
    panes = r.json(["list-panes", "--workspace", ws]).get("panes", [])
    first_pane = panes[0]["ref"] if panes else "pane:0"
    r.check("new-surface", ["new-surface", "--pane", first_pane, "--workspace", ws], lambda o: re.match(r"OK surface:\d+", o))
    r.check("list-pane-surfaces", ["list-pane-surfaces", "--pane", first_pane, "--workspace", ws],
            lambda o: len([l for l in o.splitlines() if "surface:" in l]) == 2)
    r.check("list-panels", ["list-panels", "--workspace", ws], lambda o: len([l for l in o.splitlines() if "surface:" in l]) == 4)
    r.check("focus-pane", ["focus-pane", "--pane", first_pane, "--workspace", ws], lambda o: o.startswith("OK"))
    r.check("send", ["send", "--workspace", ws, "--surface", right, f"echo {marker}-out\\n"], lambda o: o.startswith("OK"))
    time.sleep(0.6)
    r.check("read-screen", ["read-screen", "--workspace", ws, "--surface", right], lambda o: f"{marker}-out" in o)
    r.check("read-screen --lines", ["read-screen", "--workspace", ws, "--surface", right, "--lines", "3", "--scrollback"],
            lambda o: len(o.splitlines()) <= 3)
    r.check("send-key", ["send-key", "--workspace", ws, "--surface", right, "ctrl+c"], lambda o: o.startswith("OK"))
    r.check("rename-tab", ["rename-tab", "--workspace", ws, "--surface", right, f"{marker}-tab"], lambda o: o.startswith("OK"))
    r.check("list-panels title", ["list-panels", "--workspace", ws], lambda o: f"{marker}-tab" in o)
    r.check("notify", ["notify", "--title", marker, "--body", "compat body", "--workspace", ws, "--surface", right],
            lambda o: o.startswith("OK"))
    r.check("list-notifications", ["list-notifications"], lambda o: marker in o)
    r.check("clear-notifications", ["clear-notifications", "--workspace", ws], lambda o: o.startswith("OK"))
    r.check("set-status", ["set-status", "agent", "Running", "--icon", "bolt", "--workspace", ws], lambda o: o.startswith("OK"))
    r.check("list-status", ["list-status", "--workspace", ws], lambda o: "agent=Running icon=bolt" in o)
    r.check("set-progress", ["set-progress", "0.5", "--label", "Half", "--workspace", ws], lambda o: o.startswith("OK"))
    r.check("log", ["log", "--workspace", ws, "--", "compat log line"], lambda o: o.startswith("OK"))
    r.check("sidebar-state", ["sidebar-state", "--workspace", ws],
            lambda o: "progress=0.50 Half" in o and "status_count=1" in o and "[info] compat log line" in o)
    r.check("env caller identify", ["identify", "--json"], lambda o: json.loads(o)["caller"]["workspace_ref"] == ws,
            env={"CMUX_WORKSPACE_ID": next((w.get("id", "") for w in r.json(["list-workspaces", "--id-format", "both"]).get("workspaces", [])
                                            if w.get("ref") == ws), "")})
    opened = r.check("browser open", ["browser", "open", "about:blank", "--workspace", ws], lambda o: "surface=surface:" in o)
    browser = re.search(r"surface=(surface:\d+)", opened)
    bref = browser.group(1) if browser else "surface:0"
    time.sleep(0.8)
    r.check("browser eval", ["browser", bref, "eval", "1 + 41"], lambda o: o == "42")
    r.check("browser url", ["browser", bref, "url"], lambda o: o.startswith("about:"))
    r.check("unsupported is typed", ["trigger-flash", "--workspace", ws], lambda o: "unsupported" in o, expect_fail=True)
    r.check("close-workspace", ["close-workspace", "--workspace", ws], lambda o: o.startswith("OK"))
    if not args.keep_daemon:
        ok, detail = teardown(args.cli, args.socket)
        r.results.append(("teardown end_terminals", ok, detail))
        print(f"{'PASS' if ok else 'FAIL'} teardown end_terminals: {detail}")

    passed = sum(1 for _, ok, _ in r.results if ok)
    print(f"\n{passed}/{len(r.results)} passed")
    return 0 if passed == len(r.results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
