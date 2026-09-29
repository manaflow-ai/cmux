#!/usr/bin/env python3
"""End every terminal of a tagged cmux-next build's daemon and check that no
PTY outlives it (cmux-tui `terminal-reap-v1`).

Test and bench scripts call `end_terminals()` as their last step. It finds
the tag's daemon (`server status`, never starting one), records its
terminal host children (`cmux-tui __terminal-host`, one PTY each), sends
`shutdown-daemon {end_terminals:true}` on a fresh unsubscribed socket, and
waits for those hosts to exit. The app reconnects and starts a new daemon
afterwards; kill the tagged instance when done.

Usage:
  scripts/cmux-next/daemon_teardown.py --tag <tag> [--binary <cmux-tui>]
Exit 1 when a host outlived the shutdown.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time


def app_binary_for_tag(tag: str) -> str | None:
    """The tagged app's bundled cmux-tui, from its running process."""
    out = subprocess.run(["pgrep", "-f", f"cmux DEV {tag}.app/Contents/MacOS/cmux DEV"], capture_output=True, text=True).stdout.split()
    if not out:
        return None
    comm = subprocess.run(["ps", "-o", "comm=", "-p", out[0]], capture_output=True, text=True).stdout.strip()
    marker = ".app/"
    if marker not in comm:
        return None
    return comm[: comm.index(marker) + 4] + "/Contents/Resources/bin/cmux-tui"


def daemon_status(binary: str, tag: str) -> dict | None:
    state = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{tag}/tui")
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "CMUX_TUI_STATE_DIR": state}
    out = subprocess.run([binary, "--session", f"cmux-app-{tag}", "--json", "server", "status"],
                         capture_output=True, text=True, env=env, timeout=10).stdout.strip()
    if not out:
        return None
    data = json.loads(out.splitlines()[-1])
    return data if data.get("status") == "running" else None


def terminal_hosts(daemon_pid: int) -> set[int]:
    out = subprocess.run(["pgrep", "-P", str(daemon_pid), "-f", "__terminal-host"], capture_output=True, text=True).stdout
    return {int(pid) for pid in out.split()}


def alive(pids: set[int]) -> set[int]:
    if not pids:
        return set()
    out = subprocess.run(["ps", "-o", "pid=,stat=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    return {int(line.split()[0]) for line in out.splitlines() if line.split() and not line.split()[1].startswith("Z")}


def request(path: str, body: dict, timeout: float) -> dict:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(path)
    try:
        sock.sendall((json.dumps(body) + "\n").encode())
        buffer = b""
        while True:
            while b"\n" not in buffer:
                chunk = sock.recv(1 << 20)
                if not chunk:
                    raise ConnectionError(f"{body.get('cmd')}: socket closed before the reply")
                buffer += chunk
            line, buffer = buffer.split(b"\n", 1)
            message = json.loads(line)
            if message.get("id") == body["id"]:
                return message
    finally:
        sock.close()


def end_terminals(binary: str, tag: str, exit_timeout: float = 10.0) -> dict:
    """Returns {daemon_pid, hosts_before, ended_terminals, hosts_leaked, error}."""
    status = daemon_status(binary, tag)
    if status is None:
        return {"daemon_pid": None, "hosts_before": 0, "ended_terminals": 0, "hosts_leaked": [], "error": "no running daemon"}
    identity = request(status["socket"], {"id": 1, "cmd": "identify"}, 10).get("data", {})
    if "terminal-reap-v1" not in identity.get("capabilities", []):
        return {"daemon_pid": identity.get("pid"), "hosts_before": 0, "ended_terminals": 0, "hosts_leaked": [],
                "error": "daemon lacks terminal-reap-v1 (shutdown-daemon end_terminals)"}
    pid = int(identity["pid"])
    hosts = terminal_hosts(pid)
    reply = request(status["socket"], {"id": 2, "cmd": "shutdown-daemon", "pid": pid, "generation": identity["generation"],
                                       "end_terminals": True}, 90)
    if not reply.get("ok"):
        return {"daemon_pid": pid, "hosts_before": len(hosts), "ended_terminals": 0, "hosts_leaked": sorted(alive(hosts)),
                "error": f"shutdown-daemon failed: {reply.get('error')}"}
    deadline = time.monotonic() + exit_timeout
    remaining = alive(hosts)
    while remaining and time.monotonic() < deadline:
        time.sleep(0.05)
        remaining = alive(remaining)
    return {"daemon_pid": pid, "hosts_before": len(hosts), "ended_terminals": reply["data"].get("ended_terminals", 0),
            "hosts_leaked": sorted(remaining), "error": None}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--binary", help="cmux-tui of the tagged app (default: from its running process)")
    args = parser.parse_args()
    binary = args.binary or app_binary_for_tag(args.tag)
    if not binary:
        print(f"teardown: no running cmux DEV {args.tag}.app; pass --binary", file=sys.stderr)
        return 2
    result = end_terminals(binary, args.tag)
    print(json.dumps(result))
    return 1 if result["error"] or result["hosts_leaked"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
