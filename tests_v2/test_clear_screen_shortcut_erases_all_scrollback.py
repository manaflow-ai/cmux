#!/usr/bin/env python3
"""Regression tests for the Cmd+K ``clear_screen`` action.

The primary screen test protects the Ghostty history-ordering fix.  The
alternate-screen test protects cmux's safety fallback: Ghostty intentionally
does not erase an alternate-screen program's buffer, so cmux sends the same
Ctrl-L input as the user-facing "keep scrollback" action.

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
ALT_LINE_PREFIX = "CMUX_CLRSCR_ALT_LINE_"
ALT_LINE_COUNT = 24
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


def _has_exact_line(c: cmux, ws: str, surface: str, needle: str, *, scrollback: bool = False) -> bool:
    # Exact-line match so a command echo containing the marker does not count.
    return needle in {ln.strip() for ln in _read(c, ws, surface, scrollback=scrollback).splitlines()}


def _enter_alternate_screen(c: cmux, ws: str, surface: str, token: str) -> None:
    # The shell remains the foreground process while this command emits a real
    # DEC private-mode alternate-screen sequence.  This models a TUI without
    # making the test depend on an installed third-party program.
    enter = "1b5b3f31303439681b5b324a1b5b48"
    command = (
        "python3 -c 'import sys;sys.stdout.buffer.write(bytes.fromhex(\""
        + enter
        + "\"));print(\""
        + token
        + "\");[print(\""
        + ALT_LINE_PREFIX
        + "\"+str(i)) for i in range("
        + str(ALT_LINE_COUNT)
        + ")]'\n"
    )
    c._call(
        "surface.send_text",
        {"workspace_id": ws, "surface_id": surface, "text": command},
    )
    _wait_for(lambda: _has_exact_line(c, ws, surface, token), timeout_s=10.0)


def _leave_alternate_screen(c: cmux, ws: str, surface: str) -> None:
    # Leave the synthetic alternate buffer so cleanup never leaks it into a
    # later test or a restored workspace.
    leave = "1b5b3f313034396c"
    command = (
        "python3 -c 'import sys;sys.stdout.buffer.write(bytes.fromhex(\""
        + leave
        + "\"))'\n"
    )
    c._call(
        "surface.send_text",
        {"workspace_id": ws, "surface_id": surface, "text": command},
    )


def _run_primary_case(c: cmux, ws: str, surface: str) -> None:
    def send(text: str) -> None:
        c._call("surface.send_text", {"workspace_id": ws, "surface_id": surface, "text": text})

    # Wait for the shell to actually execute commands. Typeahead sent before
    # zsh finishes starting is discarded, so resend until the marker is shown.
    ready = f"CMUX_CLRSCR_READY_{int(time.time() * 1000)}"
    deadline = time.time() + 60.0
    while True:
        send(f"echo {ready}\n")
        try:
            _wait_for(lambda: _has_exact_line(c, ws, surface, ready), timeout_s=3.0)
            break
        except cmuxError:
            _must(time.time() < deadline, "shell never became ready")

    # Install a prompt with OSC 133 marks.
    send("exec /bin/bash --noprofile --norc\n")
    _wait_for(lambda: "$" in _read(c, ws, surface, scrollback=False), timeout_s=5.0)
    send(MARKED_PROMPT_CMD + "\n")
    _wait_for(lambda: "clrscr$" in _read(c, ws, surface, scrollback=False), timeout_s=15.0)

    # Several screens of output, then a marker printed last.
    done = f"CMUX_CLRSCR_DONE_{int(time.time() * 1000)}"
    send(f"seq 1 {LINE_COUNT} | sed 's/^/{LINE_PREFIX}/'; echo {done}\n")
    _wait_for(lambda: _has_exact_line(c, ws, surface, done), timeout_s=30.0)
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

    # The whole point: nothing survives in history either. Before the fix the
    # last screen (including the DONE marker) stayed behind.
    after = _read(c, ws, surface, scrollback=True)
    leaked = [ln for ln in after.splitlines() if LINE_PREFIX in ln or done in ln]
    _must(not leaked, f"Cmd+K left {len(leaked)} old line(s) in scrollback, e.g. {leaked[:3]!r}")
    _must("clrscr$" in after, f"prompt missing after Cmd+K: {after!r}")


def _run_alternate_case(c: cmux, ws: str, surface: str) -> None:
    # Exercise the shared socket action first. On the old implementation this
    # calls Ghostty clear_screen, which deliberately does nothing on alt-screen.
    token = f"{ALT_LINE_PREFIX}SOCKET_{int(time.time() * 1000)}"
    _enter_alternate_screen(c, ws, surface, token)
    c._call("surface.clear_history", {"workspace_id": ws, "surface_id": surface})
    _wait_for(
        lambda: token not in _read(c, ws, surface, scrollback=False),
        timeout_s=10.0,
    )
    _must(
        ALT_LINE_PREFIX not in _read(c, ws, surface, scrollback=False),
        "surface.clear_history left alternate-screen output visible",
    )
    _leave_alternate_screen(c, ws, surface)

    # Re-enter and exercise the AppKit shortcut route through the debug socket.
    # This catches a fix that only changes the socket action while AppKit still
    # sends Cmd+K to Ghostty. Physical key input is covered by fleet dogfood.
    token = f"{ALT_LINE_PREFIX}SHORTCUT_{int(time.time() * 1000)}"
    _enter_alternate_screen(c, ws, surface, token)
    c.simulate_shortcut("cmd+k")
    _wait_for(
        lambda: token not in _read(c, ws, surface, scrollback=False),
        timeout_s=10.0,
    )
    _must(
        ALT_LINE_PREFIX not in _read(c, ws, surface, scrollback=False),
        "Cmd+K left alternate-screen output visible",
    )
    _leave_alternate_screen(c, ws, surface)


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
            _run_primary_case(c, ws, surface)
            _run_alternate_case(c, ws, surface)
            print("PASS: Cmd+K erased primary scrollback and safely redrew alternate screen")
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
