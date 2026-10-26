#!/usr/bin/env python3
"""run-scenarios.py --stage order and page-fault-order.py (p08-startup-109): the link map parse, the Mach-O __TEXT
read (thin and universal), the ASLR slide from vmmap, the fault table of an xctrace export (a hand-written shape:
the first fleet run confirms the real column names, and the stage names the columns it saw when none is an
address), profile names to linker symbols, the order (launch symbols first, then the page-fault symbols of a
majority of the cold launches, no line twice, a duplicate static name qualified with its object), the stage's flow
over a fake app (purge, then the recording, the launch, the recording's end at startup_complete), the faults cut at the
app's startup_complete launch mark, a local label (ltmpN) at a function's address never in the order, the profdata
binding, and check.py refusing an order of another profdata. Runs on any OS:
python3 -I scripts/cmux-next/tests/test_pgo_page_fault_order.py"""

import contextlib
import importlib.util
import io
import json
import os
import struct
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PGO = os.path.join(os.path.dirname(HERE), "pgo")


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(PGO, file))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


rs = load("run_scenarios", "run-scenarios.py")
pfo = rs.order_lib()
check = load("pgo_check", "check.py")

SHA = "a" * 64
OTHER_SHA = "b" * 64
VMADDR, TEXT_ADDRESS, TEXT_SIZE = 0x100000000, 0x100004000, 0x1000
LOAD_ADDRESS = 0x104F30000
SLIDE = LOAD_ADDRESS - VMADDR

LINK_MAP = """# Path: /build/cmux DEV.app/Contents/MacOS/cmux DEV
# Arch: arm64
# Object files:
[  0] linker synthesized
[  1] /build/CmuxNextApp.o
[  2] /build/libghostty.a(terminal.o)
[  3] /build/libcmux_app_ffi.a(ffi.o)
[  4] /build/libghostty.a(util.o)
# Sections:
# Address\tSize    \tSegment\tSection
0x100004000\t0x00001000\t__TEXT\t__text
0x100005000\t0x00000100\t__TEXT\t__stubs
0x100005100\t0x00000200\t__TEXT\t__cstring
# Symbols:
# Address\tSize    \tFile  Name
0x100004000\t0x00000000\t[  1] ltmp0
0x100004000\t0x00000100\t[  1] _main
0x100004100\t0x00000100\t[  1] _$s7CmuxNext6launchyyF
0x100004200\t0x00000100\t[  1] _$s7CmuxNext7restoreyyF
0x100004300\t0x00000100\t[  1] _$s7CmuxNext4idleyyF
0x100004400\t0x00000000\t[  2] ltmp0
0x100004400\t0x00000200\t[  2] _ghostty_init
0x100004480\t0x00000000\t[  2] Ltmp_inner
0x100004600\t0x00000100\t[  2] _helper
0x100004700\t0x00000100\t[  4] _helper
0x100004800\t0x00000000\t[  3] ltmp1
0x100004800\t0x00000000\t[  3] _cmux_ffi_start_alias
0x100004800\t0x00000100\t[  3] _cmux_ffi_start
0x100004800\t0x00000000\t[  3] l_private
0x100004900\t0x00000000\t[  3] _rust_zero_size
0x100004A00\t0x00000600\t[  1] -[CmuxAppDelegate applicationDidFinishLaunching:]
0x100005100\t0x0000000C\t[  0] literal string: hello world
# Dead Stripped Symbols:
#        \tSize    \tFile  Name
<<dead>> \t0x00000018\t[  1] _$s7CmuxNext4deadyyF
"""

LAUNCH_NAMES = [
    "CmuxNext/App.swift:$s7CmuxNext6launchyyF",  # Swift PGO name of a private function: `<file>:<name>`
    "/src/Restore.swift;$s7CmuxNext7restoreyyF",  # IR PGO name: `<file>;<name>`
    "main",
    "\x01-[CmuxAppDelegate applicationDidFinishLaunching:]",
    "Inlined.swift:$s7CmuxNext7inlinedyyF",  # inlined everywhere by -profile-use: not in the map
    "$s7CmuxNext4deadyyF",  # dead-stripped
]

