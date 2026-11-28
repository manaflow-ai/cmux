#!/usr/bin/env python3
"""Live check of `agent-cli-phone-grid-v1`: a real daemon, a real Claude Code in one of its
terminals, then the Mac pane and the phone's view of it side by side.

Run on a fleet Mac with Claude Code signed in (never on Leo's Macs), from a cmux-tui build:

    phone_grid_live.py --bin TARGET/debug --out DIR [--cols 50 --rows 34] [--mac 110x32]

It starts `cmux-tui server start` on a private socket, opens a workspace at the Mac's grid,
starts `claude` there (the daemon's own `claude` shim adds the hooks that report the session),
runs one prompt, then runs `phone_grid_proof` (cmux-agent-cli-render's example) against it.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path

PROMPT = "Create hello.py that prints hi, run it with python3, then say done in one line."


class Client:
    def __init__(self, path: str) -> None:
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(path)
        self.sock.settimeout(30)
        self.buf = b""
        self.next = 1

    def request(self, cmd: str, **params) -> dict:
        rid = self.next
        self.next += 1
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                self.buf += self.sock.recv(1 << 20)
            line, self.buf = self.buf.split(b"\n", 1)
            msg = json.loads(line)
            if msg.get("id") == rid:
                if msg.get("ok") is False or "error" in msg:
                    raise SystemExit(f"{cmd}: {msg}")
                return msg.get("data", msg.get("result", msg))


def screen(c: Client, surface: int) -> str:
    r = c.request("read-screen", surface=surface)
    return r.get("text") or json.dumps(r)


def wait_for(c: Client, surface: int, pred, limit: float, what: str) -> str:
    end = time.time() + limit
    text = ""
    while time.time() < end:
        text = screen(c, surface)
        if pred(text):
            return text
        time.sleep(0.5)
    raise SystemExit(f"timed out waiting for {what}:\n{text}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", type=Path, required=True, help="the cargo target dir holding cmux-tui and the example")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--cols", type=int, default=50)
    ap.add_argument("--rows", type=int, default=34)
    ap.add_argument("--mac", default="110x32")
    args = ap.parse_args()
    mc, mr = (int(x) for x in args.mac.split("x"))
    run = Path(tempfile.mkdtemp(prefix="phonegrid."))
    sock = str(run / "mux.sock")
    daemon = subprocess.Popen(
        [str(args.bin / "cmux-tui"), "server", "start", "--session", "phonegrid", "--socket", sock],
        stdout=open(run / "daemon.out", "w"), stderr=open(run / "daemon.err", "w"),
    )
    try:
        for _ in range(200):
            if os.path.exists(sock):
                break
            time.sleep(0.05)
        c = Client(sock)
        c.request("set-client-info", name="phone-grid-live", kind="cli")
        ws = c.request("new-workspace", name="phone grid", cols=mc, rows=mr)
        surface = ws.get("surface") or ws.get("surface_id") or (ws.get("surfaces") or [None])[0]
        print("workspace", json.dumps(ws)[:300])
        work = run / "work"
        work.mkdir()
        # A scratch Claude home (phone-grid-live.sh) trusts the folder up front.
        home = os.environ.get("CLAUDE_CONFIG_DIR")
        if home:
            config = Path(home) / ".claude.json"
            data = json.loads(config.read_text()) if config.exists() else {}
            data.setdefault("projects", {})[os.path.realpath(work)] = {"hasTrustDialogAccepted": True}
            config.write_text(json.dumps(data))
        time.sleep(1.5)
        c.request("send", surface=surface, text=f"cd {work} && claude\r")
        text = wait_for(c, surface, lambda t: "/effort" in t or "trust" in t, 60, "claude to start")
        if "trust" in text and "/effort" not in text:
            c.request("send", surface=surface, bytes="G1tC")  # ESC [ B: the second answer
            time.sleep(0.3)
            c.request("send", surface=surface, text="\r")
            wait_for(c, surface, lambda t: "/effort" in t, 60, "the prompt box")
        time.sleep(1.5)
        c.request("send", surface=surface, text=PROMPT)
        time.sleep(0.8)
        c.request("send", surface=surface, text="\r")
        time.sleep(8)
        wait_for(c, surface, lambda t: "esc to interrupt" not in t and "❯" in t, 180, "the turn to end")
        time.sleep(2)
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "mac-read-screen.txt").write_text(screen(c, surface))
        proof = subprocess.run(
            [str(args.bin / "examples" / "phone_grid_proof"), sock, str(surface), str(args.cols), str(args.rows), str(args.out)],
            capture_output=True, text=True, timeout=60,
        )
        print(proof.stdout, proof.stderr[-2000:])
        # The same turn as typed on the phone: a draft shows on both.
        c.request("send", surface=surface, text="what did you just do")
        time.sleep(1.5)
        typed = args.out / "typed"
        proof = subprocess.run(
            [str(args.bin / "examples" / "phone_grid_proof"), sock, str(surface), str(args.cols), str(args.rows), str(typed)],
            capture_output=True, text=True, timeout=60,
        )
        print(proof.stdout, proof.stderr[-2000:])
        return proof.returncode
    finally:
        daemon.terminate()
        try:
            daemon.wait(10)
        except subprocess.TimeoutExpired:
            daemon.kill()
        print("daemon log:", (run / "daemon.err").read_text()[-1500:])


if __name__ == "__main__":
    raise SystemExit(main())
