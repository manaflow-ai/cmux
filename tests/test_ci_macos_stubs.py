#!/usr/bin/env python3
"""The tools that let the macOS cross build on Linux link without an Apple SDK.

scripts/ci/macos_stubs.py writes framework link stubs from the imports of our
own Mac-built binaries and checks that the committed stubs still cover them.
scripts/ci/macho_weaken.py restores the weak linkage of Zig's compiler_rt
definitions in a Mach-O object. These tests run the tools on canned llvm
output and on a hand-built Mach-O object.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import re
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stubs = load("macos_stubs", "scripts/ci/macos_stubs.py")
weaken = load("macho_weaken", "scripts/ci/macho_weaken.py")

CF = "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"
SEC = "/System/Library/Frameworks/Security.framework/Versions/A/Security"
DYLIBS = f"""bin:
\t{CF} (compatibility version 150.0.0, current version 5026.5.4)
\t{SEC} (compatibility version 1.0.0, current version 61901.120.67)
\t/usr/lib/libiconv.2.dylib (compatibility version 7.0.0, current version 7.0.0)
\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
"""
NM = """                 (undefined) external _CFRelease (from CoreFoundation)
                 (undefined) external _kCFAllocatorDefault (from CoreFoundation)
                 (undefined) external _SecTrustEvaluateWithError (from Security)
                 (undefined) weak external _OBJC_CLASS_$_NSObject (from CoreFoundation)
                 (undefined) external _write (from libSystem)
