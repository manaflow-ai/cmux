#!/usr/bin/env python3
"""Behavior tests for the stored DispatchWorkItem ownership scanner."""

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


if __name__ == "__main__":
    unittest.main()
