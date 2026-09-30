#!/usr/bin/env python3
"""Focused end-to-end check: 40 representative `cmux …` commands against a
tagged cmux-next app, asserting outputs (plans/cmux-next/cli-compat.md).

Usage:
  scripts/cmux-next/cli-compat-e2e.py --socket /tmp/cmux-debug-<tag>.sock \
      --cli "<tagged app>/Contents/Resources/bin/cmux" \
      [--remote-destination localhost --remote-binary /tmp/x/cmux-tui --remote-state-dir /tmp/x/state]

With --remote-destination the script also connects an SSH machine (a second
cmux-tui session, `cmux remote connect`) and checks session-qualified ids
and --session/--machine against it (plans/cmux-next/data-model.md 1.3),
then forgets the machine. localhost with a scratch binary and state dir is
a second local daemon session.

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


def remote_cases(r: Runner, args, marker: str) -> None:
    """Session-qualified ids against a second cmux-tui session (an SSH machine)."""
    connect = ["remote", "connect", "--destination", args.remote_destination, "--session", args.remote_session]
    if args.remote_binary:
        connect += ["--binary", args.remote_binary]
    if args.remote_state_dir:
        connect += ["--state-dir", args.remote_state_dir]
    r.check("remote connect", connect, lambda o: o.startswith("OK"))
    session = None
    for _ in range(60):
        machines = r.json(["list-machines"]).get("sessions", [])
        session = next((m for m in machines if not m.get("home") and m.get("state") == "connected"
                        and args.remote_session in (m.get("session_name") or "")), None)
        if session:
            break
        time.sleep(1)
    r.results.append(("remote session connected", session is not None, json.dumps(session)[:140]))
    print(f"{'PASS' if session else 'FAIL'}  remote session connected  -> {json.dumps(session)[:140]}", flush=True)
    if not session:
        return
    q = session["qualifier"]
    r.check("list-machines", ["list-machines"], lambda o: q in o and "* home" in o)
    created = r.check("new-workspace --session", ["--session", q, "new-workspace", "--cwd", "/tmp"],
                      lambda o: re.match(rf"OK {re.escape(q)}:workspace:\d+", o))
    rws = created.split()[1] if created.startswith("OK ") else f"{q}:workspace:0"
    r.check("list-workspaces qualified", ["list-workspaces"], lambda o: rws in o and "workspace:" in o)
    r.check("list-workspaces --machine", ["list-workspaces", "--machine", q],
            lambda o: all(line.strip().split()[0].startswith(q + ":") for line in o.splitlines() if line.strip()))
    listed = r.json(["list-workspaces", "--session", q]).get("workspaces", [])
    named = any(w.get("session") == q and w.get("session_id") == session["id"] for w in listed)
    r.results.append(("workspace json names its session", named, json.dumps(listed)[:140]))
    print(f"{'PASS' if named else 'FAIL'}  workspace json names its session  -> {len(listed)} workspaces", flush=True)
    panels = r.json(["list-panels", "--workspace", rws]).get("surfaces", [])
    rsurface = panels[0]["ref"] if panels else f"{q}:surface:0"
    r.check("send qualified", ["send", "--surface", rsurface, f"echo {marker}-remote\\n"], lambda o: o.startswith("OK"))
    time.sleep(0.8)
    r.check("read-screen qualified", ["read-screen", "--surface", rsurface], lambda o: f"{marker}-remote" in o)
    local_ref = rsurface.split(":", 1)[1]
    r.check("read-screen --session", ["read-screen", "--session", q, "--surface", local_ref, "--lines", "5"],
            lambda o: f"{marker}-remote" in o)
    r.check("new-split remote", ["new-split", "right", "--workspace", rws], lambda o: re.match(rf"OK {re.escape(q)}:surface:\d+", o))
    r.check("tab action qualified target", ["tab", "rename", "--target", rsurface, "--name", f"{marker}-rt"], lambda o: o.startswith("OK"))
    r.check("list-panels title remote", ["list-panels", "--workspace", rws], lambda o: f"{marker}-rt" in o)
    r.check("tree names remote", ["tree"], lambda o: rws in o)
    r.check("move across sessions is typed", ["move-surface", "--surface", rsurface, "--pane", "pane:1"],
            lambda o: "another session" in o, expect_fail=True)
    r.check("close-workspace remote", ["close-workspace", "--workspace", rws], lambda o: o.startswith("OK"))
    r.check("remote forget", ["remote", "forget", "--target", f"machine:{session['machine_id']}", "--confirm", "true"],
            lambda o: o.startswith("OK"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--keep-daemon", action="store_true", help="skip the shutdown-daemon end_terminals teardown")
    parser.add_argument("--remote-destination", help="SSH destination for the remote-target cases (e.g. localhost)")
    parser.add_argument("--remote-session", default="compatremote", help="cmux-tui session name on the remote machine")
    parser.add_argument("--remote-binary", help="cmux-tui path on the remote machine (no spaces)")
    parser.add_argument("--remote-state-dir", help="cmux-tui state directory on the remote machine")
    args = parser.parse_args()
    if os.path.realpath(args.socket) in {"/tmp/cmux-debug.sock", "/private/tmp/cmux-debug.sock"}:
        print("refusing the default socket", file=sys.stderr)
        return 2
    r = Runner(args.cli, args.socket)
    marker = f"compat-{uuid.uuid4().hex[:6]}"

    r.check("ping", ["ping"], lambda o: o == "PONG")
    r.check("capabilities", ["capabilities", "--json"], lambda o: "surface.send_text" in json.loads(o)["methods"])
    # A window may show a remote session's workspace (`build-box:workspace:2`).
    r.check("identify", ["identify", "--json"],
            lambda o: re.match(r"^([A-Za-z0-9._-]+:)?workspace:\d+$", json.loads(o)["focused"]["workspace_ref"]))
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
    # Generated `cmux <noun> <verb>` commands, including nouns that are also
    # legacy top-level commands (`tab`, `pane`, `workspace-group`): the CLI
    # must route them to the app's actions, never "Unknown command", while
    # their legacy forms (`browser open`, `browser <surface> eval` above)
    # keep working.
    r.check("tab new-webkit", ["tab", "new-webkit", "--url", "about:blank"], lambda o: o.startswith("OK"))
    # Chromium either opens or refuses with the build's reason (fleet builds
    # have no CEF); both prove the verb resolved.
    proc = r.raw("tab", "new-chromium", "--url", "about:blank")
    chromium = (proc.stdout + proc.stderr).strip()
    ok = "Unknown command" not in chromium and (proc.returncode == 0 or "Chromium" in chromium)
    r.results.append(("cmux tab new-chromium", ok, chromium[:140]))
    print(f"{'PASS' if ok else 'FAIL'}  {'tab new-chromium':<28} cmux tab new-chromium  -> {chromium[:140]}", flush=True)
    r.check("pane split-right", ["pane", "split-right"], lambda o: o.startswith("OK"))
    r.check("workspace-group create", ["workspace-group", "create", "--name", f"{marker}-group"], lambda o: o.startswith("OK"))
    nouns = sorted({a.get("noun") for a in r.json(["action", "list"]).get("actions", []) if a.get("noun")})
    unrouted = [n for n in nouns if "Unknown command" in (r.raw(n).stdout + r.raw(n).stderr)]
    r.results.append(("every action noun routes", bool(nouns) and not unrouted, ", ".join(unrouted) or f"{len(nouns)} nouns"))
    print(f"{'PASS' if nouns and not unrouted else 'FAIL'}  every action noun routes  -> {', '.join(unrouted) or len(nouns)}", flush=True)
    r.check("close-workspace", ["close-workspace", "--workspace", ws], lambda o: o.startswith("OK"))
    if args.remote_destination:
        remote_cases(r, args, marker)
    if not args.keep_daemon:
        ok, detail = teardown(args.cli, args.socket)
        r.results.append(("teardown end_terminals", ok, detail))
        print(f"{'PASS' if ok else 'FAIL'} teardown end_terminals: {detail}")

    passed = sum(1 for _, ok, _ in r.results if ok)
    print(f"\n{passed}/{len(r.results)} passed")
    return 0 if passed == len(r.results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
