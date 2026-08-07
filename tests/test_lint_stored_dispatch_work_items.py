#!/usr/bin/env python3
"""Behavior tests for the deferred-action handle ownership scanner."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


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

    def test_audits_stored_task_handles_in_content_view(self) -> None:
        declarations = LINT.scan_declarations(
            """
            struct ContentView: View {
                @State private var fallbackTask: Task<Void, Never>?
                @State private var tasksByPanel: [String: Task<Void, Never>] = [:]
            }
            """,
            "Sources/ContentView.swift",
        )

        self.assertEqual(
            [(item.name, item.type_text, item.context) for item in declarations],
            [
                ("fallbackTask", "Task<Void,Never>?", "member:ContentView"),
                (
                    "tasksByPanel",
                    "[String:Task<Void,Never>]",
                    "member:ContentView",
                ),
            ],
        )

    def test_does_not_audit_stored_task_handles_outside_content_view(self) -> None:
        declarations = self.scan(
            """
            struct FixtureView: View {
                @State private var task: Task<Void, Never>?
            }
            """
        )

        self.assertEqual(declarations, [])

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


if __name__ == "__main__":
    unittest.main()
