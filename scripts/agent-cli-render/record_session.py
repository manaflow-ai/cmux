#!/usr/bin/env python3
"""Record a real agent CLI session for cmux-agent-cli-render's parity fixtures.

The CLI runs in a PTY of exactly COLSxROWS (an iPhone's grid, or the Mac's), driven by a script:
one prompt that writes a file, edits it and runs it, approving each permission prompt. It writes
the fixture shape `tests/parity.rs` loads:

- `pty.jsonl`: every byte the CLI wrote, `{"t_ms", "b64"}`, and the size as `{"t_ms", "resize"}`;
- `moments.json`: the times the script looked at the screen (`start`, `typed`, `working`,
  `approvalN`, `after_approvalN`, `done`);
- `transcript.jsonl`: the CLI's own transcript of the session (Claude Code's project log).

Leo, 2026-11-25: "we know what a Mac's Claude code pane looks like. And we know it/can know it for
any variation/combination at various phone sizes". Run it on a fleet Mac with the CLI signed in,
never on Leo's own Macs:

    record_session.py --cols 54 --rows 38 --out DIR [--cli claude] [--timeout 180]
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import json
import os
import pty
import select
import signal
import struct
import tempfile
import termios
import time
from pathlib import Path

PROMPT = (
    "Create hello.py that prints hi. Then use the Edit tool to change it to print hello. "
    "Then run it with python3. Keep replies to one line."
)
# A permission prompt on screen (Claude Code 2.x).
ASKS = (b"Do\x1b", b"Do you want")


def now_ms() -> int:
    return int(time.time() * 1000)


class Session:
    def __init__(self, argv: list[str], cols: int, rows: int, cwd: Path, log: Path) -> None:
        self.log = log.open("w")
        self.recent = b""
        self.last_write = 0
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(cwd)
            env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor", COLUMNS=str(cols), LINES=str(rows))
            os.execvpe(argv[0], argv, env)
        self.pid, self.fd = pid, fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.log.write(json.dumps({"t_ms": now_ms(), "resize": [cols, rows]}) + "\n")

    def pump(self, seconds: float) -> None:
        end = time.time() + seconds
        while (left := end - time.time()) > 0:
            ready, _, _ = select.select([self.fd], [], [], min(left, 0.05))
            if not ready:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            t = now_ms()
            self.last_write = t
            self.recent = (self.recent + data)[-16384:]
            self.log.write(json.dumps({"t_ms": t, "b64": base64.b64encode(data).decode()}) + "\n")
            self.log.flush()

    def idle(self, quiet_ms: int, limit: float) -> None:
        """Until `quiet_ms` pass with no write (after the CLI's first write)."""
        end = time.time() + limit
        while time.time() < end:
            self.pump(0.1)
            if self.last_write and now_ms() - self.last_write >= quiet_ms:
                return

    def send(self, data: bytes) -> None:
        os.write(self.fd, data)

    def stop(self) -> None:
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        self.log.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cols", type=int, required=True)
    ap.add_argument("--rows", type=int, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--cli", default="claude")
    ap.add_argument("--timeout", type=float, default=180)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="clirender.")) / "work"
    work.mkdir()
    moments: list[dict] = []

    def moment(name: str) -> None:
        moments.append({"name": name, "t_ms": now_ms()})

    s = Session([args.cli], args.cols, args.rows, work, args.out / "pty.jsonl")
    try:
        s.idle(1500, 60)
        # Words on screen are placed with cursor moves (`ESC [ n G`), not spaces.
        if b"Accessing" in s.recent and b"trust" in s.recent:
            # The workspace trust question ("No, exit" first): the second answer.
            s.send(b"\x1b[B")
            s.pump(0.3)
            s.send(b"\r")
            s.recent = b""
            s.last_write = 0
            s.idle(2000, 60)
        # The input box is drawn (its effort hint) before anything is typed.
        end = time.time() + 30
        while b"/effort" not in s.recent and time.time() < end:
            s.pump(0.2)
        s.idle(1500, 10)
        moment("start")
        s.send(PROMPT.encode())
        s.pump(1.0)
        moment("typed")
        s.send(b"\r")
        s.pump(1.0)
        # A second Enter: a no-op on the emptied box, the submit if the first came too soon.
        s.send(b"\r")
        sent = time.time()
        s.pump(4.0)
        moment("working")
        approvals = 0
        end = time.time() + args.timeout
        tick = 0
        while time.time() < end:
            # A look at the screen every 1.5 s while the turn runs (spinner, tool blocks as
            # they arrive), until 1.2 s pass with no write.
            start = time.time()
            s.idle(1200, 1.5)
            if now_ms() - s.last_write < 1200:
                tick += 1
                moment(f"working{tick}")
                continue
            _ = start
            tail = s.recent[-6000:]
            if any(a in tail for a in ASKS):
                approvals += 1
                moment(f"approval{approvals}")
                s.send(b"\r")
                s.recent = b""
                s.pump(2.0)
                moment(f"after_approval{approvals}")
                continue
            # Quiet with no question: the spinner (redrawn ~10 times a second while a turn
            # runs) has stopped, so the turn ended.
            # (Not before 8 s: a turn can sit quiet before its first token.)
            if now_ms() - s.last_write >= 1200 and time.time() - sent > 8:
                s.idle(2000, 10)
                moment("done")
                break
        else:
            raise SystemExit("record_session: timed out before the turn ended")
    finally:
        s.stop()
    (args.out / "moments.json").write_text(json.dumps(moments, indent=1) + "\n")
    slug = str(work.resolve()).replace("/", "-").replace(".", "-")
    project = Path.home() / ".claude" / "projects" / slug
    logs = sorted(project.glob("*.jsonl"), key=lambda p: p.stat().st_mtime) if project.is_dir() else []
    if logs:
        # Only the person's, the assistant's and the system's turn lines: the log also holds
        # prompt snapshots, skill and tool listings and request shapes, which carry the
        # recording machine's own instructions and stay out of a public fixture.
        with logs[-1].open() as src, (args.out / "transcript.jsonl").open("w") as dst:
            for line in src:
                if json.loads(line).get("type") in ("user", "assistant", "system"):
                    dst.write(line if line.endswith("\n") else line + "\n")
    print(json.dumps({"out": str(args.out), "moments": len(moments), "approvals": approvals,
                      "transcript": bool(logs), "cwd": str(work)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
