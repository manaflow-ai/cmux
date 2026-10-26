#!/usr/bin/env python3
"""pgo/check.py (p08-startup-053): the link map, order file and Mach-O parses, profile name to symbol mapping, and
each check over fixtures written here (order coverage at and under 90 %, the order header's profdata sha256, a link
map of another binary, the launch window of 64 pages, the hash mismatch rate at and over 20 %), the exit codes and
the PGO-CHECK line. Profiles go through a fake llvm-profdata, and once through the real one over the text-format
fixtures in fixtures/pgo (skipped when none is installed). Runs on any OS:
python3 -I scripts/cmux-next/tests/test_pgo_check.py"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import shutil
import struct
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures", "pgo")
SCRIPT = os.path.join(os.path.dirname(HERE), "pgo", "check.py")
SCENARIOS_TESTS = os.path.join(HERE, "test_pgo_scenarios.py")

spec = importlib.util.spec_from_file_location("pgo_check", SCRIPT)
pc = importlib.util.module_from_spec(spec)
sys.modules["pgo_check"] = pc
spec.loader.exec_module(pc)

TEXT_START = 0x100004000  # page aligned for 16 KiB pages
PAGE = 0x4000
WINDOW_END = TEXT_START + 64 * PAGE
ARM64, X86_64 = 0x0100000C, 0x01000007


def link_map(symbols, sections=None, dead=(), arch="arm64"):
    """A link map in ld's format: `symbols` is [(address, name)]."""
    sections = sections or [(TEXT_START, 0x200000, "__TEXT", "__text"), (TEXT_START + 0x200000, 0x100, "__TEXT",
                                                                         "__stubs")]
    lines = ["# Path: /build/cmux", f"# Arch: {arch}", "# Object files:", "[  0] linker synthesized",
             "[  1] /build/App.o", "# Sections:", "# Address\tSize    \tSegment\tSection"]
    lines += [f"0x{a:08X}\t0x{s:08X}\t{seg}\t{sect}" for a, s, seg, sect in sections]
    lines += ["", "# Symbols:", "# Address\tSize    \tFile  Name"]
    lines += [f"0x{a:08X}\t0x00000010\t[  1] {name}" for a, name in symbols]
    lines += ["", "# Dead Stripped Symbols:", "#        \tSize    \tFile  Name"]
    lines += [f"<<dead>> \t0x00000018\t[  1] {name}" for name in dead]
    return "\n".join(lines) + "\n"


def order_file(symbols, sha=None):
    head = ["# The cmux-next Release link order."] + ([f"# profdata sha256 {sha}"] if sha else [])
    return "\n".join(head + list(symbols)) + "\n"


def show_output(records):
    """`llvm-profdata show --all-functions` text for [(name, hash, entry count)]."""
    lines = ["Counters:"]
    for name, func_hash, count in records:
        lines += [f"  {name}:", f"    Hash: 0x{func_hash:016x}", "    Counters: 2", f"    Function count: {count}"]
    lines += ["Instrumentation level: Front-end", f"Functions shown: {len(records)}"]
    return "\n".join(lines) + "\n"


def macho(sections, cputype=ARM64):
    """A thin 64-bit Mach-O header with one __TEXT segment holding `sections` [(name, address, size)]."""
    segment = struct.pack("<II16sQQQQiiII", 0x19, 72 + 80 * len(sections), b"__TEXT", 0x100000000, 0x400000, 0,
                          0x400000, 5, 5, len(sections), 0)
    for name, address, size in sections:
        segment += struct.pack("<16s16sQQIIIIIIII", name.encode(), b"__TEXT", address, size, 0, 2, 0, 0, 0, 0, 0, 0)
    other = struct.pack("<II", 0x32, 8)  # an unrelated load command the parse skips
    commands = other + segment
    return struct.pack("<IiiIIIII", 0xFEEDFACF, cputype, 0, 2, 2, len(commands), 0, 0) + commands


def fat(*thin_slices):
    """A universal file of `thin_slices` [(cputype, bytes)], each at a 4 KiB boundary."""
    header = struct.pack(">II", 0xCAFEBABE, len(thin_slices))
    body, offset, entries = b"", 4096, b""
    for cputype, data in thin_slices:
        entries += struct.pack(">iiIII", cputype, 0, offset, len(data), 12)
        padded = data + b"\0" * (-len(data) % 4096)
        body += padded
        offset += len(padded)
    return (header + entries).ljust(4096, b"\0") + body


