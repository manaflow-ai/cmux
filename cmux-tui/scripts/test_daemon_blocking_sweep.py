#!/usr/bin/env python3
"""Tests for daemon-blocking-sweep.py: the MQ-13 grouping and the RUN-5 panic count."""

from __future__ import annotations

import importlib.util
import io
import json
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
                        line(1, "crates/cmux-threads/tests/blocking_panic.rs", 4, "fs", "t", "panic"),
                    ]
                )
                + "\n"
            )
            # A second process, and a torn last line from a killed one.
            (root / "blocking-2.jsonl").write_text(
                line(2, server, 10, "fs", "mux-conn") + "\n" + '{"pid":2,"thr'
            )
            with redirect_stdout(io.StringIO()) as out, redirect_stderr(io.StringIO()) as err:
                rows = SWEEP.summarize(root)
            self.assertIn("torn line blocking-2.jsonl:2", err.getvalue())
            self.assertEqual(
                [(r["location"], r["kind"], r["processes"], r["fixture"]) for r in rows],
                [
                    (f"{server}:10:9", "fs", 2, False),
                    (f"{server}:10:9", "sqlite", 1, False),
                    ("crates/cmux-threads/tests/blocking_panic.rs:4:9", "fs", 1, True),
                ],
            )
            self.assertIn("tasks=2 fixtures=1", out.getvalue())
            self.assertEqual(json.loads((root / "sites.json").read_text()), rows)

    def test_fixture_paths_and_threads(self) -> None:
        self.assertTrue(SWEEP.is_fixture("crates/a/tests/x.rs", "mux-conn"))
        self.assertTrue(SWEEP.is_fixture("crates/a/src/server/tests.rs", "mux-conn"))
        self.assertTrue(SWEEP.is_fixture("crates/a/src/request_path_tests.rs", "mux-conn"))
        self.assertFalse(SWEEP.is_fixture("crates/a/src/server/listen.rs", "mux-conn"))
        self.assertFalse(SWEEP.is_fixture("crates/a/src/latests.rs", "mux-line-out"))
        # Threads a test made: unnamed, libtest's own, or named for a test.
        self.assertTrue(SWEEP.is_fixture("crates/a/src/checked.rs", "<unnamed>"))
        self.assertTrue(SWEEP.is_fixture("crates/a/src/checked.rs", "checked::tests::recv"))
        self.assertTrue(SWEEP.is_fixture("crates/a/src/blocking.rs", "blocking-test"))


class PanicCountTests(unittest.TestCase):
    def test_totals_sum_every_test_binary(self) -> None:
        log = (
            "test result: ok. 48 passed; 0 failed; 1 ignored; 0 measured\n"
            "test result: FAILED. 3 passed; 2 failed; 0 ignored; 0 measured\n"
        )
        self.assertEqual(SWEEP.test_totals(log), (51, 2))

    def test_counts_distinct_non_fixture_panics(self) -> None:
        log = "\n".join(
            [
                "thread 'mux-conn' panicked at crates/cmux-threads/src/blocking.rs:350:5:",
                "cmux_threads: blocking call (fs) at crates/cmux-tui-core/src/mux/a.rs:7:13 on thread 'mux-conn', which disallows blocking",
                "cmux_threads: blocking call (fs) at crates/cmux-tui-core/src/mux/a.rs:7:13 on thread 'mux-conn', which disallows blocking",
                "cmux_threads: blocking call (sqlite) at crates/cmux-tui-core/tests/registry_blocking_panic.rs:20:5 on thread 'x', which disallows blocking",
            ]
        )
        self.assertEqual(
            SWEEP.blocking_panics(log),
            [("fs", "crates/cmux-tui-core/src/mux/a.rs:7:13", "mux-conn")],
        )


if __name__ == "__main__":
    unittest.main()
