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

# Reports as the lane's runtimes write them (stack_trace_format '#%n %p %F %S').
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

    def run_collect(self, tool: str, exit_code: int) -> int:
        return collect_findings.main([
            "--tool", tool, "--crate", "cmux-holder", "--os", "linux", "--target", "x86_64-unknown-linux-gnu",
            "--toolchain", "nightly-2026-10-20", "--commit", "abc", "--sysroot", SYSROOT,
            "--exit", str(exit_code), "--log-dir", str(self.logs), "--events", str(self.events),
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

    def test_only_unsupported_tests_is_its_own_result(self) -> None:
        self.events.write_text(event("codec$tests::reads_dir", "failed", MIRI_UNSUPPORTED) + "\n")
        self.assertEqual(self.run_collect("miri", 100), 1)
        self.assertEqual(self.run_record()["result"], "unsupported")
        self.assertEqual(self.findings(), [])

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
