#!/usr/bin/env python3
"""Regression: Cmd+K (Ghostty `clear_screen`) at a shell prompt erases ALL scrollback.

Before the fix, the prompt-aware clear scrolled the visible rows into history
after history had already been erased, so exactly one screen of old output
survived in scrollback and Cmd+K had to be pressed twice.

Run against a TAGGED build only (never the user's /tmp/cmux-debug.sock):

    CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_clear_screen_shortcut_erases_all_scrollback.py
"""

from __future__ import annotations

import os
import re
import sys
import time
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "")
LINE_PREFIX = "CMUX_CLRSCR_LINE_"
LINE_COUNT = 400
# A prompt carrying OSC 133 A/B marks so the terminal knows the cursor is at a
# shell prompt (the code path that used to leak one screen into scrollback).
# Works whether or not the shell already loads Ghostty's integration.
MARKED_PROMPT_CMD = (
    "if [ -n \"$ZSH_VERSION\" ]; then "
    "PS1=$'%{\\e]133;A\\a%}clrscr$ %{\\e]133;B\\a%}'; "
    "else PS1='\\[\\e]133;A\\a\\]clrscr$ \\[\\e]133;B\\a\\]'; fi"
)


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for(pred: Callable[[], bool], timeout_s: float, step_s: float = 0.3) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            if pred():
                return
        except cmuxError as exc:
            # The debug socket throttles tight polling loops; back off and retry.
            if "rate_limited" not in str(exc):
                raise
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _read(c: cmux, ws: str, surface: str, *, scrollback: bool) -> str:
    payload = c._call(
        "surface.read_text",
        {"workspace_id": ws, "surface_id": surface, "scrollback": scrollback},
    ) or {}
    return str(payload.get("text") or "")


def main() -> int:
    _must(
        bool(re.fullmatch(r"/tmp/cmux-debug-[A-Za-z0-9][A-Za-z0-9_-]*\.sock", SOCKET_PATH)),
        "CMUX_SOCKET_PATH must be an explicit tagged socket (/tmp/cmux-debug-<tag>.sock)",
    )
    ws = ""
    with cmux(SOCKET_PATH) as c:
        created = c._call("workspace.create") or {}
        ws = str(created.get("workspace_id") or "")
        _must(bool(ws), f"workspace.create returned no workspace_id: {created}")
        try:
            c._call("workspace.select", {"workspace_id": ws})
            surfaces = (c._call("surface.list", {"workspace_id": ws}) or {}).get("surfaces") or []
            _must(bool(surfaces), "workspace has no surfaces")
            surface = str(surfaces[0].get("id") or "")
            _must(bool(surface), f"surface without id: {surfaces}")

            def send(text: str) -> None:
                c._call("surface.send_text", {"workspace_id": ws, "surface_id": surface, "text": text})

            def has_exact_line(needle: str, *, scrollback: bool = False) -> bool:
                # Exact-line match so a command echo containing the marker does
                # not count; only the command's own output does.
                return needle in {ln.strip() for ln in _read(c, ws, surface, scrollback=scrollback).splitlines()}

            # Wait for the shell to actually execute commands. Typeahead sent
            # before zsh finishes starting is discarded, so resend until the
            # marker is printed as its own line.
            ready = f"CMUX_CLRSCR_READY_{int(time.time() * 1000)}"
            deadline = time.time() + 60.0
            while True:
                send(f"echo {ready}\n")
                try:
                    _wait_for(lambda: has_exact_line(ready), timeout_s=3.0)
                    break
                except cmuxError:
                    _must(time.time() < deadline, "shell never became ready")

            # Install a prompt with OSC 133 marks.
            # Use a known shell because the prompt setup uses POSIX shell syntax.
            send("exec /bin/bash --noprofile --norc\n")
            _wait_for(lambda: "$" in _read(c, ws, surface, scrollback=False), timeout_s=5.0)
            send(MARKED_PROMPT_CMD + "\n")
            _wait_for(lambda: "clrscr$" in _read(c, ws, surface, scrollback=False), timeout_s=15.0)

            # Several screens of output, then a marker printed last.
            done = f"CMUX_CLRSCR_DONE_{int(time.time() * 1000)}"
            send(f"seq 1 {LINE_COUNT} | sed 's/^/{LINE_PREFIX}/'; echo {done}\n")
            _wait_for(lambda: has_exact_line(done), timeout_s=30.0)
            _wait_for(lambda: "clrscr$" in _read(c, ws, surface, scrollback=False), timeout_s=5.0)

            before_lines = {ln.strip() for ln in _read(c, ws, surface, scrollback=True).splitlines()}
            _must(f"{LINE_PREFIX}1" in before_lines, "expected the first output line in scrollback before Cmd+K")
            _must(f"{LINE_PREFIX}{LINE_COUNT}" in before_lines, "expected the last output line before Cmd+K")

            # Cmd+K is Ghostty's default clear_screen binding on macOS.
            c.simulate_shortcut("cmd+k")

            def cleared() -> bool:
                viewport = _read(c, ws, surface, scrollback=False)
                return done not in viewport and LINE_PREFIX not in viewport and "clrscr$" in viewport

            _wait_for(cleared, timeout_s=10.0)

            # The whole point: nothing survives in history either. Before the
            # fix the last screen (including the DONE marker) stayed behind.
            after = _read(c, ws, surface, scrollback=True)
            leaked = [ln for ln in after.splitlines() if LINE_PREFIX in ln or done in ln]
            _must(not leaked, f"Cmd+K left {len(leaked)} old line(s) in scrollback, e.g. {leaked[:3]!r}")
            _must("clrscr$" in after, f"prompt missing after Cmd+K: {after!r}")
            print("PASS: Cmd+K erased the screen and all scrollback")
            return 0
        finally:
            if ws:
                try:
                    c._call("workspace.close", {"workspace_id": ws})
                except cmuxError:
                    pass


if __name__ == "__main__":
    try:
        sys.exit(main())
    except cmuxError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
