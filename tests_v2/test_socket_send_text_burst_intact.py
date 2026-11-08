#!/usr/bin/env python3
"""Regression: a multi-KB surface.send_text must reach the PTY reader intact.

A slow raw-mode reader keeps the PTY input queue full while the terminal
still has chunks queued. termio's write pool used to hand a queued request
slot out again after its first growth, which cut libxev's write queue and
dropped every request behind it with no error: a 5 KB send arrived with
about 1.7 KB missing from the middle.
"""
from __future__ import annotations

import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
PAYLOAD_BYTES = 5000
ROUNDS = int(os.environ.get("CMUX_SEND_BURST_ROUNDS", "3"))

READER = """import os, sys, tty, time
sleep_s = float(sys.argv[1]); out = sys.argv[2]
tty.setraw(0)
open(out + ".ready", "w").write("1")
buf = b""
while True:
    chunk = os.read(0, 64)
    if not chunk:
        break
    buf += chunk
    time.sleep(sleep_s)
    if b"\\x04" in chunk:
        break
open(out, "wb").write(buf)
"""


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for(path: Path, timeout_s: float) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise cmuxError(f"timed out waiting for {path}")


def _payload() -> bytes:
    text = "".join(f"{i:07d} " for i in range(PAYLOAD_BYTES // 8 + 1))
    return text[:PAYLOAD_BYTES].encode("ascii")


def _first_terminal_surface_id(payload: dict) -> str:
    for row in payload.get("surfaces") or []:
        if row.get("type") == "terminal" and row.get("id"):
            return str(row["id"])
    raise cmuxError(f"surface.list returned no terminal surface: {payload}")


def _describe_gap(expected: bytes, got: bytes) -> str:
    prefix = 0
    while prefix < min(len(expected), len(got)) and expected[prefix] == got[prefix]:
        prefix += 1
    return (
        f"received {len(got)} of {len(expected)} bytes; "
        f"first difference at byte {prefix} ({len(expected) - len(got)} bytes missing)"
    )


def _run_round(c: cmux, round_index: int) -> None:
    tmp = Path(tempfile.mkdtemp(prefix="cmux-send-burst-"))
    reader = tmp / "reader.py"
    reader.write_text(READER, encoding="utf-8")
    received = tmp / f"received-{round_index}.bin"

    payload = c._call("workspace.create", {}) or {}
    workspace_id = str(payload.get("workspace_id") or "")
    _must(bool(workspace_id), f"workspace.create returned no workspace_id: {payload}")
    try:
        surface_id = _first_terminal_surface_id(
            c._call("surface.list", {"workspace_id": workspace_id}) or {}
        )

        def send(text: str) -> None:
            c._call(
                "surface.send_text",
                {"workspace_id": workspace_id, "surface_id": surface_id, "text": text},
            )

        # A fresh pane: every round exercises the pool's first growth.
        send(f"python3 {reader} 0.03 {received}\n")
        _wait_for(Path(str(received) + ".ready"), timeout_s=60.0)

        expected = _payload() + b"\x04"
        send(_payload().decode("ascii"))
        send("\x04")
        _wait_for(received, timeout_s=60.0)
        got = received.read_bytes()
        _must(got == expected, f"round {round_index}: {_describe_gap(expected, got)}")
    finally:
        try:
            c.close_workspace(workspace_id)
        except Exception:
            pass


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        for i in range(ROUNDS):
            _run_round(c, i)
    print(f"PASS: {ROUNDS} x {PAYLOAD_BYTES}-byte surface.send_text bursts arrived intact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
