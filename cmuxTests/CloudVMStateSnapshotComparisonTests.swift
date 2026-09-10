import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CloudVMStateSnapshotComparisonTests {
    private func snapshot() -> [String: Any] {
        [
            "cursor": ["generation": "daemon-1", "revision": "2"],
            "workspaces": [["id": "ws-1", "name": "Original", "focused": true]],
            "screens": [], "panes": [], "tabs": [], "terminals": [], "browsers": [], "agents": [],
            "clients": [["id": "client-1", "connected_seconds": 1]]
        ]
    }

    private func state(_ object: [String: Any]) throws -> CloudVMState {
        try #require(CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: .cloud("vm-test")))
    }

    @Test("Connection age and request-client churn do not invalidate a session revision")
    func volatileClientsDoNotMakeAnUnchangedGraphStale() throws {
        let before = try state(snapshot())
        var changed = snapshot()
        changed["clients"] = [
            ["id": "client-1", "connected_seconds": 45],
            ["id": "snapshot-reader", "connected_seconds": 0]
        ]
        let after = try state(changed)

        #expect(before != after, "Diagnostics must remain in the complete exported document")
        #expect(before.hasSameRevisionedContent(as: after))
    }

    @Test("Actual same-cursor conflicts remain rejected", arguments: ["workspaces", "terminals", "future_resources", "cursor"])
    func graphChangesRemainConflicts(field: String) throws {
        let before = try state(snapshot())
        var changed = snapshot()
        switch field {
        case "workspaces": changed[field] = [["id": "ws-1", "name": "Changed", "focused": true]]
        case "terminals": changed[field] = [["id": "term-new", "running": true, "lifecycle": "running"]]
        case "cursor": changed[field] = ["generation": "daemon-1", "revision": "3"]
        default: changed[field] = [["id": "future-1", "value": "changed"]]
        }
        #expect(try !before.hasSameRevisionedContent(as: state(changed)))
    }
}
