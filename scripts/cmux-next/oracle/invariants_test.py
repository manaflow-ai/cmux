#!/usr/bin/env python3
"""Tests for I16 (invariants.py) and the daemon driver's I16 hooks (driver_daemon.py).

Run: python3 -I scripts/cmux-next/oracle/invariants_test.py (stdlib unittest).
The panic lines have the cmux-panic-log record shape (cmux-tui/crates/cmux-panic-log/src/lib.rs
`record`); the lock-rank message is lock_rank.rs held::check's text.
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import driver_daemon  # noqa: E402
import invariants  # noqa: E402

LOCK_RANK_MESSAGE = (
    "lock order violation: acquiring mux.state (MuxState) while this thread holds pty.term (Terminal); "
    "the order is workspace.registry > journal.writer > registry.connection > mux.state > "
    "pty.kitty_limits_request > pty.geometry > pty.term > pty.runtime > pty.kitty_graphics_limits > "
    "pty.taps > leaf (see PtyTerminalRuntime)"
)


def panic_record(message: str, location: str, thread: str = "mux-worker", test: bool = False) -> str:
    return json.dumps(
        {
            "session": "oracle",
            "owner_pid": 4242,
            "message": message,
            "location": location,
            "thread": thread,
            "at_ms": 1,
            "test": test,
            "backtrace": "   0: std::backtrace::Backtrace::force_capture\n",
        }
    )


class CaseRoot:
    """A case root laid out like the hermetic env: HOME and the owner's state under it."""

    def __init__(self, tmp: str) -> None:
        self.root = Path(tmp) / "c00001"
        self.state = self.root / "home" / ".local" / "state" / "cmux-tui"
        (self.state / "sessions").mkdir(parents=True)
        self.acpmux = self.root / "home" / ".acpmux"
        self.acpmux.mkdir(parents=True)

    def owner_log(self, *lines: str) -> Path:
        path = self.state / "owner-panics-oracle.jsonl"
        path.write_text("".join(line + "\n" for line in lines))
        return path


