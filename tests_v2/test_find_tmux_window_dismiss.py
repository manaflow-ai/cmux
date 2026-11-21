#!/usr/bin/env python3
"""
Regression test: closing Find tmux Window gives focus back to terminals.

Find tmux Window shows in the command palette overlay. Closing it must clear the
window's "command palette visible" flag, or every terminal focus is refused
afterwards and typing goes nowhere.

Covers:
- Command palette -> "Find tmux Window…" -> type a query -> Escape.
- Ctrl+Cmd+Shift+F -> Escape.
- Ctrl+Cmd+Shift+F -> Enter on a window, which jumps and closes the panel.

Needs a mirrored tmux workspace (`cmux ssh-tmux <host>`) so that Find tmux Window
is offered at all.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
FIND_COMMAND_ID = "palette.findTmuxWindow"


def _wait_until(predicate, timeout_s: float = 5.0, interval_s: float = 0.05, message: str = "timeout") -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def _palette_visible(client: cmux, window_id: str) -> bool:
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def _set_palette_visible(client: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        timeout_s=3.0,
        message=f"palette visibility did not become {visible}",
    )


def _snapshot(client: cmux, window_id: str) -> dict:
    return client.command_palette_results(window_id=window_id, limit=20) or {}


def _top_command_id(client: cmux, window_id: str) -> str:
    rows = _snapshot(client, window_id).get("results") or []
    return str((rows[0] or {}).get("command_id") or "") if rows else ""


def _palette_field_focused(client: cmux, window_id: str) -> bool:
    payload = client._call("debug.command_palette.rename_input.selection", {"window_id": window_id}) or {}
    return bool(payload.get("focused"))


def _wait_for_find_window(client: cmux, window_id: str, step: str) -> None:
    """Waits until find-window, not the palette, is the overlay showing and its field has focus."""
    _wait_until(
        lambda: _palette_visible(client, window_id)
        and _snapshot(client, window_id).get("mode") == "find_tmux_window"
        and _palette_field_focused(client, window_id),
        message=f"{step}: Find tmux Window is not the overlay showing",
    )


def _local_terminal(client: cmux, window_id: str) -> tuple[str, str]:
    workspace = client.new_workspace(window_id=window_id)
    client.select_workspace(workspace)
    _wait_until(lambda: client.current_workspace() == workspace, message="new workspace was not selected")
    surfaces = client.list_surfaces(workspace)
    if not surfaces:
        raise cmuxError("new workspace has no terminal surface")
    return workspace, str(surfaces[0][1])


def _assert_terminal_takes_focus(client: cmux, window_id: str, surface: str, step: str) -> None:
    _wait_until(
        lambda: not _palette_visible(client, window_id),
        timeout_s=3.0,
        message=f"{step}: the window still reports the command palette as visible",
    )
    client.focus_surface(surface)
    _wait_until(
        lambda: client.is_terminal_focused(surface),
        timeout_s=3.0,
        message=f"{step}: the terminal could not take focus",
    )


def _open_find_window_from_palette(client: cmux, window_id: str) -> None:
    client.simulate_shortcut("cmd+shift+p")
    _wait_until(
        lambda: _palette_visible(client, window_id)
        and _snapshot(client, window_id).get("mode") == "commands"
        and _palette_field_focused(client, window_id),
        message="cmd+shift+p did not open the palette with its field focused",
    )
    client.simulate_type("find tmux window")
    _wait_until(
        lambda: _top_command_id(client, window_id) == FIND_COMMAND_ID,
        message="Find tmux Window is not offered; attach a tmux host with `cmux ssh-tmux` first",
    )
    client.simulate_shortcut("enter")


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        window_id = client.current_window()
        client.focus_window(window_id)
        client.activate_app()
        _set_palette_visible(client, window_id, False)

        workspace, terminal = _local_terminal(client, window_id)
        client.focus_surface(terminal)
        _wait_until(lambda: client.is_terminal_focused(terminal), message="the terminal never took focus")

        # Palette -> Find tmux Window -> query -> Escape.
        _open_find_window_from_palette(client, window_id)
        _wait_for_find_window(client, window_id, "palette")
        client.simulate_type("no-such-text")
        _wait_until(
            lambda: _snapshot(client, window_id).get("query") == "no-such-text",
            message="palette: the query never reached Find tmux Window",
        )
        client.simulate_shortcut("escape")
        _assert_terminal_takes_focus(client, window_id, terminal, "palette then Escape")

        # Ctrl+Cmd+Shift+F -> Escape.
        client.simulate_shortcut("ctrl+cmd+shift+f")
        _wait_for_find_window(client, window_id, "shortcut")
        client.simulate_shortcut("escape")
        _assert_terminal_takes_focus(client, window_id, terminal, "shortcut then Escape")

        # Ctrl+Cmd+Shift+F -> Enter jumps to the first listed window and closes the panel.
        client.simulate_shortcut("ctrl+cmd+shift+f")
        _wait_for_find_window(client, window_id, "jump")
        # With no query the panel lists every window; Enter needs one to jump to.
        _wait_until(
            lambda: bool(_snapshot(client, window_id).get("results")),
            message="jump: Find tmux Window listed no windows",
        )
        client.simulate_shortcut("enter")
        _wait_until(
            lambda: not _palette_visible(client, window_id),
            timeout_s=3.0,
            message="jump: the window still reports the command palette as visible",
        )
        client.select_workspace(workspace)
        _wait_until(lambda: client.current_workspace() == workspace, message="jump: could not return to the terminal")
        _assert_terminal_takes_focus(client, window_id, terminal, "jump")

    print("PASS: closing Find tmux Window by Escape or by a jump lets terminals take focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