"""


class FakeTools:
    """Replace llvm-objdump and llvm-nm with canned output per binary."""

    def __init__(self, outputs: dict[str, tuple[str, str]]):
        self.outputs = outputs

    def __call__(self, tool: str, *args: str) -> str:
        dylibs, nm = self.outputs[args[-1]]
        return dylibs if tool.endswith("llvm-objdump") else nm


class StubTests(unittest.TestCase):
    def setUp(self) -> None:
        self.original_run = stubs._run
        stubs._run = FakeTools({"a": (DYLIBS, NM), "b": (DYLIBS, "                 (undefined) external _CFRetain (from CoreFoundation)\n")})
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        # The tool's own report lines: the cases that expect a refusal print "FAIL stubs: ...", which a CI log
        # reader took for this suite failing (2026-11-19). They are kept here and shown only when a test fails.
        self.tool_output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.tool_output)
        self.redirect.__enter__()

    def tearDown(self) -> None:
        self.redirect.__exit__(None, None, None)
        stubs._run = self.original_run
        self.tmp.cleanup()

    def run(self, result=None):
        result = super().run(result)
        if result is not None and any(test is self for test, _ in result.failures + result.errors):
            sys.stderr.write(f"{self.id()} tool output:\n{self.tool_output.getvalue()}")
        return result

    def test_imports_are_grouped_by_install_name_with_versions(self) -> None:
        libs = stubs.imports("a")
        self.assertEqual(libs[CF]["current"], "5026.5.4")
        self.assertEqual(libs[CF]["compat"], "150.0.0")
        self.assertEqual(libs[CF]["symbols"], {"_CFRelease", "_kCFAllocatorDefault", "_OBJC_CLASS_$_NSObject"})
        self.assertEqual(libs[SEC]["symbols"], {"_SecTrustEvaluateWithError"})
        self.assertEqual(libs["/usr/lib/libSystem.B.dylib"]["symbols"], {"_write"})

    def test_generate_writes_one_stub_per_framework_from_every_binary(self) -> None:
        self.assertEqual(stubs.cmd_generate(self.dir, ["a", "b"]), 0)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["CoreFoundation.tbd", "Security.tbd"])
        text = (self.dir / "CoreFoundation.tbd").read_text()
        self.assertIn(f"install-name:    '{CF}'", text)
        self.assertIn("current-version: 5026.5.4", text)
        self.assertIn("compatibility-version: 150.0.0", text)
        symbols = re.findall(r"'(_[^']*)'", text)
        self.assertEqual(symbols, ["_CFRelease", "_CFRetain", "_OBJC_CLASS_$_NSObject", "_kCFAllocatorDefault"])

    def test_check_names_a_stub_that_lost_an_import(self) -> None:
        stubs.cmd_generate(self.dir, ["a"])
        self.assertEqual(stubs.cmd_check(self.dir, ["a"]), 0)
        self.assertEqual(stubs.cmd_check(self.dir, ["a", "b"]), 1)
        (self.dir / "Security.tbd").unlink()
        self.assertEqual(stubs.cmd_check(self.dir, ["a"]), 1)

    def test_install_puts_framework_stubs_where_the_linker_looks(self) -> None:
        stubs.cmd_generate(self.dir, ["a"])
        sysroot = self.dir / "sysroot"
        stubs.cmd_install(self.dir, sysroot)
        installed = sysroot / "System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd"
        self.assertEqual(installed.read_text(), (self.dir / "CoreFoundation.tbd").read_text())
        self.assertTrue((sysroot / "System/Library/Frameworks/Security.framework/Security.tbd").exists())

    def test_tailnet_headers_and_link_stubs_are_installed_together(self) -> None:
        stubs.cmd_install(ROOT / "scripts/ci/macos-stubs", self.dir)
        for name in ["IOKit", "SystemConfiguration"]:
            self.assertTrue((self.dir / f"System/Library/Frameworks/{name}.framework/{name}.tbd").is_file())
        self.assertTrue((self.dir / "usr/lib/libresolv.tbd").is_file())
        self.assertTrue((self.dir / "usr/include/CoreFoundation/CoreFoundation.h").is_file())
        self.assertTrue((self.dir / "usr/include/IOKit/IOKitLib.h").is_file())
        self.assertTrue((self.dir / "usr/include/Security/Security.h").is_file())

    def test_a_libsystem_routine_bound_to_a_framework_needs_no_stub(self) -> None:
        # A Mac link with the macOS 15 SDK binds log2 to CoreServices (an
        # umbrella re-export); the Linux link binds it to libSystem, which
        # exports it too. The stub must not have to carry it.
        stubs.cmd_generate(self.dir, ["a"])
        stubs._run = FakeTools({"d": (DYLIBS, NM + "                 (undefined) external _log2 (from CoreFoundation)\n")})
        system = self.dir / "libSystem.tbd"
        system.write_text("--- !tapi-tbd\nexports:\n  - symbols: [ _log2, _write ]\n...\n")
        self.assertEqual(stubs.cmd_check(self.dir, ["d"]), 1)
        self.assertEqual(stubs.cmd_check(self.dir, ["d"], system), 0)

    def test_two_versions_of_one_framework_are_refused(self) -> None:
        stubs._run = FakeTools({"a": (DYLIBS, NM), "c": (DYLIBS.replace("5026.5.4", "4000.0.0"), NM)})
        with self.assertRaises(SystemExit):
            stubs.cmd_generate(self.dir, ["a", "c"])


def macho_object(symbols: list[tuple[int, int]]) -> bytearray:
    """A 64-bit Mach-O object with one LC_SYMTAB: (n_type, n_desc) per symbol."""
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 0x1, 1, 24, 0, 0)
    symoff = 32 + 24
    symtab_cmd = struct.pack("<6I", 0x2, 24, symoff, len(symbols), symoff + 16 * len(symbols), 1)
    table = b"".join(struct.pack("<IBBHQ", 0, n_type, 1, n_desc, 0) for n_type, n_desc in symbols)
    return bytearray(header + symtab_cmd + table + b"\0")


def descs(data: bytearray, count: int) -> list[int]:
    return [struct.unpack_from("<H", data, 56 + 16 * i + 6)[0] for i in range(count)]


class WeakenTests(unittest.TestCase):
    GLOBAL, LOCAL, UNDEFINED = 0x0F, 0x0E, 0x01  # N_SECT|N_EXT, N_SECT, N_UNDF|N_EXT

    def test_only_global_definitions_become_weak(self) -> None:
        data = macho_object([(self.GLOBAL, 0), (self.LOCAL, 0), (self.UNDEFINED, 0), (self.GLOBAL, 0x0080)])
        self.assertEqual(weaken.weaken(data), 1)
        self.assertEqual(descs(data, 4), [0x0080, 0, 0, 0x0080])
        self.assertEqual(weaken.weaken(data), 0)

    def test_a_linked_image_is_refused(self) -> None:
        data = macho_object([(self.GLOBAL, 0)])
        struct.pack_into("<I", data, 12, 0x2)  # MH_EXECUTE
        with self.assertRaises(SystemExit):
            weaken.weaken(data)


class CommittedStubs(unittest.TestCase):
    """The stubs under scripts/ci/macos-stubs as the Linux link reads them."""

    def test_every_version_fits_the_packed_mach_o_form(self) -> None:
        # A dylib version packs as X.Y.Z in 16.8.8 bits: ld64.lld refuses the whole stub
        # ("malformed file") when Y or Z is over 255, and every symbol in it goes undefined.
        for path in sorted((ROOT / "scripts/ci/macos-stubs").glob("*.tbd")):
            text = path.read_text()
            for key in ("current-version", "compatibility-version"):
                with self.subTest(stub=path.name, key=key):
                    value = re.search(rf"^{key}:\s*(\S+)$", text, re.M).group(1)
                    parts = [int(part) for part in value.split(".")]
                    self.assertLessEqual(len(parts), 3, value)
                    self.assertLessEqual(parts[0], 0xFFFF, value)
                    self.assertTrue(all(part <= 0xFF for part in parts[1:]), value)


# Imports a dependency in cmux-tui/Cargo.lock adds to the cross-linked daemons, as soon as any code calls into it.
# The stubs come from Mac-built binaries, so a call added later (acpmux ps's chrono::Local, #49166) fails the Linux
# link ("undefined symbol: CFTimeZoneCopySystem") before a regenerate; listing them here catches it in this test.
LOCKED_CRATE_IMPORTS = {
    # chrono's clock (Local) reads the system zone through iana-time-zone's CoreFoundation calls.
    "iana-time-zone": ("CoreFoundation", ("_CFTimeZoneCopySystem", "_CFTimeZoneGetName", "_CFTimeZoneResetSystem")),
}


class LockedCrateImportTests(unittest.TestCase):
    def test_a_locked_crate_that_calls_a_framework_has_its_imports_in_the_stub(self) -> None:
        lock = (ROOT / "cmux-tui" / "Cargo.lock").read_text()
        missing = []
        for crate, (framework, symbols) in LOCKED_CRATE_IMPORTS.items():
            if f'name = "{crate}"' not in lock:
                continue
            stub = (ROOT / "scripts" / "ci" / "macos-stubs" / f"{framework}.tbd").read_text()
            held = set(re.findall(r"'(_[A-Za-z0-9_$]+)'", stub))
            missing += [f"{framework}.tbd lacks {symbol} ({crate})" for symbol in symbols if symbol not in held]
        self.assertEqual(missing, [])


# cmux-tui's own `#[link(name = "X", kind = "framework")] extern` blocks: every name declared there must be in
# X.tbd when we stub X. The stubs come from older Mac-built binaries, so a new declaration (kSecGuestAttributePid in
# cmux-rd-host's webrtc_child.rs, #51585) failed every Linux cross link of cmux-tui from 2026-11-23 21:04Z
# ("ld64.lld: undefined symbol: kSecGuestAttributePid", cmux-tui artifacts run 45285325164), and each tree took
# the macOS fallback build instead: 2 h from landing to a published tree, the nightly waiting on it. A framework
# with no stub file is not ours to judge here (stubs-check reads what the Mac binaries link).
FRAMEWORK_EXTERN = re.compile(
    r'#\[link\(name\s*=\s*"([A-Za-z]+)",\s*kind\s*=\s*"framework"\)\]\s*(?:unsafe\s+)?extern\s+"C"\s*\{')
EXTERN_ITEM = re.compile(r"\b(?:static(?:\s+mut)?|fn)\s+([A-Za-z_][A-Za-z0-9_]*)")


def framework_externs(text: str) -> list[tuple[str, list[str]]]:
    out = []
    for match in FRAMEWORK_EXTERN.finditer(text):
        depth, end = 1, match.end()
        while depth and end < len(text):
            depth += {"{": 1, "}": -1}.get(text[end], 0)
            end += 1
        out.append((match.group(1), EXTERN_ITEM.findall(text[match.end():end - 1])))
    return out


class SourceExternTests(unittest.TestCase):
    def test_an_extern_block_names_one_framework_and_each_item(self) -> None:
        text = ('#[link(name = "Security", kind = "framework")]\nunsafe extern "C" {\n'
                "    static kSecGuestAttributePid: CFTypeRef;\n    fn SecCodeCopySelf(flags: u32) -> i32;\n}\n")
        self.assertEqual(framework_externs(text), [("Security", ["kSecGuestAttributePid", "SecCodeCopySelf"])])

    def test_every_framework_name_cmux_tui_declares_is_in_its_stub(self) -> None:
        stubs, missing = ROOT / "scripts" / "ci" / "macos-stubs", []
        for path in sorted((ROOT / "cmux-tui").glob("**/*.rs")):
            if "target" in path.relative_to(ROOT).parts:
                continue
            for framework, names in framework_externs(path.read_text(errors="replace")):
                stub = stubs / f"{framework}.tbd"
                if not stub.is_file():
                    continue
                held = set(re.findall(r"'(_[A-Za-z0-9_$]+)'", stub.read_text()))
                missing += [f"{path.relative_to(ROOT)}: {framework}.tbd lacks _{name}"
                            for name in names if f"_{name}" not in held]
        self.assertEqual(missing, [])


# A locked Apple binding crate (core-foundation-sys, security-framework-sys, system-configuration-sys) has every
# extern it declares in its framework's stub, so a first call into it links on the pool. #54956 (2026-11-27) made
# acpmux search the keychain through security-framework, which was locked since #37211 but never called there, and
# every Linux cross link of cmux-tui failed ("undefined symbol: kSecMatchSearchList", 20 names; run 46100844289),
# the macOS fallback build and the nightly behind it. sys-crates.txt lists the versions the stubs cover; a lock
# bump of one of these crates fails here until `macos_stubs.py sys-crates` adds the new version's externs.
LOCK_PATH = "cmux-tui/Cargo.lock"
SYS_CRATES_PATH = "scripts/ci/macos-stubs/sys-crates.txt"


class SysCrateCoverageTests(unittest.TestCase):
    def test_declared_externs_reads_every_extern_block(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp)
            (src / "item.rs").write_text('extern "C" {\n    pub static kSecMatchSearchList: CFStringRef;\n'
                                         '    pub fn SecItemCopyMatching(q: CFDictionaryRef) -> OSStatus;\n}\n'
                                         "fn not_extern() {}\n")
            self.assertEqual(stubs.declared_externs(src), {"_kSecMatchSearchList", "_SecItemCopyMatching"})

    def test_declared_externs_reads_objc2s_own_extern_macros(self) -> None:
        # objc2::ffi declares the runtime in extern_c! / extern_c_unwind!, not a bare `extern "C" {`.
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp)
            (src / "rc.rs").write_text("macro_rules! extern_c {\n    { $(pub fn $name:ident();)* } => {};\n}\n"
                                       "extern_c! {\n    #[cfg(target_vendor = \"apple\")]\n"
                                       "    pub fn objc_alloc(value: *const AnyClass) -> *mut AnyObject;\n}\n"
                                       "extern_c_unwind! {\n    /// fn some_external_function() in a doc\n"
                                       "    pub fn objc_msgSend(); // and the linker\n}\n")
            self.assertEqual(stubs.declared_externs(src), {"_objc_alloc", "_objc_msgSend"})

    def test_locked_versions_names_only_the_binding_crates(self) -> None:
        lock = ('[[package]]\nname = "security-framework-sys"\nversion = "2.17.0"\n\n'
                '[[package]]\nname = "security-framework"\nversion = "3.7.0"\n\n'
                '[[package]]\nname = "core-foundation-sys"\nversion = "0.8.7"\n')
        self.assertEqual(stubs.locked_versions(lock),
                         {"security-framework-sys": ["2.17.0"], "core-foundation-sys": ["0.8.7"]})

    def test_every_locked_binding_crate_version_is_in_the_stubs(self) -> None:
        covered = {tuple(line.split()[:2]) for line in (ROOT / SYS_CRATES_PATH).read_text().splitlines()
                   if line and not line.startswith("#")}
        locked = stubs.locked_versions((ROOT / LOCK_PATH).read_text())
        missing = [f"{name} {version}" for name, versions in sorted(locked.items()) for version in versions
                   if (name, version) not in covered]
        self.assertEqual(missing, [], "run: python3 scripts/ci/macos_stubs.py sys-crates scripts/ci/macos-stubs "
                                      "cmux-tui/Cargo.lock")

    def test_every_locked_objc2_crate_is_classified(self) -> None:
        # #56513 (iroh) locked objc2-core-wlan and objc2-security-foundation; their #[link(kind = "framework")]
        # had no stub, so every Linux link of the daemon failed "framework not found for -framework CoreWLAN".
        lock = (ROOT / LOCK_PATH).read_text()
        known = set(stubs.SYS_CRATES) | set(stubs.OBJC2_STUBBED_FROM_BINARIES) | stubs.OBJC2_NOT_IN_DAEMON_BUILD
        new = sorted({name for name, _ in stubs.LOCKED.findall(lock) if name.startswith("objc2")} - known)
        self.assertEqual(new, [], "a new objc2 binding crate links its framework: add it to SYS_CRATES (then run "
                                  "macos_stubs.py sys-crates) or to OBJC2_NOT_IN_DAEMON_BUILD in scripts/ci/macos_stubs.py")

    def test_every_sys_crate_framework_has_a_stub(self) -> None:
        for framework in set(stubs.SYS_CRATES.values()):
            install, _ = stubs.read_stub(ROOT / "scripts/ci/macos-stubs" / f"{framework}.tbd")
            # libobjc is a dylib, not a framework (objc2's runtime): its stub keeps /usr/lib/libobjc.A.dylib.
            self.assertIn("/usr/lib/libobjc.A.dylib" if framework == "libobjc" else f"/{framework}.framework/", install)

    def test_sys_crates_starts_a_stub_for_a_new_framework(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src = root / "src" / "objc2-core-wlan-9.9.9" / "src"
            src.mkdir(parents=True)
            (src / "lib.rs").write_text('extern "C" {\n    pub static CWErrorDomain: u8;\n}\n'
                                        'extern "C-unwind" {\n    pub fn CWKeychainDeleteWiFiPassword() -> i32;\n}\n')
            stub_dir = root / "stubs"
            stub_dir.mkdir()
            lock = root / "Cargo.lock"
            lock.write_text('[[package]]\nname = "objc2-core-wlan"\nversion = "9.9.9"\n')
            with mock.patch.dict(os.environ, {"SYS_CRATES_SRC": str(root / "src")}):
                with contextlib.redirect_stdout(io.StringIO()):
                    stubs.cmd_sys_crates(stub_dir, lock)
            install, held = stubs.read_stub(stub_dir / "CoreWLAN.tbd")
            self.assertEqual(install, "/System/Library/Frameworks/CoreWLAN.framework/Versions/A/CoreWLAN")
            self.assertEqual(held, {"_CWErrorDomain", "_CWKeychainDeleteWiFiPassword"})

    def test_the_stubs_hold_the_keychain_search_that_broke_the_link(self) -> None:
        held = stubs.read_stub(ROOT / "scripts/ci/macos-stubs/Security.tbd")[1]
        for name in ("_kSecMatchSearchList", "_SecKeychainItemDelete", "_kSecUseAuthenticationUISkip"):
            self.assertIn(name, held)

    def test_the_stubs_hold_the_objc_runtime_calls_that_broke_the_link(self) -> None:
        # 2026-11-28: every Linux link of cmux-tui failed "undefined symbol: objc_alloc" and 4 more (objc2).
        held = stubs.read_stub(ROOT / "scripts/ci/macos-stubs/libobjc.tbd")[1]
        for name in ("_objc_alloc", "_sel_getName", "_class_getName", "_class_isMetaClass", "_object_getClass"):
            self.assertIn(name, held)
        # A libSystem routine bound to libobjc would not resolve on a Mac: sys-crates drops what libSystem exports
        # (MACOS_STUBS_SYSTEM_TBD), and a comment's words are no symbols.
        for name in ("_free", "_dlopen", "_dlsym", "_sysctlbyname", "_pthread_main_np", "_and", "_linker"):
            self.assertNotIn(name, held)


# Every other locked crates.io package: lock-scan.txt records what each declares against an Apple framework, and
# the stubs hold those names. #54956's keychain search came through a crate the source-extern test above could not
# see; a crate outside SYS_CRATES that declares its own framework externs (a keychain, notification or IOKit
# binding) would fail the pool's link the same way at its first call.
LOCK_SCAN_PATH = "scripts/ci/macos-stubs/lock-scan.txt"
LOCK_SCAN_CMD = "python3 scripts/ci/macos_stubs.py lock-scan scripts/ci/macos-stubs cmux-tui/Cargo.lock"


class LockScanTests(unittest.TestCase):
    def test_a_framework_link_names_its_block_and_a_build_script_its_framework(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            crate = Path(tmp)
            (crate / "src").mkdir()
            (crate / "src" / "lib.rs").write_text(
                '#[cfg_attr(target_os = "macos", link(name = "IOKit", kind = "framework"))]\n#[allow(dead_code)]\n'
                'unsafe extern "C" {\n    pub fn IOServiceMatching(name: *const u8) -> *mut u8;\n'
                "    pub static kIOMasterPortDefault: u32;\n}\n"
                '#[link(name = "CoreFoundation", kind = "framework")]\nextern "C" {\n'
                "    fn CFTimeZoneCopySystem() -> *const u8;\n}\n"
                'extern "C" { fn not_a_framework(); }\n')
            (crate / "build.rs").write_text('fn main() { println!("cargo:rustc-link-lib=framework=CoreWLAN"); }\n')
            self.assertEqual(stubs.framework_declarations(crate), {
                "IOKit": {"_IOServiceMatching", "_kIOMasterPortDefault"},
                "CoreFoundation": {"_CFTimeZoneCopySystem"}, "CoreWLAN": set()})

    def test_lock_scan_skips_what_sys_crates_covers_and_non_registry_packages(self) -> None:
        lock = ('[[package]]\nname = "core-foundation-sys"\nversion = "0.8.7"\n'
                'source = "registry+https://github.com/rust-lang/crates.io-index"\n\n'
                '[[package]]\nname = "objc2-app-kit"\nversion = "0.3.2"\n'
                'source = "registry+https://github.com/rust-lang/crates.io-index"\n\n'
                '[[package]]\nname = "cmux-tui"\nversion = "0.1.0"\n\n'
                '[[package]]\nname = "iana-time-zone"\nversion = "0.1.63"\n'
                'source = "registry+https://github.com/rust-lang/crates.io-index"\n')
        self.assertEqual(stubs.lock_scan_packages(lock), [("iana-time-zone", "0.1.63")])

    def test_lock_scan_records_each_crate_and_fills_the_stub(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for leaf, body in (("keys-1.0.0", '#[link(name = "Security", kind = "framework")]\nextern "C" {\n'
                                              "    pub fn SecKeychainItemDelete(item: *mut u8) -> i32;\n}\n"),
                               ("plain-2.0.0", "pub fn nothing() {}\n")):
                (root / "src" / leaf / "src").mkdir(parents=True)
                (root / "src" / leaf / "src" / "lib.rs").write_text(body)
            stub_dir = root / "stubs"
            stub_dir.mkdir()
            lock = root / "Cargo.lock"
            lock.write_text("".join(f'[[package]]\nname = "{n}"\nversion = "{v}"\n'
                                    'source = "registry+https://github.com/rust-lang/crates.io-index"\n\n'
                                    for n, v in (("keys", "1.0.0"), ("plain", "2.0.0"))))
            with mock.patch.dict(os.environ, {"SYS_CRATES_SRC": str(root / "src")}):
                with contextlib.redirect_stdout(io.StringIO()):
                    stubs.cmd_lock_scan(stub_dir, lock)
            self.assertEqual(stubs.read_lock_scan(stub_dir / "lock-scan.txt"),
                             {("keys", "1.0.0"): {"Security": {"_SecKeychainItemDelete"}}, ("plain", "2.0.0"): {}})
            install, held = stubs.read_stub(stub_dir / "Security.tbd")
            self.assertEqual(install, "/System/Library/Frameworks/Security.framework/Versions/A/Security")
            self.assertEqual(held, {"_SecKeychainItemDelete"})

    def test_every_recorded_framework_name_is_in_its_stub(self) -> None:
        stub_dir, missing = ROOT / "scripts/ci/macos-stubs", []
        for (name, version), declared in sorted(stubs.read_lock_scan(ROOT / LOCK_SCAN_PATH).items()):
            for framework, names in sorted(declared.items()):
                path = stub_dir / f"{framework}.tbd"
                if not path.exists():
                    missing.append(f"{name} {version}: no {framework}.tbd")
                    continue
                lacks = sorted(names - stubs.read_stub(path)[1])
                if lacks:
                    missing.append(f"{name} {version}: {framework}.tbd lacks {', '.join(lacks[:8])}")
        self.assertEqual(missing, [], f"run: {LOCK_SCAN_CMD}")

    def test_every_locked_package_is_scanned(self) -> None:
        # A package lock-scan.txt lacks is read here (cargo's registry, else crates.io): one that declares no
        # framework passes, so a lock bump costs nothing; one that declares a framework fails until lock-scan
        # records it and its names are in the stub.
        record = stubs.read_lock_scan(ROOT / LOCK_SCAN_PATH)
        unread = [p for p in stubs.lock_scan_packages((ROOT / LOCK_PATH).read_text()) if p not in record]
        if not unread:
            return
        try:
            with tempfile.TemporaryDirectory() as tmp:
                found = stubs.scan_packages(unread, Path(tmp))
        except OSError as error:
            self.fail(f"{len(unread)} locked packages are not in {LOCK_SCAN_PATH} and could not be read "
                      f"({error}); run: {LOCK_SCAN_CMD}")
        declaring = [f"{n} {v}: {', '.join(sorted(found[(n, v)]))}" for n, v in unread if found[(n, v)]]
        self.assertEqual(declaring, [], f"these locked packages link Apple frameworks; run: {LOCK_SCAN_CMD}")


class MergeStubs(unittest.TestCase):
    def test_merge_adds_the_newer_symbols_and_stubs(self) -> None:
        with tempfile.TemporaryDirectory() as old_dir, tempfile.TemporaryDirectory() as new_dir:
            old, new = Path(old_dir), Path(new_dir)
            lib = {"current": "61901.120.67", "compat": "1.0.0"}
            (old / "Security.tbd").write_text(stubs.render(SEC, {**lib, "symbols": {"_SecA"}}))
            (new / "Security.tbd").write_text(stubs.render(SEC, {**lib, "symbols": {"_SecA", "_kSecGuestAttributePid"}}))
            (new / "IOKit.tbd").write_text(stubs.render("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", {**lib, "symbols": {"_IOA"}}))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(stubs.cmd_merge(old, new), 0)
            self.assertEqual(stubs.read_stub(old / "Security.tbd")[1], {"_SecA", "_kSecGuestAttributePid"})
            self.assertEqual(stubs.read_stub(old / "IOKit.tbd")[1], {"_IOA"})


if __name__ == "__main__":
    unittest.main()