SWIFT_LAUNCH = "App.swift:$s4main8launchedyyF"
SWIFT_PUBLIC = "$s4main5startyyF"
CLANG_LOCAL = "shim.c;setup_shim"
OBJC = "-[AppDelegate applicationDidFinishLaunching:]"
LATE = "$s4main4lateyyF"
INLINED = "Small.swift:$s4main6inlinedyyF"


class Fixture(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="pgo-check-")
        self.addCleanup(shutil.rmtree, self.dir)
        # The repo's pinned file is real state (task 052); a fixture pins only what it passes with --pinned.
        self.addCleanup(setattr, pc, "DEFAULT_PINNED", pc.DEFAULT_PINNED)
        pc.DEFAULT_PINNED = os.path.join(self.dir, "absent.sha256")
        self.fake = self.write("fake-llvm-profdata.py",
                               "import sys\nsys.stdout.write(open(sys.argv[-1] + '.show').read())\n")

    def write(self, name, content, mode="w"):
        path = os.path.join(self.dir, name)
        with open(path, mode) as target:
            target.write(content)
        return path

    def profile(self, name, records):
        path = self.write(name, "profile bytes " + name)
        self.write(name + ".show", show_output(records))
        return path

    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = pc.main([*args, "--llvm-profdata", f"{sys.executable} {self.fake}"])
        self.out, self.err = out.getvalue(), err.getvalue()
        return code

    def checks(self):
        line = [line for line in self.out.splitlines() if line.startswith("PGO-CHECK ")][-1]
        return {c["check"]: c for c in json.loads(line[len("PGO-CHECK "):])["checks"]}

    def bound_order(self, symbols, profdata_bytes=b"profdata v1"):
        """An order file bound to a profdata the test writes; returns (order path, profdata path)."""
        profdata = self.write("cmux-next.profdata", profdata_bytes, "wb")
        sha = hashlib.sha256(profdata_bytes).hexdigest()
        return self.write("cmux-next.order", order_file(symbols, sha)), profdata


class ParseTests(unittest.TestCase):
    def test_link_map_sections_symbols_and_dead(self):
        parsed = pc.parse_link_map(link_map([(TEXT_START, "_main"), (TEXT_START + 0x40, OBJC), (TEXT_START + 0x80,
                                             "ltmp0"), (TEXT_START + 0x20, "ltmp0")], dead=["_$s4main6unusedyyF"]))
        self.assertEqual(parsed.arch, "arm64")
        self.assertEqual(parsed.sections[("__TEXT", "__text")], (TEXT_START, 0x200000))
        self.assertEqual(parsed.symbols[OBJC], TEXT_START + 0x40)  # a name with spaces keeps them
        self.assertEqual(parsed.symbols["ltmp0"], TEXT_START + 0x20)  # a repeated local name: its lowest address
        self.assertEqual(parsed.dead, {"_$s4main6unusedyyF"})

    def test_a_file_that_is_not_a_link_map_is_an_input_error(self):
        with self.assertRaises(pc.InputError):
            pc.parse_link_map("_main\n_other\n")

    def test_order_file_prefixes_comments_duplicates_and_header(self):
        sha = "ab" * 32
        parsed = pc.parse_order(order_file(["_main", "arm64:_$s4main5startyyF", "App.o:_helper", "_main", "",
                                            "x86_64:App.o:_both", OBJC, "# a comment"], sha))
        self.assertEqual(parsed.symbols, ["_main", "_$s4main5startyyF", "_helper", "_both", OBJC])
        self.assertEqual(parsed.duplicates, 1)
        self.assertEqual(parsed.sha256, sha)
        self.assertIsNone(pc.parse_order(order_file(["_main"])).sha256)

    def test_profile_names_map_to_mach_o_symbols(self):
        self.assertEqual(pc.symbol_candidates(SWIFT_LAUNCH)[0], "_$s4main8launchedyyF")
        self.assertEqual(pc.symbol_candidates("/src/My App/App.swift:$s4main1fyyF")[0], "_$s4main1fyyF")
        self.assertEqual(pc.symbol_candidates(SWIFT_PUBLIC)[0], "_$s4main5startyyF")
        self.assertEqual(pc.symbol_candidates(CLANG_LOCAL)[0], "_setup_shim")
        self.assertEqual(pc.symbol_candidates("main"), ["_main", "main"])
        self.assertEqual(pc.symbol_candidates(OBJC), [OBJC])
        self.assertEqual(pc.symbol_candidates("Shim.m:" + OBJC), [OBJC])

    def test_show_output_records_names_hashes_and_counts(self):
        records = [(SWIFT_LAUNCH, 0x3EA, 7), ("main", 0x3E9, 0), (SWIFT_LAUNCH, 0x99, 1)]
        self.assertEqual(pc.profile_records(show_output(records)), records)

    def test_mach_o_text_sections_thin_and_universal(self):
        with tempfile.TemporaryDirectory() as folder:
            thin = os.path.join(folder, "thin")
            with open(thin, "wb") as target:
                target.write(macho([("__text", TEXT_START, 0x1000), ("__stubs", TEXT_START + 0x1000, 0x20)]))
            self.assertEqual(pc.binary_text_sections(thin, "arm64"),
                             {("__TEXT", "__text"): (TEXT_START, 0x1000), ("__TEXT", "__stubs"): (TEXT_START + 0x1000,
                                                                                                  0x20)})
            universal = os.path.join(folder, "universal")
            with open(universal, "wb") as target:
                target.write(fat((X86_64, macho([("__text", 0x100002000, 0x500)], X86_64)),
                                 (ARM64, macho([("__text", TEXT_START, 0x700)]))))
            self.assertEqual(pc.binary_text_sections(universal, "arm64")[("__TEXT", "__text")], (TEXT_START, 0x700))
            self.assertEqual(pc.binary_text_sections(universal, "x86_64")[("__TEXT", "__text")], (0x100002000, 0x500))
            with self.assertRaises(pc.InputError):
                pc.binary_text_sections(universal, "")  # two slices, the map names no arch
            truncated = os.path.join(folder, "truncated")
            with open(truncated, "wb") as target:
                target.write(macho([("__text", TEXT_START, 0x1000)])[:40])
            with self.assertRaises(pc.InputError):
                pc.binary_text_sections(truncated, "arm64")