# Link map addresses each cold launch faulted on, in time order.
FAULT_RUNS = [
    [0x100004110, 0x100004450, 0x100004610, 0x100004950, 0x100004810, 0x100005150, 0x100004300],
    [0x100004450, 0x100004950, 0x100004810, 0x100004610, 0x100004710],
    [0x100004450, 0x100004810, 0x100004950, 0x100004610],
]
EXPECTED_ORDER = [
    "_main", "_$s7CmuxNext6launchyyF", "_$s7CmuxNext7restoreyyF",
    "-[CmuxAppDelegate applicationDidFinishLaunching:]",  # the launch symbols, by address
    "_ghostty_init", "_cmux_ffi_start", "_rust_zero_size", "terminal.o:_helper",  # by median first-fault rank
]


def segment(name, vmaddr, vmsize, sections=()):
    body = b"".join(struct.pack("<16s16sQQIIIIIIII", sect.encode(), name.encode(), address, size, 0, 0, 0, 0, 0, 0,
                                0, 0) for sect, address, size in sections)
    return struct.pack("<II16sQQQQiiII", 0x19, 72 + len(body), name.encode(), vmaddr, vmsize, 0, 0, 5, 5,
                       len(sections), 0) + body


def thin_macho(cputype=0x0100000C, text_size=TEXT_SIZE):
    commands = segment("__PAGEZERO", 0, VMADDR) + segment(
        "__TEXT", VMADDR, 0x8000, [("__text", TEXT_ADDRESS, text_size), ("__stubs", 0x100005000, 0x100)])
    return struct.pack("<IiiIIIII", 0xFEEDFACF, cputype, 0, 2, 2, len(commands), 0, 0) + commands


def fat_macho():
    intel, arm = thin_macho(0x01000007, text_size=0x2000), thin_macho()
    header = struct.pack(">II", 0xCAFEBABE, 2)
    first = 0x1000
    second = first + len(intel)
    return (header + struct.pack(">iiIII", 0x01000007, 3, first, len(intel), 12)
            + struct.pack(">iiIII", 0x0100000C, 0, second, len(arm), 12)).ljust(first, b"\0") + intel + arm


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as target:
        target.write(data)
    return path


def launch_list(sha=SHA, names=LAUNCH_NAMES):
    return ("# cmux-next launch functions: ran before startup_complete (run-scenarios.py --stage profile)\n"
            f"# profdata sha256 {sha}\n" + "".join(name + "\n" for name in names))


class Workspace:
    """A stage folder with stage 1's outputs, the -profile-use app, its link map and the build's sha256 file."""

    def __init__(self, root, stamped=SHA, listed=SHA, built=SHA, binary=None):
        self.out = os.path.join(root, "stage")
        write(os.path.join(self.out, rs.LAUNCH_FUNCTIONS), launch_list(listed))
        write(os.path.join(self.out, rs.PROFDATA + ".sha256"), f"{stamped}  {rs.PROFDATA}\n")
        self.app = os.path.join(root, "cmux DEV order.app")
        self.binary = write(os.path.join(self.app, "Contents", "MacOS", "cmux DEV"), binary or thin_macho())
        self.link_map = write(os.path.join(root, "cmux DEV-LinkMap-normal-arm64.txt"), LINK_MAP)
        self.build_sha = write(os.path.join(root, "Resources", "build", "cmux-next.profdata.sha256"),
                               f"{built}  {rs.PROFDATA}\n")

    def argv(self, *extra):
        return ["--stage", "order", "--app", self.app, "--link-map", self.link_map, "--out", self.out,
                "--profdata-sha256", self.build_sha, *extra]

    def record_faults(self, runs=FAULT_RUNS):
        for index, addresses in enumerate(runs, 1):
            write(os.path.join(self.out, "order-runs", f"order-cold-{index}", rs.FAULTS), json.dumps(
                {"run": f"order-cold-{index}", "pid": 40 + index, "load_address": hex(LOAD_ADDRESS),
                 "faults": len(addresses), "addresses": [hex(a + SLIDE) for a in addresses]}))

    def read(self, name):
        with open(os.path.join(self.out, name)) as source:
            return source.read()


def quiet(function, *args, **kwargs):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = function(*args, **kwargs)
    return code, out.getvalue(), err.getvalue()


