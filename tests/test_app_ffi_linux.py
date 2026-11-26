#!/usr/bin/env python3
"""CmuxNext's Linux shape links CCmuxAppFFI as a system library (scripts/ci/app_ffi_linux.py).

  - the module map `app_ffi_linux.py build` writes (LinuxAppFFI/module.modulemap, gitignored) holds
    CCmuxAppFFI and one module per entry of scripts/cmux-next/build-app-ffi.sh's headers_in, the names
    the xcframework gives them, so a header added to the xcframework is importable on Linux too;
  - every header it names exists, and every module links libcmux_app_ffi.a;
  - Package.swift's Linux shape declares that system library, and the lane script builds
    the library before a CmuxNext suite on Linux, and SwiftPM purges keep it;
  - with no `cc` (the swift container), clang compiles and links the crates.
"""

from __future__ import annotations

import importlib.util
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/app_ffi_linux.py"
spec = importlib.util.spec_from_file_location("app_ffi_linux", SCRIPT)
app_ffi_linux = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(app_ffi_linux)


class AppFFILinuxTests(unittest.TestCase):
    def test_the_module_map_is_build_output(self) -> None:
        ignore = (app_ffi_linux.MODULEMAP.parent / ".gitignore").read_text(encoding="utf-8")
        self.assertIn(app_ffi_linux.MODULEMAP.name, ignore.split())

    def test_every_xcframework_module_and_header(self) -> None:
        text = app_ffi_linux.render()
        modules = re.findall(r"^module (\w+) \{", text, re.M)
        entries = app_ffi_linux.headers_in()
        self.assertEqual(modules, ["CCmuxAppFFI", *[module for _, module in entries]])
        for header in re.findall(r'header "([^"]+)"', text):
            self.assertTrue((app_ffi_linux.MODULEMAP.parent / header).resolve().is_file(), header)
        self.assertEqual(text.count('link "cmux_app_ffi"'), len(modules))

    def test_linux_shape_and_lane_script(self) -> None:
        manifest = (ROOT / "Packages/macOS/CmuxNext/Package.swift").read_text(encoding="utf-8")
        self.assertIn('.systemLibrary(name: "CCmuxAppFFILinux", path: "LinuxAppFFI")', manifest)
        self.assertIn('let appFFIDependency: [Target.Dependency] = targetsLinux ? ["CCmuxAppFFILinux"] : ["CCmuxAppFFI"]', manifest)
        lane = (ROOT / "scripts/ci/package-test-lane.sh").read_text(encoding="utf-8")
        self.assertIn("python3 scripts/ci/app_ffi_linux.py build", lane)
        # The lane builds the library into .build before SwiftPM's purges (a resolve retry, a header
        # change, an unfinished build): they keep it, or the link that follows finds no library.
        guard = (ROOT / "scripts/ci/swiftpm-binary-module-guard.sh").read_text(encoding="utf-8")
        purge = guard.split("\nswiftpm_purge_build_outputs() {\n", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("|app-ffi-linux)", purge)

    def test_clang_stands_in_for_a_missing_cc(self) -> None:
        import shutil
        from unittest import mock

        found = {"clang": "/usr/bin/clang"}
        with mock.patch.object(shutil, "which", lambda name, path=None: found.get(name)):
            env: dict[str, str] = {"PATH": "/usr/bin"}
            app_ffi_linux.c_toolchain(env)
        self.assertEqual(env["CC"], "clang")
        self.assertEqual(env["CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER"], "clang")
        found["cc"] = "/usr/bin/cc"
        with mock.patch.object(shutil, "which", lambda name, path=None: found.get(name)):
            env = {"PATH": "/usr/bin"}
            app_ffi_linux.c_toolchain(env)
        self.assertNotIn("CC", env)


if __name__ == "__main__":
    sys.exit(unittest.main())