class CoverageTests(Fixture):
    def map_with(self, live, dead=()):
        return self.write("cmux.map", link_map([(TEXT_START + 0x10 * i, s) for i, s in enumerate(live)], dead=dead))

    def test_ninety_percent_passes(self):
        symbols = [f"_f{i}" for i in range(10)]
        order, profdata = self.bound_order(symbols)
        code = self.run_main("--order", order, "--link-map", self.map_with(symbols[:9]), "--profdata", profdata)
        self.assertEqual(code, 0, self.out + self.err)
        coverage = self.checks()["coverage"]
        self.assertEqual((coverage["percent"], coverage["live"], coverage["absent"]), (90.0, 9, 1))

    def test_under_ninety_percent_fails_and_names_what_is_missing(self):
        symbols = [f"_f{i}" for i in range(20)]
        order, profdata = self.bound_order(symbols)
        live = symbols[:17]
        self.assertEqual(self.run_main("--order", order, "--link-map", self.map_with(live, dead=["_f17"]),
                                       "--profdata", profdata), 1)
        coverage = self.checks()["coverage"]
        self.assertEqual((coverage["ok"], coverage["percent"], coverage["dead_stripped"], coverage["absent"]),
                         (False, 85.0, 1, 2))
        self.assertIn("dead_stripped: _f17", self.out)
        self.assertIn("absent: _f18", self.out)

    def test_an_order_file_without_symbols_fails(self):
        order, profdata = self.bound_order([])
        self.assertEqual(self.run_main("--order", order, "--link-map", self.map_with(["_main"]), "--profdata",
                                       profdata), 1)
        self.assertEqual(self.checks()["coverage"]["detail"], "the order file has no symbols")

    def test_json_keeps_every_missing_name(self):
        symbols = [f"_f{i}" for i in range(30)]
        order, profdata = self.bound_order(symbols)
        report = os.path.join(self.dir, "report.json")
        self.run_main("--order", order, "--link-map", self.map_with(["_f0"]), "--profdata", profdata, "--json", report)
        with open(report) as source:
            coverage = json.load(source)["checks"][0]
        self.assertEqual(len(coverage["absent"]), 29)
        self.assertIn("... 19 more", self.out)

    def test_unreadable_inputs_exit_2(self):
        order, profdata = self.bound_order(["_main"])
        self.assertEqual(self.run_main("--order", order, "--link-map", os.path.join(self.dir, "none.map")), 2)
        self.assertIn("--link-map", self.err)
        self.assertEqual(self.run_main("--order", order, "--link-map", self.write("bad.map", "nothing\n")), 2)


