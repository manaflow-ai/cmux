#!/usr/bin/env python3
"""Tests for daemon-blocking-sweep.py: the MQ-13 grouping and the RUN-5 verdicts."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import time
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).with_name("daemon-blocking-sweep.py")
SPEC = importlib.util.spec_from_file_location("daemon_blocking_sweep", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
SWEEP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SWEEP)

SOURCE = """\
use std::fs;

pub fn read() {
    let _ = fs::read("x"); // line 4: daemon code
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn reads() {
        let brace = '{';
        let text = "}";
        read(); // line 16: test code
    }
}

pub fn after() {} // line 20: daemon code again
"""


def line(pid: int, file: str, number: int, kind: str, thread: str, mode: str = "record") -> str:
    return json.dumps(
        {
            "pid": pid,
            "thread": thread,
            "file": file,
            "line": number,
            "column": 9,
            "kind": kind,
            "mode": mode,
            "overflow": False,
        }
    )


class GroupTests(unittest.TestCase):
    def test_one_row_per_location_kind_and_thread_across_processes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            server = "crates/cmux-tui-core/src/server/listen.rs"
            (root / "blocking-1.jsonl").write_text(
                "\n".join(
                    [
                        line(1, server, 10, "fs", "mux-conn"),
                        line(1, server, 10, "sqlite", "mux-conn"),
                        line(1, server, 10, "fs", "mux-echo"),
                        line(1, "crates/cmux-threads/tests/blocking_panic.rs", 4, "fs", "t", "panic"),
                    ]
                )
                + "\n"
            )
            # A second process, and a torn last line from a killed one.
            (root / "blocking-2.jsonl").write_text(line(2, server, 10, "fs", "mux-conn") + "\n" + '{"pid":2,"thr')
            with redirect_stdout(io.StringIO()) as out, redirect_stderr(io.StringIO()) as err:
                rows = SWEEP.summarize(root)
            self.assertIn("torn line blocking-2.jsonl:2", err.getvalue())
            self.assertEqual(
                [(r["location"], r["kind"], r["thread"], r["processes"], r["fixture"]) for r in rows],
                [
                    (f"{server}:10:9", "fs", "mux-conn", 2, False),
                    (f"{server}:10:9", "fs", "mux-echo", 1, False),
                    (f"{server}:10:9", "sqlite", "mux-conn", 1, False),
                    ("crates/cmux-threads/tests/blocking_panic.rs:4:9", "fs", "t", 1, True),
                ],
            )
            self.assertIn("tasks=3 fixtures=1", out.getvalue())
            self.assertEqual(json.loads((root / "sites.json").read_text()), rows)


    def test_instance_numbers_in_a_thread_name_are_one_thread_class(self) -> None:
        reader = "crates/a/src/surface/hosted_reader.rs"
        rows = SWEEP.group(
            [
                json.loads(line(1, reader, 5, "sqlite", "surface-2-host")),
                json.loads(line(1, reader, 5, "sqlite", "surface-14-host")),
                json.loads(line(2, reader, 5, "sqlite", "surface-2-host")),
                json.loads(line(1, reader, 5, "sqlite", "surface-2-reader")),
            ]
        )
        self.assertEqual(
            [(r["thread"], r["thread_names"], r["processes"]) for r in rows],
            [("surface-N-host", 2, 2), ("surface-N-reader", 1, 1)],
        )


class FixtureTests(unittest.TestCase):
    def test_test_files_are_fixtures(self) -> None:
        self.assertTrue(SWEEP.is_fixture("crates/a/tests/x.rs", 1))
        self.assertTrue(SWEEP.is_fixture("crates/a/src/server/tests.rs", 1))
        self.assertTrue(SWEEP.is_fixture("crates/a/src/request_path_tests.rs", 1))
        self.assertFalse(SWEEP.is_fixture("crates/a/src/latests.rs", 1))

    def test_only_lines_inside_a_cfg_test_module_are_fixtures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "src" / "reader.rs"
            source.parent.mkdir()
            source.write_text(SOURCE, encoding="utf-8")
            self.assertEqual(SWEEP.cfg_test_ranges(source), ((7, 18),))
            self.assertFalse(SWEEP.is_fixture(str(source), 4))
            self.assertTrue(SWEEP.is_fixture(str(source), 16))
            self.assertFalse(SWEEP.is_fixture(str(source), 20))

    def test_the_thread_never_makes_a_fixture(self) -> None:
        # Unnamed or test-like thread names at daemon code are tasks: the row keeps them.
        rows = SWEEP.group(
            [
                json.loads(line(1, "crates/a/src/server/listen.rs", 3, "fs", name))
                for name in ("<unnamed>", "latest-sync", "a::tests::b")
            ]
        )
        self.assertEqual([row["fixture"] for row in rows], [False, False, False])

    def test_a_missing_source_is_not_a_fixture(self) -> None:
        self.assertFalse(SWEEP.is_fixture("/nonexistent/src/lib.rs", 3))


RECORD_LOG = """\
     Running unittests src/lib.rs (target/debug/deps/cmux_tui_core-0123456789abcdef)
