#!/usr/bin/env python3

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def function_body(source: str, signature: str, next_signature: str) -> str:
    start = source.index(signature)
    end = source.index(next_signature, start)
    return source[start:end]


class GhosttyFocusCallbackContractTests(unittest.TestCase):
    def test_ui_focus_callback_never_waits_for_terminal_state(self) -> None:
        surface_source = (ROOT / "ghostty/src/Surface.zig").read_text()
        focus_callback = function_body(
            surface_source,
            "pub fn focusCallback(self: *Surface, focused: bool) !void {",
            "pub fn refreshCallback(self: *Surface) !void {",
        )

        self.assertNotIn("renderer_state.mutex", focus_callback)
        self.assertIn(
            "self.queueIo(.{ .focused = focused }, .unlocked);",
            focus_callback,
        )

    def test_io_handler_owns_terminal_focus_state(self) -> None:
        termio_source = (ROOT / "ghostty/src/termio/Termio.zig").read_text()
        focus_handler = function_body(
            termio_source,
            "pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {",
            "pub fn processOutput(self: *Termio, buf: []const u8) void {",
        )

        self.assertIn("self.terminal.flags.focused = focused;", focus_handler)
        self.assertIn("renderer_state.mutex.lockUncancelable", focus_handler)


if __name__ == "__main__":
    unittest.main()