class LinkMapTests(unittest.TestCase):
    def setUp(self):
        self.map = pfo.parse_link_map(LINK_MAP)
        self.index = pfo.TextIndex(self.map)

    def test_parse_keeps_live_symbols_and_the_header(self):
        self.assertEqual((self.map.path, self.map.arch), ("/build/cmux DEV.app/Contents/MacOS/cmux DEV", "arm64"))
        names = [s.name for s in self.map.symbols]
        self.assertNotIn("_$s7CmuxNext4deadyyF", names)
        self.assertIn("-[CmuxAppDelegate applicationDidFinishLaunching:]", names)
        self.assertEqual(self.map.objects[2], "/build/libghostty.a(terminal.o)")
        self.assertEqual(self.map.section("__TEXT", "__text"), (TEXT_ADDRESS, TEXT_SIZE))

    def test_index_is_text_only_and_a_zero_size_symbol_runs_to_the_next(self):
        self.assertNotIn("literal string: hello world", self.index.by_name)
        self.assertEqual(self.index.symbol_at(0x100004950).name, "_rust_zero_size")
        self.assertEqual(self.index.symbol_at(0x1000049FF).name, "_rust_zero_size")
        self.assertIsNone(self.index.symbol_at(0x100005150))
        self.assertIsNone(self.index.symbol_at(0x100003FFF))

    def test_a_fault_at_a_shared_address_is_the_sized_function_never_a_local_label(self):
        self.assertEqual(self.index.symbol_at(0x100004010).name, "_main")  # ltmp0 of CmuxNextApp.o shares it
        self.assertEqual(self.index.symbol_at(0x100004410).name, "_ghostty_init")  # ltmp0 of terminal.o
        self.assertEqual(self.index.symbol_at(0x100004490).name, "_ghostty_init")  # past the Ltmp_inner label
        self.assertEqual(self.index.symbol_at(0x100004810).name, "_cmux_ffi_start")  # a zero-size alias too
        for label in ("ltmp0", "ltmp1", "Ltmp_inner", "l_private"):
            self.assertNotIn(label, self.index.by_name)
        self.assertEqual([pfo.is_local_label(n) for n in ("ltmp12", "l_OBJC_x", "LBB0_1")], [True] * 3)
        self.assertFalse(pfo.is_local_label("_ltmp0") or pfo.is_local_label("-[A b]") or pfo.is_local_label("_main"))

    def test_a_name_twice_in_text_is_qualified_with_its_object(self):
        first, second = self.index.by_name["_helper"]
        self.assertEqual((self.index.order_line(first), self.index.order_line(second)),
                         ("terminal.o:_helper", "util.o:_helper"))
        self.assertEqual(self.index.order_line(self.index.by_name["_main"][0]), "_main")

    def test_not_a_link_map_is_refused(self):
        with self.assertRaises(pfo.OrderError):
            pfo.parse_link_map("hello\n")


class BinaryTests(unittest.TestCase):
    def test_thin_and_universal_text(self):
        with tempfile.TemporaryDirectory() as root:
            expected = {"vmaddr": VMADDR, "text_address": TEXT_ADDRESS, "text_size": TEXT_SIZE}
            self.assertEqual(pfo.macho_text(write(os.path.join(root, "thin"), thin_macho()), "arm64"), expected)
            self.assertEqual(pfo.macho_text(write(os.path.join(root, "fat"), fat_macho()), "arm64"), expected)
            self.assertEqual(pfo.macho_text(os.path.join(root, "fat"), "x86_64")["text_size"], 0x2000)

    def test_a_link_map_of_another_build_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            other = pfo.macho_text(write(os.path.join(root, "bin"), thin_macho(text_size=0x1100)), "arm64")
            with self.assertRaisesRegex(pfo.OrderError, "another build"):
                pfo.check_link_map_matches(pfo.parse_link_map(LINK_MAP), other)

    def test_vmmap_gives_the_binary_text_address(self):
        binary = "/build/cmux DEV.app/Contents/MacOS/cmux DEV"
        vmmap = ("==== Non-writable regions for process 42\n"
                 "REGION TYPE                    START - END         [ VSIZE  RSDNT  DIRTY   SWAP] PRT/MAX SHRMOD PURGE"
                 "    REGION DETAIL\n"
                 "__TEXT                      1a0000000-1a0100000    [  1024K   512K     0K     0K] r-x/r-x SM=COW"
                 "          /usr/lib/dyld\n"
                 f"__TEXT                      104f30000-104f38000    [    32K    32K     0K     0K] r-x/r-x SM=COW"
                 f"          {binary}\n")
        self.assertEqual(pfo.text_load_address(vmmap, binary), LOAD_ADDRESS)
        with self.assertRaises(pfo.OrderError):
            pfo.text_load_address(vmmap, "/other/binary")


