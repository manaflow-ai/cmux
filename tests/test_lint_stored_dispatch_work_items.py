#!/usr/bin/env python3
"""Behavior tests for the deferred-action handle ownership scanner."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO_ROOT / "scripts" / "lint-stored-dispatch-work-items.py"
SPEC = importlib.util.spec_from_file_location("stored_work_item_lint", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
LINT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = LINT
SPEC.loader.exec_module(LINT)


class StoredDispatchWorkItemScannerTests(unittest.TestCase):
    def scan(self, source: str):
        return LINT.scan_declarations(source, "Sources/Fixture.swift")

    def test_finds_annotated_inferred_and_multiline_declarations(self) -> None:
        declarations = self.scan(
            """
            final class Owner {
                var annotated: DispatchWorkItem?
                var multiline:
                    [String: DispatchWorkItem] = [:]
                var generic:
                    Wrapper<DispatchWorkItem>
                var inferred = DispatchWorkItem {}
                var inferredArray = [DispatchWorkItem]()
                var inferredGenericArray = Array<DispatchWorkItem>()
                var inferredGenericDictionary = Dictionary<String, DispatchWorkItem>()
            }
            """
        )

        self.assertEqual(
            [(item.name, item.type_text) for item in declarations],
            [
                ("annotated", "DispatchWorkItem?"),
                ("multiline", "[String:DispatchWorkItem]"),
                ("generic", "Wrapper<DispatchWorkItem>"),
                ("inferred", "<inferred:DispatchWorkItem>"),
                ("inferredArray", "<inferred:[DispatchWorkItem]>"),
                ("inferredGenericArray", "<inferred:[DispatchWorkItem]>"),
                (
                    "inferredGenericDictionary",
                    "<inferred:[DispatchWorkItem]>",
                ),
            ],
        )

    def test_ignores_comments_and_strings(self) -> None:
        declarations = self.scan(
            r'''
            // var lineComment: DispatchWorkItem?
            /* var blockComment = DispatchWorkItem {} */
            /* outer /* var nestedComment: DispatchWorkItem? */ comment */
            let text = "var ordinaryString: DispatchWorkItem?"
            let raw = #"var rawString = DispatchWorkItem {}"#
            let multiline = """
            var multilineString: DispatchWorkItem?
            """
            '''
        )

        self.assertEqual(declarations, [])

    def test_interpolated_nested_strings_do_not_hide_following_declaration(self) -> None:
        declarations = self.scan(
            r'''
            final class Owner {
                let ordinary = "value: \(values["quoted\"key"] ?? "fallback")"
                let raw = #"value: \#(values["key"] ?? "fallback")"#
                private var timeout: DispatchWorkItem?
            }
            '''
        )

        self.assertEqual(
            [(item.name, item.type_text) for item in declarations],
            [("timeout", "DispatchWorkItem?")],
        )

    def test_context_distinguishes_member_from_function_local(self) -> None:
        declarations = self.scan(
            """
            final class Owner {
                var member: DispatchWorkItem?

                func schedule() {
                    var local: DispatchWorkItem?
                }
            }
            """
        )

        self.assertEqual(
            [(item.name, item.context) for item in declarations],
            [
                ("member", "member:Owner"),
                ("local", "local:Owner.schedule"),
            ],
        )

    def test_backtick_identifiers_do_not_create_keyword_scopes(self) -> None:
        declarations = self.scan(
            """
            final class Owner {
                func schedule(`class`: Int) {
                    var local: DispatchWorkItem?
                }
            }
            """
        )

        self.assertEqual(
            [(item.name, item.context) for item in declarations],
            [("local", "local:Owner.schedule")],
        )

    def test_ignores_computed_properties_but_keeps_stored_observers(self) -> None:
        declarations = self.scan(
            """
            final class Owner {
                var shorthand: DispatchWorkItem? { nil }
                var accessor: DispatchWorkItem? {
                    get { nil }
                }
                var observed: DispatchWorkItem? = nil {
                    didSet {}
                }
            }
            """
        )

        self.assertEqual(
            [(item.name, item.type_text) for item in declarations],
            [("observed", "DispatchWorkItem?")],
        )

    def test_comparison_initializer_does_not_consume_following_declaration(self) -> None:
        declarations = self.scan(
            """
            final class Owner {
                var isLarge = count < limit
                var timeout: DispatchWorkItem?
            }
            """
        )

        self.assertEqual(
            [(item.name, item.type_text) for item in declarations],
            [("timeout", "DispatchWorkItem?")],
        )

    def test_inferred_dictionary_colon_is_not_a_type_annotation(self) -> None:
        declarations = self.scan(
            """
            final class Owner {
                var workByName = ["refresh": DispatchWorkItem {}]
            }
            """
        )

        self.assertEqual(
            [(item.name, item.type_text) for item in declarations],
            [("workByName", "<inferred:[DispatchWorkItem]>")],
        )

    def test_audits_stored_async_handles_in_macos_swiftui_state(self) -> None:
        declarations = LINT.scan_declarations(
            """
            struct FixtureView: View {
                @State
                private var fallbackTask: Task<Void, Never>?
                @State private var tasksByPanel: [String: Task<Void, Never>] = [:]
                @State private var expiryTimer: DispatchSourceTimer?
                @State private var feedbackTimer: Timer?
            }
            """,
            "Sources/FixtureView.swift",
        )

        self.assertEqual(
            [(item.name, item.type_text, item.context) for item in declarations],
            [
                ("fallbackTask", "Task<Void,Never>?", "member:FixtureView"),
                (
                    "tasksByPanel",
                    "[String:Task<Void,Never>]",
                    "member:FixtureView",
                ),
                (
                    "expiryTimer",
                    "DispatchSourceTimer?",
                    "member:FixtureView",
                ),
                (
                    "feedbackTimer",
                    "Timer?",
                    "member:FixtureView",
                ),
            ],
        )

    def test_audits_inferred_async_handles_in_macos_swiftui_state(self) -> None:
        declarations = LINT.scan_declarations(
            """
            struct FixtureView: View {
                @State private var task = Task {}
                @State private var detachedTask = Task.detached {}
                @State private var taskArray = [Task<Void, Never>]()
                @State private var taskDictionary = Dictionary<String, Task<Void, Never>>()
                @State private var timer = DispatchSource.makeTimerSource(queue: .main)
                @State private var feedback = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in }
                @State private var feedbackTimers = Array<Timer>()
            }
            """,
            "Packages/macOS/Fixture/Sources/Fixture/FixtureView.swift",
        )

        self.assertEqual(
            [(item.name, item.type_text, item.context) for item in declarations],
            [
                ("task", "<inferred:Task>", "member:FixtureView"),
                ("detachedTask", "<inferred:Task>", "member:FixtureView"),
                ("taskArray", "<inferred:[Task]>", "member:FixtureView"),
                (
                    "taskDictionary",
                    "<inferred:[Task]>",
                    "member:FixtureView",
                ),
                (
                    "timer",
                    "<inferred:DispatchSourceTimer>",
                    "member:FixtureView",
                ),
                (
                    "feedback",
                    "<inferred:Timer>",
                    "member:FixtureView",
                ),
                (
                    "feedbackTimers",
                    "<inferred:[Timer]>",
                    "member:FixtureView",
                ),
            ],
        )

    def test_audits_async_state_handles_in_shared_macos_packages(self) -> None:
        declarations = LINT.scan_declarations(
            """
            struct SharedFixtureView: View {
                @State private var refreshTask: Task<Void, Never>?
            }
            """,
            "Packages/Shared/Fixture/Sources/Fixture/SharedFixtureView.swift",
        )

        self.assertEqual(
            [(item.name, item.type_text, item.context) for item in declarations],
            [
                (
                    "refreshTask",
                    "Task<Void,Never>?",
                    "member:SharedFixtureView",
                )
            ],
        )

    def test_does_not_audit_non_state_or_ios_async_handles(self) -> None:
        declarations = LINT.scan_declarations(
            """
            struct FixtureView: View {
                private var task: Task<Void, Never>?
                private var timer: DispatchSourceTimer?
            }
            """,
            "Sources/FixtureView.swift",
        )
        ios_declarations = LINT.scan_declarations(
            """
            struct FixtureView: View {
                @State private var task: Task<Void, Never>?
            }
            """,
            "Packages/iOS/Fixture/Sources/Fixture/FixtureView.swift",
        )

        self.assertEqual(declarations, [])
        self.assertEqual(ios_declarations, [])

    def test_allowance_comparison_rejects_changed_ownership_and_stale_entries(self) -> None:
        allowance = LINT.Allowance(
            "Sources/Fixture.swift",
            "timeout",
            "DispatchWorkItem?",
            "local:Owner.schedule",
            1,
            "fixture",
        )
        moved_to_member = LINT.Declaration(
            "Sources/Fixture.swift",
            "timeout",
            "DispatchWorkItem?",
            "member:Owner",
            1,
        )

        unexpected, stale = LINT.compare_allowances([moved_to_member], (allowance,))

        self.assertEqual(unexpected, {moved_to_member.key: 1})
        self.assertEqual(
            stale,
            {
                (
                    allowance.path,
                    allowance.name,
                    allowance.type_text,
                    allowance.context,
                ): 1
            },
        )

    def test_missing_bonsplit_source_root_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing_root = Path(directory) / "missing-bonsplit-sources"
            stderr = io.StringIO()
            with mock.patch.object(LINT, "BONSPLIT_SOURCES_ROOT", missing_root):
                with contextlib.redirect_stderr(stderr):
                    result = LINT.main()

        self.assertEqual(result, 1)
        self.assertIn("required audited source root is missing", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
