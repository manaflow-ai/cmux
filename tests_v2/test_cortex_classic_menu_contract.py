#!/usr/bin/env python3
"""Compile the actual typed native-menu presentation contract."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CmuxSidebarClassicMenu.swift"

class NativeMenuContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        path = Path(cls.temporary.name)
        harness = path / "main.swift"
        harness.write_text(r"""import Foundation
let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
let requests: [CmuxSidebarClassicMenuAction] = [
    .presentWorkspaceMenu(workspaceID: id, selectedWorkspaceIDs: [id, second]),
    .presentGroupMenu(groupID: second)]
let encoder = JSONEncoder(); let decoder = JSONDecoder()
var roundTrip = true
for request in requests {
    let decoded = try decoder.decode(CmuxSidebarClassicMenuAction.self, from: encoder.encode(request))
    roundTrip = roundTrip && decoded == request
}
let rawCommand = Data(#"{"executeCommand":{"command":"arbitrary shell"}}"#.utf8)
let selectsItem = Data(#"{"selectMenuItem":{"item":"Close Workspace"}}"#.utf8)
let scopes = requests.map { Array($0.requiredActionScopeNames).sorted() }
let result: [String: Any] = ["roundTrip":roundTrip, "scopes":scopes,
    "rejectsCommand": (try? decoder.decode(CmuxSidebarClassicMenuAction.self, from: rawCommand)) == nil,
    "rejectsItemSelection": (try? decoder.decode(CmuxSidebarClassicMenuAction.self, from: selectsItem)) == nil]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
""")
        binary = path / "contract"
        subprocess.run(["swiftc", str(SOURCE), str(harness), "-o", str(binary)], check=True)
        cls.result = json.loads(subprocess.run([str(binary)], check=True, capture_output=True, text=True).stdout)
    @classmethod
    def tearDownClass(cls): cls.temporary.cleanup()
    def test_workspace_and_group_roundtrip_preserve_exact_ids(self): self.assertTrue(self.result["roundTrip"])
    def test_only_explicit_native_presentation_scope_is_declared(self):
        self.assertEqual(self.result["scopes"], [["presentNativeSidebarMenu"], ["presentNativeSidebarMenu"]])
    def test_arbitrary_commands_are_not_part_of_transport(self): self.assertTrue(self.result["rejectsCommand"])
    def test_extension_cannot_choose_a_native_menu_item(self): self.assertTrue(self.result["rejectsItemSelection"])

if __name__ == "__main__": unittest.main()