class BindingTests(Fixture):
    def setUp(self):
        super().setUp()
        self.map = self.write("cmux.map", link_map([(TEXT_START, "_main")]))

    def test_header_sha_matches_profdata_and_pinned(self):
        order, profdata = self.bound_order(["_main"])
        sha = hashlib.sha256(b"profdata v1").hexdigest()
        pinned = self.write("pinned.sha256", f"# the pinned profile\n{sha}  cmux-next.profdata\n")
        self.assertEqual(self.run_main("--order", order, "--link-map", self.map, "--profdata", profdata,
                                       "--pinned", pinned), 0, self.out)
        self.assertEqual(sorted(self.checks()["binding"]["compared"]), ["pinned", "profdata"])

    def test_a_profdata_of_another_refresh_fails(self):
        order, _ = self.bound_order(["_main"])
        other = self.write("other.profdata", b"profdata v2", "wb")
        self.assertEqual(self.run_main("--order", order, "--link-map", self.map, "--profdata", other), 1)
        self.assertFalse(self.checks()["binding"]["ok"])

    def test_a_pinned_sha_of_another_refresh_fails(self):
        order, _ = self.bound_order(["_main"])
        pinned = self.write("pinned.sha256", f"{'cd' * 32}  cmux-next.profdata\n")
        self.assertEqual(self.run_main("--order", order, "--link-map", self.map, "--pinned", pinned), 1)
        self.assertIn("pinned is " + "cd" * 32, self.checks()["binding"]["detail"])

    def test_no_pinned_profile_fails_a_bound_order(self):
        order, _ = self.bound_order(["_main"])
        pinned = self.write("pinned.sha256", "# no profile is pinned\n")
        self.assertEqual(self.run_main("--order", order, "--link-map", self.map, "--pinned", pinned), 1)
        self.assertIn("pinned is not pinned", self.checks()["binding"]["detail"])

    def test_a_header_without_sha_fails(self):
        order = self.write("cmux-next.order", order_file(["_main"]))
        profdata = self.write("cmux-next.profdata", b"profdata v1", "wb")
        self.assertEqual(self.run_main("--order", order, "--link-map", self.map, "--profdata", profdata), 1)
        self.assertIn("no `# profdata sha256", self.checks()["binding"]["detail"])

    def test_nothing_to_compare_with_fails(self):
        order, _ = self.bound_order(["_main"])
        self.assertEqual(self.run_main("--order", order, "--link-map", self.map), 1)
        self.assertIn("nothing to compare", self.checks()["binding"]["detail"])

    def test_a_pinned_file_that_is_not_a_sha_is_an_input_error(self):
        order, _ = self.bound_order(["_main"])
        self.assertEqual(self.run_main("--order", order, "--link-map", self.map, "--pinned",
                                       self.write("pinned.sha256", "latest  cmux-next.profdata\n")), 2)


class LinkMapBinaryTests(Fixture):
    def app(self, sections):
        bundle = os.path.join(self.dir, "cmux.app")
        os.makedirs(os.path.join(bundle, "Contents", "MacOS"))
        with open(os.path.join(bundle, "Contents", "Info.plist"), "wb") as target:
            plistlib.dump({"CFBundleExecutable": "cmux"}, target)
        with open(os.path.join(bundle, "Contents", "MacOS", "cmux"), "wb") as target:
            target.write(macho(sections))
        return bundle

    def run_with_app(self, sections):
        order, profdata = self.bound_order(["_main"])
        return self.run_main("--order", order, "--link-map", self.write("cmux.map", link_map([(TEXT_START, "_main")])),
                             "--profdata", profdata, "--app", self.app(sections))

    def test_the_map_of_this_binary_passes(self):
        self.assertEqual(self.run_with_app([("__text", TEXT_START, 0x200000), ("__stubs", TEXT_START + 0x200000,
                                                                               0x100)]), 0, self.out)
        self.assertTrue(self.checks()["link-map"]["ok"])

    def test_the_map_of_another_link_fails(self):
        self.assertEqual(self.run_with_app([("__text", TEXT_START, 0x200040), ("__stubs", TEXT_START + 0x200040,
                                                                               0x100)]), 1)
        self.assertIn("__TEXT,__stubs, __TEXT,__text differ", self.checks()["link-map"]["detail"])

    def test_an_app_without_executable_name_is_an_input_error(self):
        order, profdata = self.bound_order(["_main"])
        bundle = os.path.join(self.dir, "empty.app")
        os.makedirs(bundle)
        self.assertEqual(self.run_main("--order", order, "--link-map", self.write("cmux.map", link_map(
            [(TEXT_START, "_main")])), "--profdata", profdata, "--app", bundle), 2)