VM_EXPORT = """<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[7]'><schema name="virtual-memory">
<col><mnemonic>start</mnemonic><name>Start</name><engineering-type>start-time</engineering-type></col>
<col><mnemonic>thread</mnemonic><name>Thread</name><engineering-type>thread</engineering-type></col>
<col><mnemonic>operation</mnemonic><name>Operation</name><engineering-type>string</engineering-type></col>
<col><mnemonic>address</mnemonic><name>Address</name><engineering-type>address</engineering-type></col>
</schema>
<row><start-time id="1" fmt="00:00.200">200000000</start-time><thread id="2" fmt="Main Thread 0x1a (cmux DEV, pid: 42)"><tid id="3">26</tid><process id="4" fmt="cmux DEV (42)"><pid id="5">42</pid></process></thread><string id="6" fmt="Page In">Page In</string><address id="7" fmt="0x104f34450">4378018896</address></row>
<row><start-time id="8" fmt="00:00.100">100000000</start-time><thread ref="2"/><string ref="6"/><address id="9" fmt="0x104f34110">0x104f34110</address></row>
<row><start-time id="10" fmt="00:00.150">150000000</start-time><thread id="11" fmt="Main Thread 0x2 (WindowServer, pid: 7)"><tid id="12">2</tid><process id="13" fmt="WindowServer (7)"><pid id="14">7</pid></process></thread><string ref="6"/><address id="15" fmt="0x1">1</address></row>
</node></trace-query-result>
"""


# The app's launch marks: first_window_frame_committed (20 ms after process start) at 100 ms of the trace,
# startup_complete (100 ms) at 190 ms (emitted 10 ms late); the marks of another app (pid 7) and of another subsystem
# are ignored.
SIGNPOST_EXPORT = """<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[8]'><schema name="os-signpost">
<col><mnemonic>time</mnemonic><name>Timestamp</name><engineering-type>event-time</engineering-type></col>
<col><mnemonic>thread</mnemonic><name>Thread</name><engineering-type>thread</engineering-type></col>
<col><mnemonic>process</mnemonic><name>Process</name><engineering-type>process</engineering-type></col>
<col><mnemonic>event-type</mnemonic><name>Event Type</name><engineering-type>event-type</engineering-type></col>
<col><mnemonic>name</mnemonic><name>Name</name><engineering-type>signpost-name</engineering-type></col>
<col><mnemonic>subsystem</mnemonic><name>Subsystem</name><engineering-type>subsystem</engineering-type></col>
<col><mnemonic>message</mnemonic><name>Message</name><engineering-type>os-log-metadata</engineering-type></col>
</schema>
<row><event-time id="1" fmt="00:00.100">100000000</event-time><thread id="2" fmt="Main Thread 0x1a (cmux DEV, pid: 42)"><tid id="3">26</tid><process id="4" fmt="cmux DEV (42)"><pid id="5">42</pid></process></thread><process ref="4"/><event-type id="6" fmt="Event">Event</event-type><signpost-name id="7" fmt="launch.mark">launch.mark</signpost-name><subsystem id="8" fmt="com.cmuxterm.app.next">com.cmuxterm.app.next</subsystem><os-log-metadata id="9" fmt="first_window_frame_committed ms=20.0"><narrative-text id="10" fmt="first_window_frame_committed ms=20.0">first_window_frame_committed ms=20.0</narrative-text></os-log-metadata></row>
<row><event-time id="11" fmt="00:00.120">120000000</event-time><thread id="12" fmt="Main Thread 0x2 (other, pid: 7)"><tid id="13">2</tid><process id="14" fmt="other (7)"><pid id="15">7</pid></process></thread><process ref="14"/><event-type ref="6"/><signpost-name ref="7"/><subsystem ref="8"/><os-log-metadata id="16" fmt="startup_complete ms=1.0"><narrative-text id="17" fmt="startup_complete ms=1.0">startup_complete ms=1.0</narrative-text></os-log-metadata></row>
<row><event-time id="18" fmt="00:00.150">150000000</event-time><thread ref="2"/><process ref="4"/><event-type ref="6"/><signpost-name ref="7"/><subsystem id="19" fmt="com.example">com.example</subsystem><os-log-metadata id="20" fmt="startup_complete ms=5.0"><narrative-text id="21" fmt="startup_complete ms=5.0">startup_complete ms=5.0</narrative-text></os-log-metadata></row>
<row><event-time id="22" fmt="00:00.190">190000000</event-time><thread ref="2"/><process ref="4"/><event-type ref="6"/><signpost-name ref="7"/><subsystem ref="8"/><os-log-metadata id="23" fmt="startup_complete ms=100.0"><narrative-text id="24" fmt="startup_complete ms=100.0">startup_complete ms=100.0</narrative-text></os-log-metadata></row>
</node></trace-query-result>
"""


