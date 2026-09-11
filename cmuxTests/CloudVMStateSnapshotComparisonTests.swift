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

    @Test("Live terminal geometry can change without changing the resource revision")
    func terminalResizeDoesNotInvalidateTheGraph() throws {
        var object = snapshot()
        object["terminals"] = [["id": "term-1", "running": true, "lifecycle": "running", "cols": 80, "rows": 24]]
        let before = try state(object)
        object["terminals"] = [["id": "term-1", "running": true, "lifecycle": "running", "cols": 120, "rows": 40]]
        let after = try state(object)
        #expect(before != after)
        #expect(before.hasSameRevisionedContent(as: after))
        object["terminals"] = [["id": "term-1", "running": true, "lifecycle": "running", "cols": 120, "rows": 40, "future_field": "changed"]]
        #expect(try !before.hasSameRevisionedContent(as: state(object)))
    }

    @Test("PTY title updates remain live observations while launch identity stays strict")
    func terminalTitleDoesNotInvalidateTheGraph() throws {
        var object = snapshot()
        object["terminals"] = [["id": "term-1", "running": true, "lifecycle": "running", "title": "bash", "cwd": "/home/cmux"]]
        let before = try state(object)
        object["terminals"] = [["id": "term-1", "running": true, "lifecycle": "running", "title": "vim", "cwd": "/home/cmux"]]
        let after = try state(object)
        #expect(before != after)
        #expect(before.hasSameRevisionedContent(as: after))
        object["terminals"] = [["id": "term-1", "running": true, "lifecycle": "running", "title": "vim", "cwd": "/different-launch"]]
        #expect(try !before.hasSameRevisionedContent(as: state(object)))
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

    @Test("Applying a delta keeps the session revision aligned with its cursor", arguments: [false, true])
    func deltaAdvancesBothRevisionRepresentations(legacyNumeric: Bool) throws {
        var object = snapshot()
        object["session"] = ["id": "session-1", "revision": legacyNumeric ? (2 as Any) : "2", "name": "Kept"]
        var document = CloudVMStateDocument(snapshot: object)
        let advanced = document.setCursor(CloudVMCursor(generation: "daemon-1", revision: 3))
        #expect(advanced)
        let session = try #require(document.value(forKey: "session") as? [String: Any])
        #expect(CloudWireNumber.unsigned(session["revision"]) == 3)
        #expect(session["name"] as? String == "Kept")
        #expect((session["revision"] is String) == !legacyNumeric)
    }

    @Test("A legacy document without a session object does not gain one")
    func deltaDoesNotInventASessionRecord() {
        var document = CloudVMStateDocument(snapshot: snapshot())
        let advanced = document.setCursor(CloudVMCursor(generation: "daemon-1", revision: 3))
        #expect(advanced)
        #expect(document.value(forKey: "session") == nil)
    }
}