class LaunchWindowTests(Fixture):
    SYMBOLS = [(TEXT_START, "_$s4main8launchedyyF"), (TEXT_START + 0x100, "_$s4main5startyyF"),
               (TEXT_START + 0x200, "_setup_shim"), (WINDOW_END - 0x10, OBJC), (WINDOW_END, "_$s4main4lateyyF")]

    def run_window(self, records, *extra, symbols=None, arch="arm64"):
        profdata = self.profile("cmux-next.profdata", records)  # the same hashes: no mismatch
        order = self.write("cmux-next.order", order_file([name for _, name in self.SYMBOLS],
                                                         pc.runner.sha256_of(profdata)))
        fresh = self.profile("launch.profraw", records)
        return self.run_main("--order", order, "--link-map", self.write("cmux.map", link_map(
            symbols or self.SYMBOLS, arch=arch)), "--profdata", profdata, "--launch-profile", fresh, *extra)

    def test_launch_functions_in_the_first_64_pages_pass(self):
        records = [(SWIFT_LAUNCH, 1, 3), (SWIFT_PUBLIC, 2, 1), (CLANG_LOCAL, 3, 1), (OBJC, 4, 9), (INLINED, 5, 2),
                   (LATE, 6, 0)]  # LATE did not run in the launch; INLINED is not in the map
        self.assertEqual(self.run_window(records), 0, self.out)
        window = self.checks()["launch-window"]
        self.assertEqual((window["percent"], window["inside"], window["outside"], window["unmapped"],
                          window["page_size"]), (100.0, 4, 0, 1, 16384))

    def test_a_launch_function_past_the_window_fails_under_90_percent(self):
        records = [(SWIFT_LAUNCH, 1, 3), (SWIFT_PUBLIC, 2, 1), (CLANG_LOCAL, 3, 1), (OBJC, 4, 9), (LATE, 6, 1)]
        self.assertEqual(self.run_window(records), 1)
        window = self.checks()["launch-window"]
        self.assertEqual((window["ok"], window["percent"], window["outside"]), (False, 80.0, 1))
        self.assertIn("outside: " + LATE, self.out)

    def test_pages_and_page_size_set_the_window(self):
        records = [(SWIFT_LAUNCH, 1, 3), (OBJC, 4, 9)]
        self.run_window(records, "--pages", "1")
        self.assertEqual(self.checks()["launch-window"]["percent"], 50.0)
        self.run_window(records, "--page-size", "4096")
        self.assertEqual(self.checks()["launch-window"]["page_size"], 4096)
        self.run_window(records, arch="x86_64")
        self.assertEqual(self.checks()["launch-window"]["page_size"], 4096)

    def test_no_launch_function_in_the_map_fails(self):
        self.assertEqual(self.run_window([(INLINED, 5, 2)]), 1)
        self.assertEqual(self.checks()["launch-window"]["detail"],
                         "no launch function of the profile is in the link map")


