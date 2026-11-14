#!/usr/bin/env python3
"""Regression tests for the short hard-timeout ratchet."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/check_short_timeouts.py"
SPEC = importlib.util.spec_from_file_location("short_timeout_guard", SCRIPT)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class ShortTimeoutGuardTests(unittest.TestCase):
    def test_checked_in_tree_matches_its_ratchet(self) -> None:
        allow = json.loads((ROOT / "tests/short-timeout-allowlist.json").read_text(encoding="utf-8"))
        found = guard.scan_tree(ROOT)
        problems = guard.problems(found, allow)
        guard.report_guard_checks(problems)
        self.assertEqual(problems, [])

    def test_each_problem_is_its_own_guard_check(self) -> None:
        import os
        from unittest import mock

        with tempfile.TemporaryDirectory() as tmp:
            results = Path(tmp) / "checks"
            errors = guard.problems({"a.rs:rust-duration": 3, "b.rs:rust-duration": 1},
                                    {"allow": {"a.rs:rust-duration": {"count": 2, "reason": "r"}}})
            with mock.patch.dict(os.environ, {guard.GUARD_CHECK_RESULTS_ENV: str(results)}):
                guard.report_guard_checks(errors)
            self.assertEqual(results.read_text().splitlines(), [
                "0\ta.rs:rust-duration: 3 hits, allowlist says 2; a new short timeout was added",
                "0\tb.rs:rust-duration: 1 new short timeout(s); add a reason or remove the timeout",
            ])
        with mock.patch.dict(os.environ, {guard.GUARD_CHECK_RESULTS_ENV: ""}):
            guard.report_guard_checks(errors)  # no results file: nothing to write, no error

    def test_new_two_second_deadline_fails_and_reasoned_comment_passes(self) -> None:
        source = "func request() { call(deadline: .seconds(2)) }\n"
        hits = guard.scan_source(
            source,
            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Request.swift",
        )
        self.assertEqual([(hit["pattern"], hit["line"]) for hit in hits], [("swift-duration", 1)])
        self.assertTrue(
            guard.problems(
                {"Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Request.swift:swift-duration": 1},
                {"allow": {}},
            )
        )

        for annotated in (
            "func request() { call(deadline: .seconds(2)) } // timeout: hung peer\n",
            "// timeout: hung peer\nfunc request() { call(deadline: .seconds(2)) }\n",
        ):
            with self.subTest(annotated=annotated):
                self.assertEqual(guard.scan_source(annotated, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Request.swift"), [])

        multiline = "func request() { call(\n  deadline: .milliseconds(1200)\n) }\n"
        self.assertEqual(
            [(hit["pattern"], hit["line"]) for hit in guard.scan_source(
                multiline,
                "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Request.swift",
            )],
            [("swift-duration", 2)],
        )

    def test_a_rust_pace_constant_beside_a_timeout_is_no_timeout(self) -> None:
        # A backoff step, a retry wait, a poll interval or a progress note is judged by its own name, not by the
        # TIMEOUT constant declared next to it; a pace name that also says TIMEOUT, BUDGET or DEADLINE still counts.
        rust = (
            "const LONG_WAIT: Duration = SCREENSHOT_TIMEOUT;\n"
            "const FIRST_NOTE_AFTER: Duration = Duration::from_secs(2);\n"
            "const RECONNECT_MAX_WAIT: Duration = Duration::from_secs(2);\n"
            "const POLL: Duration = Duration::from_secs(3);\n"
            "const RETRY_STOP_BUDGET: Duration = Duration::from_secs(1);\n"
            "const ANSWER_WAIT: Duration = Duration::from_secs(2);\n"
        )
        self.assertEqual(
            [hit["line"] for hit in guard.scan_source(rust, "cmux-tui/crates/acpmux/src/hub/start.rs")],
            [5, 6],
        )

    def test_a_rust_duration_limit_constant_is_a_deadline(self) -> None:
        # A Duration constant named a LIMIT is a deadline with no other deadline word near it
        # (cli/app/wait.rs RECONNECT_GONE_LIMIT); a usize LIMIT beside a pace is not one.
        path = "cmux-tui/crates/cmux-tui/src/cli/app/wait.rs"
        limit = "/// After this the app counts as quit.\nconst RECONNECT_GONE_LIMIT: Duration = Duration::from_secs(5);\n"
        self.assertEqual([(hit["pattern"], hit["line"]) for hit in guard.scan_source(limit, path)], [("rust-duration", 2)])
        reasoned = "// timeout: tells a quit app from a restarting one\nconst GONE_LIMIT: std::time::Duration = std::time::Duration::from_secs(5);\n"
        self.assertEqual(guard.scan_source(reasoned, path), [])
        count = "const MAX_LIMIT: usize = 200;\n/// How often to read.\nconst RECHECK: Duration = Duration::from_secs(1);\n"
        self.assertEqual(guard.scan_source(count, path), [])

    def test_other_language_patterns_and_test_module_exclusion(self) -> None:
        swift = "request.timeoutInterval = 2\nsetsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value)\n"
        self.assertEqual(
            [hit["pattern"] for hit in guard.scan_source(swift, "Packages/macOS/CmuxNext/Sources/CmuxNextApps/Socket.swift")],
            ["swift-timeoutInterval", "swift-socket-timeout"],
        )

        rust = (
            "const START_BUDGET: Duration = Duration::from_secs(2);\n"
            "async_fn.timeout(Duration::from_millis(10)).await;\n"
            "const SHORT_MILLIS: Duration = Duration::from_millis(1200);\n"
            "#[cfg(test)] mod tests { const TEST_TIMEOUT: Duration = Duration::from_secs(1); }\n"
        )
        self.assertEqual(
            [hit["pattern"] for hit in guard.scan_source(rust, "cmux-tui/crates/acpmux/src/hub/start.rs")],
            ["rust-duration", "rust-duration", "rust-duration"],
        )

        ts = (
            "const deadline = performance.now() + 2_000;\n"
            "const timeoutMs = 30_000;\n"
            "const TRUST_READ_TIMEOUT_MS = 1_500;\n"
        )
        self.assertEqual(
            [hit["pattern"] for hit in guard.scan_source(ts, "webviews/src/agent-session/acpmux/request.ts")],
            ["ts-hard-timeout", "ts-hard-timeout"],
        )

    def test_ratchet_rejects_new_raised_and_unshrunk_entries(self) -> None:
        allow = {"allow": {"a.swift:swift-duration": {"count": 2, "reason": "debt: old"}}}
        self.assertEqual(guard.problems({"a.swift:swift-duration": 2}, allow), [])
        self.assertTrue(guard.problems({"a.swift:swift-duration": 3}, allow))
        self.assertTrue(guard.problems({"a.swift:swift-duration": 1}, allow))
        self.assertTrue(guard.problems({"b.swift:swift-duration": 1}, allow))

    def test_update_writes_a_sorted_snapshot_and_preserves_reasons(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "allow.json"
            previous = {"allow": {"a.swift:swift-duration": {"count": 2, "reason": "safe: reviewed"}}}
            guard.update(path, {"a.swift:swift-duration": 1, "b.ts:ts-hard-timeout": 1}, previous)
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(list(data["allow"]), ["a.swift:swift-duration", "b.ts:ts-hard-timeout"])
            self.assertEqual(data["allow"]["a.swift:swift-duration"]["reason"], "safe: reviewed")


if __name__ == "__main__":
    unittest.main()
