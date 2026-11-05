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
        self.assertEqual(guard.problems(found, allow), [])

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