class MismatchTests(Fixture):
    def run_mismatch(self, fresh, pinned):
        profdata = self.profile("cmux-next.profdata", pinned)
        sha = pc.runner.sha256_of(profdata)
        order = self.write("cmux-next.order", order_file(["_$s4main8launchedyyF"], sha))
        return self.run_main("--order", order, "--link-map", self.write("cmux.map", link_map(
            [(TEXT_START, "_$s4main8launchedyyF")])), "--profdata", profdata, "--launch-profile",
            self.profile("launch.profraw", fresh))

    PINNED = [(SWIFT_LAUNCH, 1, 5), ("$s4main1ayyF", 2, 0), ("$s4main1byyF", 3, 0), ("$s4main1cyyF", 4, 0),
              ("$s4main1dyyF", 5, 0)]

    def test_twenty_percent_passes(self):
        fresh = [(SWIFT_LAUNCH, 1, 3), ("$s4main1ayyF", 2, 0), ("$s4main1byyF", 3, 0), ("$s4main1cyyF", 4, 0),
                 ("$s4main1dyyF", 99, 0), ("$s4main3newyyF", 7, 0)]
        self.assertEqual(self.run_mismatch(fresh, self.PINNED), 0, self.out)
        mismatch = self.checks()["mismatch"]
        self.assertEqual((mismatch["percent"], mismatch["compared"], mismatch["mismatched"], mismatch["new"]),
                         (20.0, 5, 1, 1))

    def test_over_twenty_percent_fails(self):
        fresh = [(SWIFT_LAUNCH, 1, 3), ("$s4main1ayyF", 2, 0), ("$s4main1byyF", 3, 0), ("$s4main1cyyF", 98, 0),
                 ("$s4main1dyyF", 99, 0)]
        self.assertEqual(self.run_mismatch(fresh, self.PINNED), 1)
        self.assertEqual(self.checks()["mismatch"]["percent"], 40.0)
        self.assertIn("mismatched: $s4main1cyyF", self.out)

    def test_a_name_with_two_hashes_matches_either(self):
        pinned = self.PINNED + [(SWIFT_LAUNCH, 77, 1)]
        fresh = [(SWIFT_LAUNCH, 77, 3), ("$s4main1ayyF", 2, 0)]
        self.assertEqual(self.run_mismatch(fresh, pinned), 0, self.out)
        self.assertEqual(self.checks()["mismatch"]["percent"], 0.0)

    def test_no_shared_name_fails(self):
        self.assertEqual(self.run_mismatch([(SWIFT_LAUNCH + "x", 1, 3)], self.PINNED), 1)
        self.assertIn("no function of the launch profile", self.checks()["mismatch"]["detail"])


def find_llvm_profdata():
    spec = importlib.util.spec_from_file_location("test_pgo_scenarios_tool", SCENARIOS_TESTS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.TOOL


TOOL = find_llvm_profdata()


@unittest.skipUnless(TOOL, "no llvm-profdata on this host")
class RealToolTests(unittest.TestCase):
    """The text-format fixtures of test_pgo_scenarios.py through the real llvm-profdata: run 1's launch profile is
    the fresh one, the merge of the three launch profiles the pinned one; one changed hash is 1 of 6 functions."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="pgo-check-real-")
        self.addCleanup(shutil.rmtree, self.dir)

    def test_mismatch_and_window_with_llvm_profdata(self):
        profdata = os.path.join(self.dir, "cmux-next.profdata")
        pc.runner.run_tool(TOOL, "merge", "-o", profdata,
                           *(os.path.join(FIXTURES, f"run{run}-launch.proftext") for run in (1, 2, 3)))
        with open(os.path.join(FIXTURES, "run1-launch.proftext")) as source:
            fresh_text = source.read().replace("\n1003\n", "\n9003\n")  # sometimes() changed since the refresh
        fresh = os.path.join(self.dir, "launch.proftext")
        with open(fresh, "w") as target:
            target.write(fresh_text)
        order = os.path.join(self.dir, "cmux-next.order")
        with open(order, "w") as target:
            target.write(order_file(["_main", "_$s4main8launchedyyF"], pc.runner.sha256_of(profdata)))
        link = os.path.join(self.dir, "cmux.map")
        with open(link, "w") as target:
            target.write(link_map([(TEXT_START, "_main"), (TEXT_START + 0x40, "_$s4main8launchedyyF"),
                                   (WINDOW_END + 0x40, "_$s4main9sometimesyyF")]))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = pc.main(["--order", order, "--link-map", link, "--profdata", profdata, "--launch-profile", fresh,
                            "--llvm-profdata", " ".join(TOOL)])
        text = out.getvalue()
        checks = {c["check"]: c for c in json.loads(text.splitlines()[-1][len("PGO-CHECK "):])["checks"]}
        self.assertEqual(checks["mismatch"]["mismatched"], 1, text)
        self.assertEqual(checks["mismatch"]["compared"], 6, text)
        self.assertTrue(checks["mismatch"]["ok"], text)
        # main, launched and sometimes ran in run 1's launch; sometimes lies past the window.
        self.assertEqual((checks["launch-window"]["inside"], checks["launch-window"]["outside"]), (2, 1), text)
        self.assertEqual(code, 1, text)


if __name__ == "__main__":
    unittest.main()
