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

    def test_windows_notice_has_the_reviewed_mingw_w64_and_gcc_runtime_texts(self) -> None:
        # The 2026-10-05 independent review of the real x86_64-pc-windows-gnu
        # link (package-notices.json windows_gnu.review): mingw-w64 13.0.0 CRT,
        # GCC 15.2.0 libgcc_eh/crtbegin, Zig compiler_rt (musl-derived math).
        text = pn.compose("cmux-tui", "x86_64-pc-windows-gnu", CRATES, self.inputs)
        self.assertIn("MinGW-w64 runtime licensing", text)
        self.assertIn("Copyright (c) 2009, 2010, 2011, 2012, 2013 by the mingw-w64 project", text)
        self.assertIn("This file has no copyright assigned and is placed in the Public Domain.", text)
        self.assertIn("GCC RUNTIME LIBRARY EXCEPTION", text)
        self.assertIn("Version 3.1, 31 March 2009", text)
        self.assertIn("musl as a whole is licensed under the following standard MIT license", text)
        self.assertIn("rustc 1.95.0", text)
        self.assertIn("Zig 0.16.0", text)
        for name in ("highway", "wuffs", "uucode", "simdutf"):
            self.assertIn(name, text)
        self.assertNotIn("musl libc 1.2.5", text)  # no musl libc on Windows, only musl-derived math
        self.assertIn("bin/cmux-tui-hook", text)

    def test_windows_relay_notice_names_its_binaries(self) -> None:
        text = pn.compose("relay", "x86_64-pc-windows-gnu", CRATES, self.inputs)
        self.assertIn("bin/chatmux-relay", text)
        self.assertIn("MinGW-w64 runtime licensing", text)

    def test_windows_is_a_generated_target(self) -> None:
        self.assertIn("x86_64-pc-windows-gnu", pn.TARGETS)

    def test_an_unknown_target_is_refused(self) -> None:
        with self.assertRaises(pn.NoticeError):
            pn.compose("cmux-tui", "riscv64gc-unknown-linux-gnu", CRATES, self.inputs)


class WindowsToolchainTest(unittest.TestCase):
    """The review covers one toolchain: the build job's linker and every GCC
    ident in a packaged binary must be that toolchain."""

    REVIEWED_GCC = "x86_64-w64-mingw32-gcc.exe (x86_64-posix-seh-rev1, Built by MinGW-Builds project) 15.2.0\nCopyright (C) 2025 Free Software Foundation, Inc.\n"
    REVIEWED_MACROS = "#define __MINGW64_VERSION_MAJOR 13\n#define __MINGW64_VERSION_MINOR 0\n#define __MINGW64_VERSION_BUGFIX 0\n#define _UCRT 1\n"

    def setUp(self) -> None:
        self.inputs = pn.load_inputs()

    def test_the_reviewed_toolchain_passes(self) -> None:
        self.assertEqual(pn.windows_toolchain_problems(self.REVIEWED_GCC, self.REVIEWED_MACROS, self.inputs), [])

    def test_another_gcc_build_fails(self) -> None:
        gcc = "x86_64-w64-mingw32-gcc.exe (Rev8, Built by MSYS2 project) 15.2.0\n"
        [problem] = pn.windows_toolchain_problems(gcc, self.REVIEWED_MACROS, self.inputs)
        self.assertIn("MSYS2", problem)

    def test_another_mingw_w64_runtime_fails(self) -> None:
        macros = self.REVIEWED_MACROS.replace("MAJOR 13", "MAJOR 14")
        [problem] = pn.windows_toolchain_problems(self.REVIEWED_GCC, macros, self.inputs)
        self.assertIn("14.0.0", problem)

    def test_an_msvcrt_runtime_fails(self) -> None:
        macros = self.REVIEWED_MACROS.replace("#define _UCRT 1\n", "")
        [problem] = pn.windows_toolchain_problems(self.REVIEWED_GCC, macros, self.inputs)
        self.assertIn("UCRT", problem)

    def test_binary_idents_must_be_the_reviewed_gcc(self) -> None:
        reviewed = b"GCC: (x86_64-posix-seh-rev1, Built by MinGW-Builds project) 15.2.0\x00"
        self.assertEqual(pn.windows_binary_problems(b"MZ" + reviewed * 3, self.inputs), [])
        self.assertEqual(pn.windows_binary_problems(b"MZ no C objects", self.inputs), [])
        [problem] = pn.windows_binary_problems(reviewed + b"GCC: (Rev8, Built by MSYS2 project) 15.2.0\x00", self.inputs)
        self.assertIn("MSYS2", problem)


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

    def test_a_windows_runtime_text_must_match_its_sha256(self) -> None:
        inputs = pn.load_inputs()
        inputs.data = copy.deepcopy(inputs.data)
        inputs.data["windows_gnu"]["files"][0]["sha256"] = "0" * 64
        [problem] = pn.data_problems(inputs)
        self.assertIn(inputs.data["windows_gnu"]["files"][0]["file"], problem)

    def test_texts_for_another_ghostty_next_commit_fail(self) -> None:
        inputs = pn.load_inputs()
        inputs.graph = json.loads(json.dumps(inputs.graph))
        inputs.graph["commit"] = "c" * 40
        problems = pn.data_problems(inputs)
        self.assertTrue(any("c" * 40 in p for p in problems), problems)


class PublishProvenanceTest(unittest.TestCase):
    """Coverage restored from 2345a8c6e78 (dropped with the Windows pending notice)."""

    def test_publish_workflows_take_packages_only_from_release_runs(self) -> None:
        # The release run's notices come from package_notices.py generate.
        workflows = HERE.parents[2] / ".github/workflows"
        for name in ("tui-publish-npm.yml", "tui-publish-pypi.yml"):
            text = (workflows / name).read_text()
            self.assertIn('artifact_path=".github/workflows/cmux-tui-release.yml"', text, name)

    def test_a_package_without_a_generated_notice_fails_the_contract(self) -> None:
        import tempfile

        import package_contract  # noqa: PLC0415

        with tempfile.TemporaryDirectory() as tmp:
            problem = package_contract._notice_problem(b"some notice\n", Path(tmp), "cmux-tui", "x86_64-pc-windows-gnu", "cmux-tui-win32-x64")
        self.assertIsNotNone(problem)
        self.assertIn("no generated notice", problem)


if __name__ == "__main__":
    unittest.main()