class I16Test(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.case = CaseRoot(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_no_log_holds(self) -> None:
        self.assertEqual(invariants.check_i16(self.case.root), [])

    def test_empty_log_and_memory_log_hold(self) -> None:
        self.case.owner_log()
        (self.case.state / "owner-memory-oracle.jsonl").write_text('{"memory_bytes": 1}\n')
        self.assertEqual(invariants.check_i16(self.case.root), [])

    def test_panic_line_fails_with_message_and_location(self) -> None:
        self.case.owner_log(panic_record("index out of bounds: the len is 2 but the index is 5", "crates/cmux-tui-core/src/layout.rs:812:17"))
        [violation] = invariants.check_i16(self.case.root)
        self.assertEqual(violation.id, "I16")
        self.assertEqual(violation.kind, "panic")
        self.assertEqual(violation.location, "crates/cmux-tui-core/src/layout.rs:812:17")
        self.assertIn("index out of bounds", violation.message)
        self.assertIn("thread 'mux-worker'", violation.message)
        self.assertEqual(violation.pointer, "/daemon/panicLog/home~1.local~1state~1cmux-tui~1owner-panics-oracle.jsonl/1")

    def test_lock_rank_panic_is_its_own_kind(self) -> None:
        self.case.owner_log(panic_record(LOCK_RANK_MESSAGE, "crates/cmux-tui-core/src/mux.rs:301:28"))
        [violation] = invariants.check_i16(self.case.root)
        self.assertEqual(violation.kind, "lock-rank")
        self.assertIn("I16 lock-rank at crates/cmux-tui-core/src/mux.rs:301:28: lock order violation", violation.text())

    def test_every_line_of_every_log_is_reported(self) -> None:
        self.case.owner_log(panic_record("first", "a.rs:1:1"), "", panic_record("second", "b.rs:2:2", test=True))
        (self.case.acpmux / "panics.jsonl").write_text(panic_record("acp", "c.rs:3:3") + "\n")
        violations = invariants.check_i16(self.case.root)
        self.assertEqual([v.location for v in violations], ["c.rs:3:3", "a.rs:1:1", "b.rs:2:2"])
        self.assertEqual(violations[2].pointer.rsplit("/", 1)[1], "3")
        self.assertIn("debug test trigger", violations[2].message)

    def test_unparseable_line_is_a_violation(self) -> None:
        self.case.owner_log('{"message": "cut')
        [violation] = invariants.check_i16(self.case.root)
        self.assertEqual(violation.location, "")
        self.assertIn("is not a panic log record", violation.message)

    def test_symlinked_log_is_not_followed(self) -> None:
        elsewhere = Path(self.tmp.name) / "other-case"
        elsewhere.mkdir()
        (elsewhere / "owner-panics-x.jsonl").write_text(panic_record("not ours", "x.rs:1:1") + "\n")
        (self.case.state / "owner-panics-x.jsonl").symlink_to(elsewhere / "owner-panics-x.jsonl")
        (self.case.root / "linked").symlink_to(elsewhere, target_is_directory=True)
        self.assertEqual(invariants.check_i16(self.case.root), [])

    def test_missing_case_root_is_an_error(self) -> None:
        with self.assertRaises(FileNotFoundError):
            invariants.check_i16(self.case.root / "missing")

    def test_cli_exit_codes(self) -> None:
        with redirect_stdout(io.StringIO()):
            self.assertEqual(invariants.main(["i16", str(self.case.root)]), 0)
        self.case.owner_log(panic_record("boom", "a.rs:1:1"))
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(invariants.main(["i16", str(self.case.root), "--json"]), 1)
        [row] = json.loads(out.getvalue())
        self.assertEqual((row["id"], row["location"], row["kind"]), ("I16", "a.rs:1:1", "panic"))


class LockRankBinaryTest(unittest.TestCase):
    def test_marker_found_across_chunk_boundary(self) -> None:
        needle = invariants.LOCK_RANK_PANIC_PREFIX.encode()
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "cmux-tui"
            for split in range(1, len(needle)):
                binary.write_bytes(b"\0" * (64 - split) + needle + b"{name} (")
                self.assertTrue(invariants.lock_ranks_compiled_in(binary, chunk_size=64), split)
            binary.write_bytes(b"\0" * 200 + needle[:-1] + b"\0")
            self.assertFalse(invariants.lock_ranks_compiled_in(binary, chunk_size=64))

    def test_driver_refuses_binary_without_ranks(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "cmux-tui"
            binary.write_bytes(b"\x7fELF release build")
            with self.assertRaisesRegex(driver_daemon.DriverError, "no lock-rank checker"):
                driver_daemon.require_lock_ranks(binary)
            binary.write_bytes(b"\x7fELF oracle build " + invariants.LOCK_RANK_PANIC_PREFIX.encode() + b"tail")
            driver_daemon.require_lock_ranks(binary)
            with self.assertRaisesRegex(driver_daemon.DriverError, "cannot read"):
                driver_daemon.require_lock_ranks(Path(tmp) / "missing")


class DriverI16Test(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.case = CaseRoot(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_clean_case_keeps_its_result(self) -> None:
        result = {"status": "Pass", "checkpoints": [], "message": ""}
        self.assertIs(driver_daemon.finish_case(result, self.case.root), result)

    def test_pass_with_panic_becomes_failure_naming_message_and_location(self) -> None:
        self.case.owner_log(panic_record(LOCK_RANK_MESSAGE, "crates/cmux-tui-core/src/mux.rs:301:28"))
        result = driver_daemon.finish_case({"status": "Pass", "checkpoints": [], "message": ""}, self.case.root)
        self.assertEqual(result["status"], "Failure")
        self.assertTrue(result["message"].startswith("I16 lock-rank at crates/cmux-tui-core/src/mux.rs:301:28: lock order violation"))
        self.assertEqual(result["invariants"][0]["pointer"].split("/")[1:3], ["daemon", "panicLog"])

    def test_crash_keeps_status_and_gains_the_panic(self) -> None:
        self.case.owner_log(panic_record("called `Option::unwrap()` on a `None` value", "src/main.rs:9:5", thread="main"))
        result = driver_daemon.finish_case({"status": "Crash", "message": "daemon exited 101", "step": "s2"}, self.case.root)
        self.assertEqual((result["status"], result["step"]), ("Crash", "s2"))
        self.assertEqual(result["message"].split("; ")[0], "daemon exited 101")
        self.assertIn("src/main.rs:9:5", result["message"])

    def test_panic_logs_must_resolve_inside_the_case_root(self) -> None:
        home = self.case.root / "home"
        driver_daemon.require_case_local_panic_logs({"HOME": str(home)}, self.case.root, system="Linux")
        driver_daemon.require_case_local_panic_logs({"HOME": str(home)}, self.case.root, system="Darwin")
        driver_daemon.require_case_local_panic_logs(
            {"HOME": str(home), "CMUX_TUI_STATE_DIR": str(self.case.root / "state" / "sessions")}, self.case.root
        )
        # A state dir at the case root itself puts the owner log in the run dir, shared by cases.
        with self.assertRaisesRegex(driver_daemon.DriverError, "outside the case root"):
            driver_daemon.require_case_local_panic_logs(
                {"HOME": str(home), "CMUX_TUI_STATE_DIR": str(self.case.root)}, self.case.root
            )
        with self.assertRaisesRegex(driver_daemon.DriverError, "outside the case root"):
            driver_daemon.require_case_local_panic_logs(
                {"HOME": str(home), "ACPMUX_HOME": str(Path(self.tmp.name) / "shared")}, self.case.root
            )
        with self.assertRaisesRegex(driver_daemon.DriverError, "no home"):
            driver_daemon.require_case_local_panic_logs({}, self.case.root)

    def test_owner_log_dir_matches_the_rust_resolution(self) -> None:
        home = Path("/tmp/o/r/c/home")
        self.assertEqual(
            driver_daemon.panic_log_dirs({"HOME": str(home)}, system="Linux"),
            [home / ".local" / "state" / "cmux-tui", home / ".acpmux"],
        )
        self.assertEqual(
            driver_daemon.panic_log_dirs({"HOME": str(home), "XDG_STATE_HOME": "/tmp/o/r/c/xdg"}, system="Linux")[0],
            Path("/tmp/o/r/c/xdg/cmux-tui"),
        )
        self.assertEqual(
            driver_daemon.panic_log_dirs({"HOME": str(home)}, system="Darwin")[0],
            home / "Library" / "Application Support" / "cmux-tui",
        )

    def test_open_session_names_the_session_task(self) -> None:
        with self.assertRaisesRegex(driver_daemon.DriverError, "p15-oracle-023"):
            driver_daemon.open_session({})


if __name__ == "__main__":
    unittest.main()
