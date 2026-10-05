#!/usr/bin/env python3
"""Portable behavioral proof for shared context-menu target capture.

This compiles the real Foundation-only planner without starting CMUX or
touching the user's windows. The app/ExtensionKit entrypoint canary remains
separate and must run against the exact tagged pair after integration.
"""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "Sources/SidebarClassicMenuParity.swift"
HARNESS = r'''
import Foundation

let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
let d = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
let x = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
let order = [a, b, c, d]
func labels(_ ids: [UUID]) -> [Int] {
    ids.map { Int($0.uuidString.suffix(1))! }
}
var result: [String: Any] = [:]
let selected = SidebarClassicMenuParity(nativeOrder: order, anchorID: b,
    selectedWorkspaceIDs: [d, b, b, x])!
result["selection"] = labels(selected.selectedWorkspaceIDs)
for operation in SidebarClassicMenuParity.CloseSelection.allCases {
    result[operation.rawValue] = labels(selected.closePlan(operation).workspaceIDs)
}
let captured = selected.closePlan(.below)
result["afterReorderAndInsertion"] = labels(captured.survivingWorkspaceIDs(in: [x, d, a, c, b]))
result["afterClosedTarget"] = labels(captured.survivingWorkspaceIDs(in: [x, a, b, d]))
let outside = SidebarClassicMenuParity(nativeOrder: order, anchorID: c, selectedWorkspaceIDs: [a, b])!
result["outsideSelection"] = labels(outside.selectedWorkspaceIDs)
result["firstAboveEnabled"] = SidebarClassicMenuParity(nativeOrder: order, anchorID: a,
    selectedWorkspaceIDs: [])!.canClose(.above)
result["lastBelowEnabled"] = SidebarClassicMenuParity(nativeOrder: order, anchorID: d,
    selectedWorkspaceIDs: [])!.canClose(.below)
result["allSelectedOthersEnabled"] = SidebarClassicMenuParity(nativeOrder: order, anchorID: a,
    selectedWorkspaceIDs: order)!.canClose(.others)
result["missingAnchorRejected"] = SidebarClassicMenuParity(nativeOrder: order, anchorID: x,
    selectedWorkspaceIDs: [x]) == nil
result["duplicateNativeOrderRejected"] = SidebarClassicMenuParity(nativeOrder: [a, a], anchorID: a,
    selectedWorkspaceIDs: [a]) == nil
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''


class ClassicMenuTargetCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("swiftc")
        if compiler is None:
            raise RuntimeError("swiftc is required; skipped tests are not a parity proof")
        with tempfile.TemporaryDirectory(prefix="cortex-menu-parity-") as directory:
            scratch = Path(directory)
            harness = scratch / "main.swift"
            harness.write_text(HARNESS)
            binary = scratch / "parity"
            subprocess.run([compiler, str(SOURCE), str(harness), "-o", str(binary)],
                           check=True, capture_output=True, text=True, timeout=120)
            run = subprocess.run([str(binary)], check=True, capture_output=True,
                                 text=True, timeout=10)
            cls.actual = json.loads(run.stdout)

    def test_multi_selection_is_native_ordered_and_deduplicated(self):
        self.assertEqual(self.actual["selection"], [2, 4])
        self.assertEqual(self.actual["selected"], [2, 4])

    def test_close_others_keeps_every_selected_workspace(self):
        self.assertEqual(self.actual["others"], [1, 3])

    def test_relative_close_uses_native_order_even_across_groups(self):
        self.assertEqual(self.actual["above"], [1])
        self.assertEqual(self.actual["below"], [3, 4])

    def test_confirmation_cannot_capture_new_or_reordered_workspaces(self):
        self.assertEqual(self.actual["afterReorderAndInsertion"], [3, 4])
        self.assertEqual(self.actual["afterClosedTarget"], [4])

    def test_context_click_outside_selection_targets_clicked_workspace(self):
        self.assertEqual(self.actual["outsideSelection"], [3])

    def test_boundary_actions_are_disabled(self):
        for key in ["firstAboveEnabled", "lastBelowEnabled", "allSelectedOthersEnabled"]:
            self.assertFalse(self.actual[key], key)

    def test_invalid_native_identity_is_rejected(self):
        self.assertTrue(self.actual["missingAnchorRejected"])
        self.assertTrue(self.actual["duplicateNativeOrderRejected"])


if __name__ == "__main__":
    unittest.main()
