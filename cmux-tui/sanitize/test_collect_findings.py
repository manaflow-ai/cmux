#!/usr/bin/env python3
"""Tests for collect_findings.py: python3 cmux-tui/sanitize/test_collect_findings.py"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("collect_findings", HERE / "collect_findings.py")
collect_findings = importlib.util.module_from_spec(_spec)
sys.modules["collect_findings"] = collect_findings
_spec.loader.exec_module(collect_findings)

R = "/rustc/07e526db9df34143c99ec8064acc8ad543f69b30/library"

# Short reports in the lane's frame shape (stack_trace_format '#%n %p %F %L').
ASAN_UAF = f"""=================================================================
==308935==ERROR: AddressSanitizer: heap-use-after-free on address 0x754e595e4010 at pc 0x56cc45a854e6 bp 0x752e56ffd750 sp 0x752e56ffd748
READ of size 1 at 0x754e595e4010 thread T1
    #0 0x56cc45a854e5 in cmux_holder::ring::Ring::read /src/cmux-tui/crates/cmux-holder/src/ring.rs:12:26
    #1 0x56cc45a83878 in cmux_holder::ring::tests::read_after_drop /src/cmux-tui/crates/cmux-holder/src/ring.rs:80:12
    #2 0x56cc45a85e47 in <cmux_holder::ring::tests::read_after_drop::{{closure#0}} as core::ops::function::FnOnce<()>>::call_once {R}/core/src/ops/function.rs:250:5

0x754e595e4010 is located 0 bytes inside of 3-byte region [0x754e595e4010,0x754e595e4013)
freed by thread T1 here:
    #0 0x56cc45a1b0f6 in free <null>
    #1 0x56cc45a85000 in cmux_holder::ring::Ring::drop /src/cmux-tui/crates/cmux-holder/src/ring.rs:40:9

SUMMARY: AddressSanitizer: heap-use-after-free /src/cmux-tui/crates/cmux-holder/src/ring.rs:12:26 in cmux_holder::ring::Ring::read
==308935==ABORTING
"""


def lsan_leak(pid: int) -> str:
    return f"""=================================================================
=={pid}==ERROR: LeakSanitizer: detected memory leaks

Direct leak of 4096 byte(s) in 1 object(s) allocated from:
    #0 0x5e925b9fb554 in malloc <null>
    #1 0x5e925bc174cf in cmux_holder::spool::Spool::grow /src/cmux-tui/crates/cmux-holder/src/spool.rs:31:18
    #2 0x5e925bd316c5 in cmux_holder::spool::Spool::push /src/cmux-tui/crates/cmux-holder/src/spool.rs:47:13
    #3 0x5e925ba2a0f1 in cmux_holder::spool::tests::push_many /src/cmux-tui/crates/cmux-holder/src/spool.rs:158:9

Indirect leak of 64 byte(s) in 1 object(s) allocated from:
    #0 0x5e925b9fb554 in malloc <null>
    #1 0x5e925bc17000 in cmux_holder::spool::Chunk::new /src/cmux-tui/crates/cmux-holder/src/spool.rs:12:5

SUMMARY: LeakSanitizer: 4160 byte(s) leaked in 2 allocation(s).
"""


def miri_output(test: str, alloc: int, tag: int) -> str:
    return f"""
running 1 test
test {test} ... error: Undefined Behavior: attempting a read access using <{tag}> at alloc{alloc}[0x0], but that tag does not exist in the borrow stack for this location
  --> src/lib.rs:12:26
   |
12 |         let x = unsafe {{ *p }};
   |                          ^^ Undefined Behavior occurred here
   |
   = help: this indicates a potential bug in the program: it performed an invalid operation, but the Stacked Borrows rules it violated are still experimental
   = note: this is on thread `{test}`
   = note: stack backtrace:
           0: codec::decode
               at src/lib.rs:12:26: 12:28
           1: core::ptr::read::<u8>
               at /home/u/.rustup/toolchains/nightly-2026-10-20-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/core/src/ptr/mod.rs:1700:5: 1700:20
           2: tests::decode_roundtrip
               at src/lib.rs:40:9: 40:30

note: some details are omitted, run with `MIRIFLAGS=-Zmiri-backtrace=full` for a verbose backtrace

error: aborting due to 1 previous error


"""


MIRI_LEAK = """
running 1 test
test tests::leaks ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 3 filtered out; finished in 0.13s

