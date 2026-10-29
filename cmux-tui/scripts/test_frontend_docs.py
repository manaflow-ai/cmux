#!/usr/bin/env python3
"""Keep frontend README protocol claims aligned with the supported wire API."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


TUI = Path(__file__).resolve().parents[1]
README_PATHS = (
    TUI / "frontends" / "README.md",
    TUI / "frontends" / "README.ja.md",
    TUI / "frontends" / "web" / "README.md",
    TUI / "frontends" / "web" / "README.ja.md",
)


def supported_protocol() -> int:
    source = (TUI / "frontends" / "web" / "src" / "lib" / "protocol.ts").read_text(
        encoding="utf-8"
    )
    match = re.search(r"SUPPORTED_PROTOCOL\s*=\s*(\d+)", source)
    if match is None:
        raise AssertionError("web frontend has no supported protocol constant")
    return int(match.group(1))


def documented_protocol() -> int:
    source = (TUI / "docs" / "protocol.md").read_text(encoding="utf-8")
    match = re.search(r"^# Raw control protocol v(\d+)\s*$", source, re.MULTILINE)
    if match is None:
        raise AssertionError("raw protocol guide has no version heading")
    return int(match.group(1))


class FrontendReadmeProtocolTests(unittest.TestCase):
    def test_readmes_match_the_supported_websocket_protocol(self) -> None:
        expected = supported_protocol()
        self.assertEqual(expected, documented_protocol())

        for path in README_PATHS:
            text = path.read_text(encoding="utf-8")
            websocket_lines = [
                line for line in text.splitlines() if "websocket" in line.lower()
            ]
            self.assertTrue(websocket_lines, path)
            versions = {
                int(version)
                for line in websocket_lines
                for version in re.findall(
                    r"(?:protocol|プロトコル)[-\s]?v?(\d+)",
                    line,
                    re.IGNORECASE,
                )
            }
            self.assertEqual(versions, {expected}, path)


if __name__ == "__main__":
    unittest.main()
