#!/usr/bin/env python3
"""
Regression test: dropping files into terminal inserts shell-escaped paths.
"""

import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux


SHELL_ESCAPE_CHARS = "\\ ()[]{}<>\"'`!#$&;|*?\t"


def escape_for_shell(value: str) -> str:
    out = value
    for ch in SHELL_ESCAPE_CHARS:
        out = out.replace(ch, f"\\{ch}")
    return out


def wait_for_text(client: cmux, surface_id: str, needle: str, timeout: float = 3.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = client.read_terminal_text(surface_id)
        if needle in text:
            return True
        time.sleep(0.1)
    return False


def main() -> int:
    tmp = Path(tempfile.gettempdir())
    p1 = (tmp / "cmux drop [image] #1 (a).png").resolve()
    p2 = (tmp / "cmux drop second & file!.jpg").resolve()
    p1.write_text("x", encoding="utf-8")
    p2.write_text("y", encoding="utf-8")

    try:
        with cmux() as client:
            try:
                client.activate_app()
            except Exception:
                pass

            surface_id = client.new_surface(panel_type="terminal")
            client.focus_surface(surface_id)
            client.simulate_file_drop(surface_id, [str(p1), str(p2)])

            expected = f"{escape_for_shell(str(p1))} {escape_for_shell(str(p2))}"
            if not wait_for_text(client, surface_id, expected):
                text = client.read_terminal_text(surface_id)
                print("FAIL: expected dropped paths not found in terminal text")
                print(f"expected substring: {expected}")
                print("terminal tail:")
                print(text[-800:])
                return 1

            print("PASS: dropped file paths inserted as escaped paths")
            return 0
    finally:
        p1.unlink(missing_ok=True)
        p2.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