class FakeTrace:
    """trace.py's export seam over the two fixture tables: `export_file` writes the table the xpath names."""

    def __init__(self, root):
        self.real = rs.load_by_path("cmux_trace", os.path.join(rs.CMUX_NEXT, "trace.py"))
        self.root = root
        self.EXPORT_TOC_S = self.EXPORT_TIMEOUT_S = 1
        self.xctrace_rows = self.real.xctrace_rows

    def XcTrace(self, run_dir, system_trace, cap_s):
        return type("Recording", (), {"path": os.path.join(run_dir, "trace.trace")})()

    def export_file(self, command, path, timeout, name, to_stdout=False):
        tables = {"os-signpost": SIGNPOST_EXPORT, "virtual-memory": VM_EXPORT}
        if name in tables:
            write(path, tables[name])

    def parse_toc(self, path):
        return {"schemas": ["time-profile", "os-signpost", "virtual-memory"]}


class FaultTableTests(unittest.TestCase):
    def test_the_app_faults_of_an_export_in_time_order(self):
        trace = rs.load_by_path("cmux_trace", os.path.join(rs.CMUX_NEXT, "trace.py"))
        with tempfile.TemporaryDirectory() as root:
            path = write(os.path.join(root, "xctrace-virtual-memory.xml"), VM_EXPORT)
            self.assertEqual(pfo.fault_addresses(trace.xctrace_rows(path), 42), [0x104F34110, 0x104F34450])

    def test_a_table_without_an_address_column_names_its_columns(self):
        with self.assertRaisesRegex(pfo.OrderError, "operation"):
            pfo.fault_addresses([{"operation": ("Page In", "Page In"), "start": (1, "1")}], 42)

    def test_faults_after_startup_complete_are_cut(self):
        trace = rs.load_by_path("cmux_trace", os.path.join(rs.CMUX_NEXT, "trace.py"))
        with tempfile.TemporaryDirectory() as root:
            signposts = write(os.path.join(root, "xctrace-os-signpost.xml"), SIGNPOST_EXPORT)
            cutoff = pfo.startup_cutoff(trace.xctrace_rows(signposts), 42)
            # process start = min(100 ms - 20 ms, 190 ms - 100 ms) = 80 ms; startup_complete at 100 ms after it.
            self.assertEqual(cutoff, 180_000_000)
            path = write(os.path.join(root, "xctrace-virtual-memory.xml"), VM_EXPORT)
            self.assertEqual(pfo.fault_addresses(trace.xctrace_rows(path), 42, cutoff), [0x104F34110])
            self.assertEqual(pfo.fault_addresses(trace.xctrace_rows(path), 42, 200_000_000), [0x104F34110, 0x104F34450])

    def test_no_startup_complete_mark_is_refused(self):
        trace = rs.load_by_path("cmux_trace", os.path.join(rs.CMUX_NEXT, "trace.py"))
        with tempfile.TemporaryDirectory() as root:
            signposts = write(os.path.join(root, "xctrace-os-signpost.xml"), SIGNPOST_EXPORT)
            with self.assertRaisesRegex(pfo.OrderError, "no launch.mark startup_complete of pid 99"):
                pfo.startup_cutoff(trace.xctrace_rows(signposts), 99)

    def test_a_cut_needs_the_fault_start(self):
        rows = [{"address": (0x104F34110, "0x104f34110"), "process": {"pid": 42}}]
        self.assertEqual(pfo.fault_addresses(rows, 42), [0x104F34110])
        with self.assertRaisesRegex(pfo.OrderError, "no start time"):
            pfo.fault_addresses(rows, 42, 1)

    def test_the_recorder_cuts_its_faults_at_startup_complete(self):
        with tempfile.TemporaryDirectory() as root:
            recorder = rs.VmFaultRecorder(root, trace=FakeTrace(root))
            self.assertEqual(recorder.faults(42), ([0x104F34110], 180_000_000))

    def test_vm_schema_names(self):
        self.assertTrue(pfo.is_vm_schema("virtual-memory"))
        self.assertFalse(pfo.is_vm_schema("time-profile"))
        self.assertFalse(pfo.is_vm_schema("syscall"))