error: memory leaked: alloc41476 (Rust heap, size: 32, align: 1), allocated here:
   --> src/lib.rs:20:9
    |
    = note: stack backtrace:
            0: alloc::raw_vec::RawVecInner::try_allocate_in
                at /home/u/.rustup/toolchains/nightly-2026-10-20-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/alloc/src/raw_vec/mod.rs:485:41: 485:63
            1: tests::leaks
                at src/lib.rs:20:9: 20:20

error: aborting due to 1 previous error
"""

MIRI_UNSUPPORTED = """
running 1 test
test tests::reads_dir ... error: unsupported operation: `opendir` not available when isolation is enabled
    --> /home/u/.rustup/toolchains/nightly-2026-10-20-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/std/src/sys/fs/unix.rs:1852:57
     |
     = help: set `MIRIFLAGS=-Zmiri-disable-isolation` to disable isolation;

error: aborting due to 1 previous error
"""

# A plain red test that prints its own `error:` line: not a Miri finding.
PLAIN_FAILURE = """
running 1 test
error: config missing
thread 'tests::plain' panicked at src/lib.rs:5:5:
assertion failed: false
test tests::plain ... FAILED
"""

SYSROOT = "/home/u/.rustup/toolchains/nightly-2026-10-20-x86_64-unknown-linux-gnu"

# Real-shaped reports, as nightly-2026-10-20 with -Zbuild-std, the rust-src
# remap and inline frames writes them (`#%n %p %F %L`): std's inlined helpers
# are their own lines with /rustc/ files, a frame with no line keeps its
# module and BuildId, and libtest's harness sits under the test.
BIN = "(/w/target-address/x86_64-unknown-linux-gnu/debug/deps/cmux_holder-52c34744ed7e30b6+{off}) (BuildId: c84536ef)"
HARNESS = f"""    #{{n}} 0x5f3c38c6e69a in test::__rust_begin_short_backtrace::<core::result::Result<(), alloc::string::String>, fn() -> core::result::Result<(), alloc::string::String>> {BIN.format(off="0x19c69a")}
    #{{n1}} 0x5f3c38cad373 in <test::types::RunnableTest>::run {BIN.format(off="0x1db373")}
    #{{n2}} 0x5f3c38c74900 in std::panicking::catch_unwind::do_call::<core::panic::unwind_safe::AssertUnwindSafe<test::run_test_in_process::{{{{closure#0}}}}>, core::result::Result<(), alloc::string::String>> test.73e075bfb260dd19-cgu.01
    #{{n3}} 0x5f3c38c7dddd in __rust_try test.73e075bfb260dd19-cgu.01
    #{{n4}} 0x5f3c38c77f13 in test::run_test_in_process {BIN.format(off="0x1a5f13")}
"""


def harness(first: int) -> str:
    return HARNESS.format(n=first, n1=first + 1, n2=first + 2, n3=first + 3, n4=first + 4)


def real_leak(pid: int, user_fn: str, test: str, elem: str) -> str:
    """A Vec::with_capacity leak: malloc, the std allocator chain, then the user function and its test."""
    return f"""=================================================================
=={pid}==ERROR: LeakSanitizer: detected memory leaks

