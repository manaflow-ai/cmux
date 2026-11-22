#!/usr/bin/env python3
"""Capture cmux-tui render-mode and byte-mode attach fixtures for the
CmuxNextMobile render-grid tests.

Starts a throwaway cmux-tui session, runs deterministic programs in PTYs,
records the first `render-state` (render attach) and `vt-state` (byte attach)
for each, then shuts the daemon down and verifies no terminal host survives.

Usage: scripts/cmux-next/capture-mobile-render-fixtures.py <cmux-tui binary> <out dir>
"""
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time

PROGRAMS = {
    # Plain prompt-like output with SGR colors, bold, a wide glyph and a cursor mid-row.
    "styled-primary": r"printf '\033[1;31mred bold\033[0m plain \033[38;2;10;200;30mrgb\033[0m\n\033[4munder\033[0m 日本 \033[7minv\033[0m\n$ '; exec cat",
    # Full-screen TUI on the alternate screen with a background fill and the cursor hidden.
    "alternate-screen": r"printf '\033[?1049h\033[H\033[44m top bar \033[0m\033[3;5H\033[3mitalic\033[0m\033[?25l'; exec cat",
}
COLS, ROWS = 40, 6


def request(sock_file, sock, payload):
    sock.sendall((json.dumps(payload) + "\n").encode())
    while True:
        line = sock_file.readline()
        if not line:
            raise RuntimeError("daemon closed")
        message = json.loads(line)
        if message.get("id") == payload["id"]:
            if not message.get("ok"):
                raise RuntimeError(f"{payload['cmd']}: {message}")
            return message.get("data")


def connect(path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(path)
    return sock, sock.makefile("r")


def attach_first_event(path, surface, mode, event_name):
    sock, f = connect(path)
    try:
        request(f, sock, {"id": 1, "cmd": "identify"})
        sock.sendall((json.dumps({"id": 2, "cmd": "attach-surface", "surface": surface, "mode": mode,
                                  "cols": COLS, "rows": ROWS}) + "\n").encode())
        while True:
            message = json.loads(f.readline())
            if message.get("event") == event_name:
                return message
    finally:
        sock.close()


def main():
    binary, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    session = f"iosfix-{os.getpid()}"
    runtime = tempfile.mkdtemp(prefix="cmux-iosfix-")
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TERM": "xterm-256color",
           "XDG_RUNTIME_DIR": runtime, "XDG_STATE_HOME": os.path.join(runtime, "state")}
    server = subprocess.Popen([binary, "server", "start", "--session", session], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        status = None
        for _ in range(100):
            probe = subprocess.run([binary, "server", "status", "--session", session, "--json"], env=env,
                                   capture_output=True, text=True)
            if probe.returncode == 0:
                status = json.loads(probe.stdout)
                if status.get("socket") or status.get("socket_path"):
                    break
            time.sleep(0.1)
        path = status.get("socket") or status.get("socket_path")
        sock, f = connect(path)
        identity = request(f, sock, {"id": 1, "cmd": "identify"})
        workspace = request(f, sock, {"id": 2, "cmd": "create-workspace", "name": "fixtures"})
        key = workspace["key"]
        for index, (name, program) in enumerate(PROGRAMS.items()):
            created = request(f, sock, {"id": 10 + index, "cmd": "create-terminal", "key": key,
                                        "argv": ["/bin/sh", "-c", program], "cols": COLS, "rows": ROWS})
            surface = created["surface"]
            time.sleep(0.6)
            render = attach_first_event(path, surface, "render", "render-state")
            vt = attach_first_event(path, surface, "bytes", "vt-state")
            fixture = {"protocol": identity.get("protocol"), "cmux_tui_version": identity.get("version"),
                       "program": program, "render_state": render, "vt_state": vt}
            with open(os.path.join(out_dir, f"render-{name}.json"), "w") as out:
                json.dump(fixture, out, indent=1, sort_keys=True)
                out.write("\n")
            request(f, sock, {"id": 50 + index, "cmd": "close-terminal", "terminal_id": created["terminal_id"]})
        sock.close()
    finally:
        # Terminal hosts are the daemon's children and outlive a plain stop;
        # `--end-terminals` ends every one (cmux-tui terminal-reap-v1). Their
        # args do not name the session, so check the daemon's children.
        hosts = subprocess.run(["pgrep", "-P", str(server.pid), "-f", "__terminal-host"],
                               capture_output=True, text=True).stdout.split()
        subprocess.run([binary, "server", "stop", "--session", session, "--end-terminals"], env=env, timeout=90, check=False)
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(server.pid, signal.SIGTERM)
            server.wait(timeout=5)
        def running(pid):
            stat = subprocess.run(["ps", "-o", "stat=", "-p", pid], capture_output=True, text=True).stdout.strip()
            return stat[:1] not in ("", "Z")
        leaked = [pid for pid in hosts if running(pid)]
        for _ in range(100):  # host exits trail the stop reply by milliseconds
            if not leaked:
                break
            time.sleep(0.05)
            leaked = [pid for pid in leaked if running(pid)]
        if leaked:
            print(f"error: terminal hosts outlived server stop --end-terminals: {leaked}", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