class OrderTests(unittest.TestCase):
    def setUp(self):
        self.index = pfo.TextIndex(pfo.parse_link_map(LINK_MAP))

    def test_profile_names_to_linker_names(self):
        self.assertEqual(pfo.linker_names("App.swift:$s4main3fooyyF"), ("_$s4main3fooyyF", "$s4main3fooyyF"))
        self.assertEqual(pfo.linker_names("/x/a.c;helper"), ("_helper", "helper"))
        self.assertEqual(pfo.linker_names("\x01-[A b:]")[1], "-[A b:]")
        self.assertEqual(pfo.linker_names("ns::f(int)")[0], "_ns::f(int)")  # no file prefix: kept whole

    def test_launch_symbols_in_address_order_and_the_missing_named(self):
        symbols, missing = pfo.launch_symbols(LAUNCH_NAMES, self.index)
        self.assertEqual([s.name for s in symbols], EXPECTED_ORDER[:4])
        self.assertEqual(missing, LAUNCH_NAMES[4:])

    def test_launch_first_then_majority_faults_by_median_rank_no_line_twice(self):
        launch, _ = pfo.launch_symbols(LAUNCH_NAMES, self.index)
        faults, needed = pfo.fault_symbols(FAULT_RUNS, self.index)
        self.assertEqual(needed, 2)
        lines = pfo.order_lines(launch, faults, self.index)
        self.assertEqual(lines, EXPECTED_ORDER)
        self.assertEqual(len(lines), len(set(lines)))
        self.assertNotIn("_$s7CmuxNext4idleyyF", lines)  # faulted in one launch of three
        self.assertNotIn("util.o:_helper", lines)
        self.assertFalse([line for line in lines if "ltmp" in line or line.rpartition(":")[2].startswith("l")])

    def test_the_order_is_the_same_for_the_runs_in_any_order(self):
        launch, _ = pfo.launch_symbols(LAUNCH_NAMES, self.index)
        for runs in (FAULT_RUNS[::-1], FAULT_RUNS[1:] + FAULT_RUNS[:1]):
            faults, _ = pfo.fault_symbols(runs, self.index)
            self.assertEqual(pfo.order_lines(launch, faults, self.index), EXPECTED_ORDER)

    def test_min_runs_bounds(self):
        with self.assertRaises(pfo.OrderError):
            pfo.fault_symbols(FAULT_RUNS, self.index, min_runs=4)
        faults, _ = pfo.fault_symbols(FAULT_RUNS, self.index, min_runs=1)
        self.assertIn("_$s7CmuxNext4idleyyF", [s.name for s in faults])

    def test_unslid(self):
        self.assertEqual(pfo.unslid([0x104F34110], LOAD_ADDRESS, VMADDR), [0x100004110])


