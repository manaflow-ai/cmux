#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for package_notices.py (stdlib unittest; no network, cargo or zig)."""

from __future__ import annotations

import copy
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import package_notices as pn  # noqa: E402

CRATES = "<!-- notices-section: rust -->\n## Rust crates\n\n- **lib 1.0.0**: MIT.\n"


class ComposeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.inputs = pn.load_inputs()

    def test_linux_musl_notice_has_every_statically_linked_part(self) -> None:
        text = pn.compose("cmux-tui", "x86_64-unknown-linux-musl", CRATES, self.inputs)
        self.assertIn("musl libc 1.2.5", text)
        self.assertIn((pn.NOTICES / "texts/musl-1.2.5/COPYRIGHT").read_text(), text)
        self.assertIn("rustc 1.95.0", text)
        self.assertIn("COPYRIGHT-library.html", text)
        self.assertIn("Zig 0.16.0", text)
        self.assertIn("Copyright (c) Zig contributors", text)
        for name in ("highway", "wuffs", "uucode", "simdutf"):
            self.assertIn(name, text)
        self.assertIn("Mitchell Hashimoto", text)
        self.assertIn("- **lib 1.0.0**: MIT.", text)
        self.assertIn("bin/cmux-tui-hook", text)

    def test_darwin_notice_has_no_musl(self) -> None:
        text = pn.compose("cmux-tui", "aarch64-apple-darwin", CRATES, self.inputs)
        self.assertNotIn("musl libc", text)
        self.assertIn("rustc 1.95.0", text)

    def test_relay_notice_names_its_binaries(self) -> None:
        text = pn.compose("relay", "aarch64-unknown-linux-musl", CRATES, self.inputs)
        self.assertIn("bin/chatmux-relay", text)
        self.assertIn("musl libc 1.2.5", text)

    def test_compose_is_deterministic(self) -> None:
        a = pn.compose("cmux-tui", "x86_64-unknown-linux-musl", CRATES, self.inputs)
        b = pn.compose("cmux-tui", "x86_64-unknown-linux-musl", CRATES, pn.load_inputs())
        self.assertEqual(a, b)

    def test_windows_is_refused_until_mingw_w64_is_reviewed(self) -> None:
        with self.assertRaises(pn.NoticeError) as raised:
            pn.compose("cmux-tui", "x86_64-pc-windows-gnu", CRATES, self.inputs)
        self.assertIn("mingw-w64", str(raised.exception))

    def test_an_unknown_target_is_refused(self) -> None:
        with self.assertRaises(pn.NoticeError):
            pn.compose("cmux-tui", "riscv64gc-unknown-linux-gnu", CRATES, self.inputs)


class DataTest(unittest.TestCase):
    def test_shipped_data_is_consistent(self) -> None:
        self.assertEqual(pn.data_problems(pn.load_inputs()), [])

    def test_a_stored_text_must_match_its_sha256(self) -> None:
        inputs = pn.load_inputs()
        inputs.data = copy.deepcopy(inputs.data)
        inputs.data["musl"]["sha256"] = "0" * 64
        [problem] = pn.data_problems(inputs)
        self.assertIn("musl-1.2.5/COPYRIGHT", problem)

    def test_a_linked_package_without_texts_fails(self) -> None:
        inputs = pn.load_inputs()
        inputs.data = copy.deepcopy(inputs.data)
        del inputs.data["libghostty_vt"]["owners"]["N-V-__8AAP5JWgCGP_AD0teWpa4krRvE9VPZzvviGdbmN4jI"]
        problems = pn.data_problems(inputs)
        self.assertTrue(any("wuffs" in p or "N-V-__8AAP5JWgCGP" in p for p in problems), problems)

    def test_texts_for_another_ghostty_next_commit_fail(self) -> None:
        inputs = pn.load_inputs()
        inputs.graph = json.loads(json.dumps(inputs.graph))
        inputs.graph["commit"] = "c" * 40
        problems = pn.data_problems(inputs)
        self.assertTrue(any("c" * 40 in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