test cloud::tests::needs_network ... FAILED
test server::tests::ok ... ok
test result: FAILED. 1 passed; 1 failed; 0 ignored
     Running tests/remote.rs (target/debug/deps/remote-fedcba9876543210)
test connects ... FAILED
test result: FAILED. 0 passed; 1 failed; 0 ignored
"""

PANIC_LOG = """\
     Running unittests src/lib.rs (target/debug/deps/cmux_tui_core-0123456789abcdef)
test cloud::tests::needs_network ... FAILED
test server::tests::ok ... FAILED
thread 'mux-conn' panicked at crates/cmux-threads/src/blocking.rs:350:5:
cmux_threads: blocking call (fs) at crates/cmux-tui-core/src/mux/a.rs:7:13 on thread 'mux-conn', which disallows blocking
cmux_threads: blocking call (fs) at crates/cmux-tui-core/src/mux/a.rs:7:13 on thread 'mux-conn', which disallows blocking
cmux_threads: blocking call (sqlite) at crates/cmux-tui-core/tests/registry_blocking_panic.rs:20:5 on thread 'x', which disallows blocking
test result: FAILED. 0 passed; 2 failed; 0 ignored
     Running tests/remote.rs (target/debug/deps/remote-fedcba9876543210)
test connects ... FAILED
test result: FAILED. 0 passed; 1 failed; 0 ignored
"""


class SuitesVerdictTests(unittest.TestCase):
    def test_totals_sum_every_test_binary(self) -> None:
        log = (
            "test result: ok. 48 passed; 0 failed; 1 ignored; 0 measured\n"
            "test result: FAILED. 3 passed; 2 failed; 0 ignored; 0 measured\n"
        )
        self.assertEqual(SWEEP.test_totals(log), (51, 2))

    def test_counts_distinct_panics_outside_test_code(self) -> None:
        self.assertEqual(
            SWEEP.blocking_panics(PANIC_LOG),
            [("fs", "crates/cmux-tui-core/src/mux/a.rs:7:13", "mux-conn")],
        )

    def test_failures_shared_with_record_mode_are_set_apart(self) -> None:
        result = SWEEP.run5_suites_verdict(RECORD_LOG, PANIC_LOG, [])
        core = "unittests src/lib.rs (cmux_tui_core)"
        self.assertEqual(result["panic_only_failures"], [(core, "server::tests::ok")])
        self.assertEqual(
            result["shared_failures"],
            [("tests/remote.rs (remote)", "connects"), (core, "cloud::tests::needs_network")],
        )
        self.assertEqual(result["verdict"], "fail")

    def test_a_binary_with_no_result_is_a_failure_of_its_own(self) -> None:
        log = (
            "     Running tests/cli.rs (/t/debug/deps/cli-0123456789abcdef)\n"
            "test a ... ok\n"
            "     Running tests/setup.rs (/t/debug/deps/setup-0123456789abcdef)\n"
            "test b ... FAILED\n"
            "test result: FAILED. 0 passed; 1 failed; 0 ignored\n"
            "     Running tests/hang.rs (/t/debug/deps/hang-0123456789abcdef)\n"
        )
        self.assertEqual(
            SWEEP.failed_tests(log),
            {
                ("tests/cli.rs (cli)", SWEEP.NO_RESULT),
                ("tests/setup.rs (setup)", "b"),
                ("tests/hang.rs (hang)", SWEEP.NO_RESULT),
            },
        )
        # cli failed tests in record mode but hung in panic mode: that is panic mode's own.
        record = log.replace("test a ... ok\n", "test a ... FAILED\ntest result: FAILED. 0 passed; 1 failed\n")
        result = SWEEP.run5_suites_verdict(record, log, [])
        self.assertEqual(result["panic_only_failures"], [("tests/cli.rs (cli)", SWEEP.NO_RESULT)])

    def test_a_hung_test_binary_is_stopped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fake = f"{directory}/deps/hung-0123456789abcdef"
            script = (
                "import sys, time\n"
                "print(f'     Running tests/hung.rs ({sys.argv[1]})', flush=True)\n"
                "time.sleep(60)\n"
            )
            started = time.monotonic()
            with redirect_stdout(io.StringIO()) as out:
                code, log = SWEEP.run_suite(
                    [sys.executable, "-c", script, fake], dict(os.environ), Path(directory), Path(directory) / "log", 1
                )
            self.assertLess(time.monotonic() - started, 30)
            self.assertNotEqual(code, 0)
            self.assertIn(f"SWEEP stopped {fake} after 1 s (1 processes)", out.getvalue())
            self.assertEqual(SWEEP.failed_tests(log), {("tests/hung.rs (hung)", SWEEP.NO_RESULT)})

    def test_only_shared_failures_pass(self) -> None:
        result = SWEEP.run5_suites_verdict(RECORD_LOG, RECORD_LOG, [{"fixture": True}])
        self.assertEqual(result["verdict"], "pass")
        self.assertEqual(len(result["shared_failures"]), 2)

    def test_a_site_outside_test_code_fails(self) -> None:
        result = SWEEP.run5_suites_verdict(RECORD_LOG, RECORD_LOG, [{"fixture": False}])
        self.assertEqual(result["verdict"], "fail")


BENCH_LOG = """\
LIFECYCLE-DAEMON against op="new-tab" n=40 p50=0.50 p95=1.00 max=2.00
LIFECYCLE-DAEMON against op="split right" n=40 p50=0.50 p95=1.00 max=2.00
LIFECYCLE-DAEMON ref op="new-tab" n=40 p50=0.50 p95=1.04 max=2.00
LIFECYCLE-DAEMON ref op="split right" n=40 p50=0.50 p95=1.20 max=2.00
"""


class BenchVerdictTests(unittest.TestCase):
    def test_parses_p95_per_binary_and_op(self) -> None:
        p95 = SWEEP.lifecycle_p95(BENCH_LOG)
        self.assertEqual(p95["against"], {"new-tab": 1.0, "split right": 1.0})
        self.assertEqual(p95["ref"], {"new-tab": 1.04, "split right": 1.2})

    def test_a_p95_over_the_noise_band_fails(self) -> None:
        verdict, problems = SWEEP.run5_bench_verdict(SWEEP.lifecycle_p95(BENCH_LOG), 0, 0.05)
        self.assertEqual(verdict, "fail")
        self.assertEqual(problems, ['op="split right" regressed ref_p95=1.20 against_p95=1.00'])

    def test_within_noise_and_target_passes(self) -> None:
        p95 = {"against": {"new-tab": 1.0}, "ref": {"new-tab": 1.04}}
        self.assertEqual(SWEEP.run5_bench_verdict(p95, 0, 0.05), ("pass", []))

    def test_target_sites_and_a_missing_base_fail(self) -> None:
        p95 = {"against": {"close": 2.5}, "ref": {"close": 2.1, "new-tab": 0.4}}
        verdict, problems = SWEEP.run5_bench_verdict(p95, 2, 0.05)
        self.assertEqual(verdict, "fail")
        self.assertEqual(
            problems,
            [
                'op="close" over target ref_p95=2.10 target=2.00',
                'op="new-tab" has no base measurement',
                "sites=2",
            ],
        )


if __name__ == "__main__":
    unittest.main()