class CheckTests(unittest.TestCase):
    def order(self, sha=SHA, lines=("_main", "_ghostty_init")):
        return pfo.render_order(sha, ["binary cmux DEV arm64"], list(lines))

    def test_check_order(self):
        self.assertEqual(pfo.check_order(self.order(), SHA), [])
        self.assertIn("the build uses", pfo.check_order(self.order(OTHER_SHA), SHA)[0])
        self.assertIn("no '# profdata sha256'", pfo.check_order("_main\n", SHA)[0])
        self.assertIn("listed twice", pfo.check_order(self.order(lines=("_main", "_main")), SHA)[0])
        self.assertIn("no symbol", pfo.check_order(self.order(lines=()), SHA)[0])

    def test_check_cli_refuses_a_sha_mismatch(self):
        with tempfile.TemporaryDirectory() as root:
            order = write(os.path.join(root, "cmux-next.order"), self.order())
            sha = write(os.path.join(root, "cmux-next.profdata.sha256"), f"{SHA}  cmux-next.profdata\n")
            other = write(os.path.join(root, "other.sha256"), f"{OTHER_SHA}  cmux-next.profdata\n")
            code, out, _ = quiet(check.main, ["--order", order, "--profdata-sha256", sha])
            self.assertEqual((code, out.split()[:2]), (0, ["pgo-check:", "ok"]))
            code, out, _ = quiet(check.main, ["--order", order, "--profdata-sha256", other])
            self.assertEqual(code, 1)
            self.assertIn(f"made from profdata {SHA}, the build uses {OTHER_SHA}", out)
            code, _, err = quiet(check.main, ["--order", order, "--profdata-sha256", os.path.join(root, "none")])
            self.assertEqual(code, 2)
            self.assertIn("none", err)


class FakeProcess:
    def poll(self):
        return None


class FakeApp:
    def __init__(self, events, pid):
        self.events, self.pid, self.binary, self.timings = events, pid, "/fake/cmux DEV", 0
        self.process = FakeProcess()

    def alive(self):
        return True

    def rpc(self, method, params=None, timeout=60):
        if method == "debug.timings":
            self.timings += 1
            marks = {"first_window_frame_committed": 80.0}
            if self.timings >= 2:
                marks["startup_complete"] = 300.0
                self.events.append("startup_complete")
            return {"launch_ms_since_process_start": marks}
        return {"error": f"unknown method {method}"}


class FakeLaunchError(SystemExit):
    pass


class FakeLauncher:
    errors = (SystemExit,)

    def __init__(self, events, fail=None):
        self.events, self.fail, self.runs = events, fail, []

    def end_tag(self):
        self.events.append("end_tag")

    @contextlib.contextmanager
    def launch(self, run, run_dir, env):
        self.runs.append((run, env))
        if run.name == self.fail:
            raise FakeLaunchError("bench-launch: socket-timeout")
        self.events.append(f"launch {run.name}")
        yield FakeApp(self.events, 40 + len(self.runs))
        self.events.append(f"quit {run.name}")


class FakeCold:
    errors = (SystemExit,)

    def __init__(self, events, refuse=False):
        self.events, self.refuse = events, refuse

    def check(self):
        if self.refuse:
            raise SystemExit(2)

    def __call__(self):
        self.events.append("purge")


class FakeRecorder:
    errors = (RuntimeError,)

    def __init__(self, events, run_dir):
        self.events, self.run = events, int(run_dir.rsplit("-", 1)[1])

    def start(self):
        self.events.append("record")

    def stop(self):
        self.events.append("record stop")

    def kill(self):
        self.events.append("record kill")

    def faults(self, pid):
        return [address + SLIDE for address in FAULT_RUNS[self.run - 1]], 300_000_000 + self.run