Direct leak of 128 byte(s) in 1 object(s) allocated from:
    #0 0x58ee36b0ed04 in malloc {BIN.format(off="0x16cd04")}
    #1 0x58ee36b3c111 in std::sys::alloc::unix::<impl core::alloc::global::GlobalAlloc for std::alloc::System>::alloc {R}/std/src/sys/alloc/unix.rs:14:22
    #2 0x58ee36c6ea35 in __rustc::__rdl_alloc {BIN.format(off="0x2cca35")}
    #3 0x58ee36b3d34f in alloc::alloc::alloc {R}/alloc/src/alloc.rs:158:9
    #4 0x58ee36b3d34f in <alloc::alloc::Global>::alloc_impl_runtime {R}/alloc/src/alloc.rs:335:73
    #5 0x58ee36b3d34f in <alloc::alloc::Global as core::alloc::Allocator>::allocate {R}/alloc/src/alloc.rs:575:14
    #6 0x58ee36b3d34f in <alloc::raw_vec::RawVecInner>::try_allocate_in {R}/alloc/src/raw_vec/mod.rs:485:47
    #7 0x58ee36b3d66b in <alloc::raw_vec::RawVec<{elem}>>::with_capacity_in {R}/alloc/src/raw_vec/mod.rs:187:20
    #8 0x58ee36b3d66b in <alloc::vec::Vec<{elem}>>::with_capacity {R}/alloc/src/vec/mod.rs:519:9
    #9 0x58ee36b3d66b in cmux_holder::spool::{user_fn} /src/cmux-tui/crates/cmux-holder/src/spool.rs:31:18
    #10 0x58ee36b3ddad in cmux_holder::spool::tests::{test} /src/cmux-tui/crates/cmux-holder/src/spool.rs:158:9
    #11 0x58ee36b3ddad in cmux_holder::spool::tests::{test}::{{closure#0}} /src/cmux-tui/crates/cmux-holder/src/spool.rs:157:20
    #12 0x58ee36b3ddad in <cmux_holder::spool::tests::{test}::{{closure#0}} as core::ops::function::FnOnce<()>>::call_once {R}/core/src/ops/function.rs:250:5
{harness(13)}
SUMMARY: AddressSanitizer: 128 byte(s) leaked in 1 allocation(s).
"""


def real_overflow(pid: int, test: str) -> str:
    """A heap overflow in a test body that is inlined into libtest's call_once frame."""
    return f"""=================================================================
=={pid}==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x74e4897e4014 at pc 0x61b3820a4acd bp 0x74c4871fe2d0 sp 0x74c4871fe2c8
READ of size 1 at 0x74e4897e4014 thread T1
    #0 0x61b3820a4acc in cmux_holder::ring::tests::{test} /src/cmux-tui/crates/cmux-holder/src/ring.rs:43:26
    #1 0x61b3820a4acc in cmux_holder::ring::tests::{test}::{{closure#0}} /src/cmux-tui/crates/cmux-holder/src/ring.rs:41:25
    #2 0x61b3820a4acc in <cmux_holder::ring::tests::{test}::{{closure#0}} as core::ops::function::FnOnce<()>>::call_once {R}/core/src/ops/function.rs:250:5
{harness(3)}
0x74e4897e4014 is located 0 bytes after 4-byte region [0x74e4897e4010,0x74e4897e4014)
allocated by thread T1 here:
    #0 0x61b38206ed04 in malloc {BIN.format(off="0x16cd04")}

SUMMARY: AddressSanitizer: heap-buffer-overflow /src/cmux-tui/crates/cmux-holder/src/ring.rs:43:26 in cmux_holder::ring::tests::{test}
==${pid}==ABORTING
"""


def event(name: str, kind: str, stdout: str = "") -> str:
    record = {"type": "test", "event": kind, "name": name}
    if stdout:
        record["stdout"] = stdout
    return json.dumps(record)


class CollectTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.logs = self.tmp / "logs"
        self.logs.mkdir()
        self.events = self.tmp / "events.jsonl"
        self.events.write_text("")
        self.out = self.tmp / "findings.jsonl"
        self.runs = self.tmp / "runs.jsonl"

    def run_collect(self, tool: str, exit_code: int, tests: Path | None = None) -> int:
        return collect_findings.main([
            "--tool", tool, "--crate", "cmux-holder", "--os", "linux", "--target", "x86_64-unknown-linux-gnu",
            "--toolchain", "nightly-2026-10-20", "--commit", "abc", "--sysroot", SYSROOT,
            "--exit", str(exit_code), "--log-dir", str(self.logs), "--events", str(self.events),
            "--tests", str(tests or ""),
            "--nextest-log", str(self.tmp / "nextest.log"), "--out", str(self.out), "--runs", str(self.runs)])

    def findings(self) -> list[dict]:
        return [json.loads(line) for line in self.out.read_text().splitlines()] if self.out.exists() else []

    def run_record(self) -> dict:
        lines = self.runs.read_text().splitlines()
        self.assertEqual(len(lines), 1)
        return json.loads(lines[0])

    def test_asan_report_is_one_signed_finding(self) -> None:
        (self.logs / "report.308935").write_text(ASAN_UAF)
        self.events.write_text(event("cmux-holder::ring$tests::read_after_drop", "failed") + "\n")
        self.assertEqual(self.run_collect("address", 100), 1)
        [finding] = self.findings()
        self.assertEqual(finding["kind"], "asan")
        self.assertEqual(finding["exception"], "heap-use-after-free READ")
        self.assertEqual(finding["frames"][:2], ["cmux_holder::ring::Ring::read",
                                                 "cmux_holder::ring::tests::read_after_drop"])
        self.assertEqual(len(finding["hash12"]), 12)
        self.assertEqual((finding["lane"], finding["tool"], finding["crate"]),
                         ("sanitizer-rust", "address", "cmux-holder"))
        self.assertEqual(self.run_record()["result"], "findings")

    def test_same_leak_in_two_processes_is_one_finding_counted_twice(self) -> None:
        (self.logs / "report.1").write_text(lsan_leak(1))
        (self.logs / "report.2").write_text(lsan_leak(2))
        self.assertEqual(self.run_collect("leak", 100), 1)
        [finding] = self.findings()  # the indirect leak hangs off the direct one
        self.assertEqual((finding["kind"], finding["exception"]), ("lsan", "direct-leak"))
        self.assertEqual(finding["frames"][0], "cmux_holder::spool::Spool::grow")
        self.assertEqual(finding["count"], 2)
        self.assertEqual(len(finding["reports"]), 2)

    def test_leak_has_the_same_signature_under_asan_and_lsan(self) -> None:
        (self.logs / "report.1").write_text(lsan_leak(1))
        self.run_collect("address", 100)
        self.run_collect("leak", 100)
        hashes = {finding["hash12"] for finding in self.findings()}
        self.assertEqual(len(self.findings()), 2)
        self.assertEqual(len(hashes), 1)

    def test_two_real_vec_leaks_are_two_findings_named_by_their_function(self) -> None:
        (self.logs / "report.11").write_text(real_leak(11, "grow_a", "leak_a", "u64"))
        (self.logs / "report.12").write_text(real_leak(12, "grow_b", "leak_b", "u32"))
        self.run_collect("leak", 100)
        findings = {finding["frames"][0]: finding for finding in self.findings()}
        self.assertEqual(sorted(findings), ["cmux_holder::spool::grow_a", "cmux_holder::spool::grow_b"])
        self.assertNotEqual(findings["cmux_holder::spool::grow_a"]["hash12"],
                            findings["cmux_holder::spool::grow_b"]["hash12"])
        self.assertEqual(findings["cmux_holder::spool::grow_a"]["frames"],
                         ["cmux_holder::spool::grow_a", "cmux_holder::spool::tests::leak_a",
                          "cmux_holder::spool::tests::leak_a::{closure}"])
        for finding in findings.values():
            self.assertFalse([frame for frame in finding["frames"] if "alloc" in frame or "test::" in frame[:6]])

    def test_two_inlined_test_bodies_are_two_findings_with_their_tests(self) -> None:
        (self.logs / "report.21").write_text(real_overflow(21, "overflow_a"))
        (self.logs / "report.22").write_text(real_overflow(22, "overflow_b"))
        (self.logs / "tests.tsv").write_text("21\tcmux-holder::cmux_holder$ring::tests::overflow_a\n"
                                             "22\tcmux-holder::cmux_holder$ring::tests::overflow_b\n")
        self.events.write_text(event("cmux-holder::cmux_holder$ring::tests::overflow_a", "failed") + "\n"
                               + event("cmux-holder::cmux_holder$ring::tests::overflow_b", "failed") + "\n")
        self.assertEqual(self.run_collect("address", 100, tests=self.logs / "tests.tsv"), 1)
        findings = {finding["test"]: finding for finding in self.findings()}
        self.assertEqual(sorted(findings), ["cmux-holder::cmux_holder$ring::tests::overflow_a",
                                            "cmux-holder::cmux_holder$ring::tests::overflow_b"])
        a, b = findings.values()
        self.assertNotEqual(a["hash12"], b["hash12"])
        self.assertEqual(a["frames"], ["cmux_holder::ring::tests::overflow_a",
                                       "cmux_holder::ring::tests::overflow_a::{closure}"])
        self.assertEqual(a["process"], "cmux_holder")

    def test_runner_test_names_take_the_events_full_name(self) -> None:
        self.events.write_text(event("ws::ws$tests::leak_a", "failed") + "\n")
        tests = self.tmp / "tests.tsv"
        tests.write_text("31\tws$tests::leak_a\nnot a line\n32\tws$tests::fine\n")
        pids = collect_findings.read_test_pids(tests, collect_findings.read_events(self.events))
        self.assertEqual(pids, {"31": "ws::ws$tests::leak_a", "32": "ws$tests::fine"})

    def test_unreadable_sanitizer_report_is_never_a_pass(self) -> None:
        (self.logs / "report.9").write_text("==9==AddressSanitizer: nested bug in the same thread, aborting.\n")
        self.assertEqual(self.run_collect("address", 1), 1)
        record = self.run_record()
        self.assertEqual(record["result"], "findings")
        self.assertEqual(record["unparsed_reports"], [str(self.logs / "report.9")])

    def test_miri_errors_unsupported_tests_and_plain_failures(self) -> None:
        self.events.write_text("\n".join([
            "not json",
            event("codec$tests::decode_roundtrip", "failed", miri_output("tests::decode_roundtrip", 41287, 1234)),
            event("codec$tests::leaks", "failed", MIRI_LEAK),
            event("codec$tests::reads_dir", "failed", MIRI_UNSUPPORTED),
            event("codec$tests::plain", "failed", PLAIN_FAILURE),
            event("codec$tests::ok", "ok"),
        ]) + "\n")
        self.assertEqual(self.run_collect("miri", 100), 1)
        findings = {finding["test"]: finding for finding in self.findings()}
        self.assertEqual(sorted(findings), ["codec$tests::decode_roundtrip", "codec$tests::leaks"])
        ub = findings["codec$tests::decode_roundtrip"]
        self.assertEqual(ub["kind"], "miri")
        self.assertEqual(ub["exception"], "Undefined Behavior: attempting a read access using <N> at allocNADDR, "
                                          "but that tag does not exist in the borrow stack for this location")
        self.assertEqual(ub["frames"][0], "codec::decode")
        self.assertNotIn("core::ptr::read", " ".join(ub["frames"]))  # std frame, by its /rustc/ file
        leak = findings["codec$tests::leaks"]
        self.assertEqual(leak["exception"], "memory leaked")
        self.assertEqual(leak["frames"], ["tests::leaks"])
        record = self.run_record()
        self.assertEqual(record["result"], "findings")
        self.assertEqual(record["unsupported_tests"], {"codec$tests::reads_dir": ["unsupported operation"]})
        self.assertIn("codec$tests::plain", record["failed_tests"])
        self.assertEqual(record["passed"], 1)

    def test_miri_signature_ignores_allocation_ids_and_tags(self) -> None:
        self.events.write_text(event("a", "failed", miri_output("tests::a", 1, 2)) + "\n"
                               + event("b", "failed", miri_output("tests::b", 99887, 31337)) + "\n")
        self.run_collect("miri", 100)
        [finding] = self.findings()
        self.assertEqual(finding["count"], 2)

    def test_only_unsupported_tests_is_a_green_run_that_lists_them(self) -> None:
        self.events.write_text(event("codec$tests::reads_dir", "failed", MIRI_UNSUPPORTED) + "\n"
                               + event("codec$tests::ok", "ok") + "\n")
        self.assertEqual(self.run_collect("miri", 100), 0)
        record = self.run_record()
        self.assertEqual(record["result"], "unsupported")
        self.assertEqual(record["unsupported_tests"], {"codec$tests::reads_dir": ["unsupported operation"]})
        self.assertEqual(self.findings(), [])

    def test_unsupported_beside_a_plain_failure_is_red(self) -> None:
        self.events.write_text(event("codec$tests::reads_dir", "failed", MIRI_UNSUPPORTED) + "\n"
                               + event("codec$tests::plain", "failed", PLAIN_FAILURE) + "\n")
        self.assertEqual(self.run_collect("miri", 100), 1)
        self.assertEqual(self.run_record()["result"], "failed")

    def test_clean_run_passes(self) -> None:
        self.events.write_text(event("cmux-holder$tests::a", "ok") + "\n")
        self.assertEqual(self.run_collect("thread", 0), 0)
        record = self.run_record()
        self.assertEqual((record["result"], record["passed"], record["findings"]), ("pass", 1, 0))

    def test_nextest_exit_codes(self) -> None:
        result = collect_findings.run_result
        self.assertEqual(result(101, False, False, [], {}), "build-failed")
        self.assertEqual(result(104, False, False, [], {}), "build-failed")
        self.assertEqual(result(4, False, False, [], {}), "no-tests")
        self.assertEqual(result(100, False, False, ["t"], {}), "failed")
        self.assertEqual(result(0, False, False, [], {}), "pass")

    def test_sysroot_frames_are_named_as_rustc_paths(self) -> None:
        name = collect_findings._sysroot_file
        self.assertEqual(name(f"{SYSROOT}/lib/rustlib/src/rust/library/core/src/ptr/mod.rs", SYSROOT),
                         "/rustc/library/core/src/ptr/mod.rs")
        self.assertEqual(name("src/lib.rs", SYSROOT), "src/lib.rs")
        self.assertEqual(name(f"{SYSROOT}/lib/x.rs", ""), f"{SYSROOT}/lib/x.rs")


if __name__ == "__main__":
    unittest.main()
