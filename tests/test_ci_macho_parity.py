#!/usr/bin/env python3
"""The Mach-O parity verdict for the Linux-built (shadow) macOS artifacts.

The macOS cross-compile shadow job builds the same binaries on Linux and
compares each with the Mac-built one. These tests pin which differences fail
the comparison and which are accepted as linker/compiler-vendor noise.
"""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("macho_parity", ROOT / "scripts/ci/macho_parity.py")
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)


def info(**overrides):
    base = {
        "bytes": 1000,
        "text_bytes": 600,
        "archs": ["arm64"],
        "build_version": ["platform=macos minos=11.0 sdk=15.5"],
        "load_commands": ["LC_BUILD_VERSION", "LC_CODE_SIGNATURE", "LC_LOAD_DYLIB", "LC_MAIN",
                          "LC_SOURCE_VERSION", "LC_UUID"],
        "dylibs": ["/usr/lib/libSystem.B.dylib", "/usr/lib/libiconv.2.dylib"],
        "undefined": ["___chkstk_darwin", "_malloc", "_write"],
        "exported": ["__mh_execute_header", "_main"],
    }
    base.update(overrides)
    return base


class VerdictTests(unittest.TestCase):
    def verdict(self, mac, linux):
        return parity.evaluate("x", mac, linux)

    def test_identical_artifacts_pass(self):
        self.assertTrue(self.verdict(info(), info())["pass"])

    def test_missing_source_version_and_other_uuid_are_accepted(self):
        linux = info(load_commands=["LC_BUILD_VERSION", "LC_CODE_SIGNATURE", "LC_LOAD_DYLIB", "LC_MAIN", "LC_UUID"])
        self.assertTrue(self.verdict(info(), linux)["pass"])

    def test_stack_probe_import_only_on_mac_is_accepted(self):
        linux = info(undefined=["_malloc", "_write"])
        self.assertTrue(self.verdict(info(), linux)["pass"])

    def test_new_import_on_linux_fails(self):
        linux = info(undefined=["___chkstk_darwin", "_malloc", "_strstr", "_write"])
        result = self.verdict(info(), linux)
        self.assertFalse(result["pass"])
        self.assertFalse(result["checks"]["undefined_symbols"])

    def test_extra_dylib_fails(self):
        linux = info(dylibs=["/usr/lib/libSystem.B.dylib", "/usr/lib/libcharset.1.dylib", "/usr/lib/libiconv.2.dylib"])
        self.assertFalse(self.verdict(info(), linux)["checks"]["dylibs"])

    def test_deployment_target_mismatch_fails_but_sdk_version_does_not(self):
        self.assertFalse(self.verdict(info(), info(build_version=["platform=macos minos=13.0 sdk=15.5"]))["pass"])
        self.assertTrue(self.verdict(info(), info(build_version=["platform=macos minos=11.0 sdk=26.4"]))["pass"])

    def test_old_version_min_command_must_match(self):
        mac = info(build_version=["LC_VERSION_MIN_MACOSX 10.12"],
                   load_commands=["LC_CODE_SIGNATURE", "LC_LOAD_DYLIB", "LC_MAIN", "LC_VERSION_MIN_MACOSX"])
        linux = info(build_version=["platform=macos minos=10.12 sdk=15.5"],
                     load_commands=["LC_BUILD_VERSION", "LC_CODE_SIGNATURE", "LC_LOAD_DYLIB", "LC_MAIN"])
        self.assertFalse(self.verdict(mac, linux)["pass"])

    def test_arm64_executable_without_signature_fails(self):
        linux = info(load_commands=["LC_BUILD_VERSION", "LC_LOAD_DYLIB", "LC_MAIN", "LC_UUID"])
        self.assertFalse(self.verdict(info(), linux)["checks"]["code_signature_if_arm64_exe"])

    def test_rust_symbol_hash_is_ignored(self):
        self.assertEqual(parity.normalize_symbol("__ZN4core3fmt5write17h0123456789abcdefE"),
                         "__ZN4core3fmt5writeE")
        self.assertEqual(parity.normalize_symbol("_ghostty_terminal_new"), "_ghostty_terminal_new")


if __name__ == "__main__":
    unittest.main()