class StageTests(unittest.TestCase):
    def run_stage(self, workspace, events, launcher=None, cold=None, argv=()):
        """main() over the fakes: the second debug.timings completes startup (the real wait polls once, 0.25 s)."""
        return quiet(rs.main, workspace.argv(*argv), launcher=launcher or FakeLauncher(events),
                     cold=cold or FakeCold(events), recorder=lambda run_dir: FakeRecorder(events, run_dir),
                     load_address=lambda pid, binary: LOAD_ADDRESS)

    def test_the_stage_records_three_cold_launches_and_writes_both_orders(self):
        with tempfile.TemporaryDirectory() as root:
            workspace, events = Workspace(root), []
            code, out, err = self.run_stage(workspace, events)
            self.assertEqual(code, 0, err)
            once = ["purge", "record", "launch {}", "startup_complete", "record stop", "quit {}"]
            expected = ["end_tag"] + [e.format(f"order-cold-{i}") for i in (1, 2, 3) for e in once] + ["end_tag"]
            self.assertEqual(events, expected)
            order = workspace.read(rs.ORDER)
            self.assertEqual(pfo.order_symbols(order), EXPECTED_ORDER)
            self.assertEqual(pfo.header_shas(order), [SHA])
            self.assertEqual(pfo.order_symbols(workspace.read(rs.SWIFT_ONLY_ORDER)), EXPECTED_ORDER[:4])
            manifest = json.loads(workspace.read(rs.ORDER_MANIFEST))
            self.assertEqual((manifest["order"]["page_fault_symbols"], manifest["launch_functions"]["missing"]), (4, 2))
            self.assertEqual([r["load_address"] for r in manifest["runs"]], [hex(LOAD_ADDRESS)] * 3)
            with open(os.path.join(workspace.out, "order-runs", "order-cold-2", rs.FAULTS)) as source:
                self.assertEqual(json.load(source)["startup_complete_ns"], 300_000_002)
            self.assertIn('"stage": "order"', out)
            code, _, _ = quiet(check.main, ["--order", os.path.join(workspace.out, rs.ORDER),
                                            "--profdata-sha256", workspace.build_sha])
            self.assertEqual(code, 0)

    def test_merge_only_maps_the_kept_recordings(self):
        with tempfile.TemporaryDirectory() as root:
            workspace = Workspace(root, binary=fat_macho())
            workspace.record_faults()
            code, _, err = quiet(rs.main, workspace.argv("--merge-only"))
            self.assertEqual(code, 0, err)
            self.assertEqual(pfo.order_symbols(workspace.read(rs.ORDER)), EXPECTED_ORDER)

    def test_a_build_of_another_profdata_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            workspace = Workspace(root, built=OTHER_SHA)
            workspace.record_faults()
            code, _, err = quiet(rs.main, workspace.argv("--merge-only"))
            self.assertEqual(code, 1)
            self.assertIn(f"the -profile-use build used {OTHER_SHA}", err)
            self.assertFalse(os.path.exists(os.path.join(workspace.out, rs.ORDER)))

    def test_a_launch_list_of_another_profdata_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            workspace = Workspace(root, listed=OTHER_SHA)
            workspace.record_faults()
            code, _, err = quiet(rs.main, workspace.argv("--merge-only"))
            self.assertEqual(code, 1)
            self.assertIn("run stage 1 again", err)

    def test_a_link_map_of_another_binary_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            workspace = Workspace(root, binary=thin_macho(text_size=0x1100))
            workspace.record_faults()
            code, _, err = quiet(rs.main, workspace.argv("--merge-only"))
            self.assertEqual(code, 1)
            self.assertIn("another build", err)

    def test_a_missing_recording_is_named(self):
        with tempfile.TemporaryDirectory() as root:
            workspace = Workspace(root)
            workspace.record_faults(FAULT_RUNS[:2])
            code, _, err = quiet(rs.main, workspace.argv("--merge-only"))
            self.assertEqual(code, 1)
            self.assertIn("order-cold-3: no recorded faults", err)

    def test_a_refused_purge_stops_before_any_launch(self):
        with tempfile.TemporaryDirectory() as root:
            workspace, events = Workspace(root), []
            code, _, err = self.run_stage(workspace, events, cold=FakeCold(events, refuse=True))
            self.assertEqual(code, 1)
            self.assertIn("purge refused", err)
            self.assertEqual(events, [])

    def test_a_failed_launch_kills_the_recording_and_names_the_run(self):
        with tempfile.TemporaryDirectory() as root:
            workspace, events = Workspace(root), []
            code, _, err = self.run_stage(workspace, events, launcher=FakeLauncher(events, fail="order-cold-2"))
            self.assertEqual(code, 1)
            self.assertIn("order-cold-2: launch: FakeLaunchError", err)
            self.assertEqual(events[-3:], ["record", "record kill", "end_tag"])

    def test_order_runs_launch_cold_and_end_their_sessions(self):
        self.assertEqual([(r.name, r.keep_state, r.quit) for r in rs.order_plan(2)],
                         [("order-cold-1", False, "end-sessions"), ("order-cold-2", False, "end-sessions")])

    def test_the_cold_launches_skip_the_lab_host_validation(self):
        launcher = rs.order_launcher("/fake/cmux DEV.app", 30)
        self.assertEqual((launcher.validate_host, launcher.timeout), (False, 30))

    def test_order_needs_the_link_map(self):
        with tempfile.TemporaryDirectory() as root:
            workspace = Workspace(root)
            with self.assertRaises(SystemExit):
                quiet(rs.parse_args, ["--stage", "order", "--app", workspace.app, "--out", workspace.out])


if __name__ == "__main__":
    unittest.main()
