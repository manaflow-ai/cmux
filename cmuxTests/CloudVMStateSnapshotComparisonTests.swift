import CmuxSurfaceCatalogModel
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

    @Test("Session transport metadata does not reject an equal-cursor refresh")
    func sessionEnvelopeChurnDoesNotInvalidateRevision() throws {
        var first = snapshot()
        first["session"] = ["name": "cmux", "connected_seconds": 1]
        var second = snapshot()
        second["session"] = ["name": "cmux", "connected_seconds": 44, "client_count": 2]
        let before = try state(first)
        let after = try state(second)
        #expect(before != after)
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

    @Test("Closing a tab does not make the same-revision full snapshot stale", arguments: [true, false])
    func legacyDetachedTerminalLifecycleMatchesFullSnapshot(running: Bool) throws {
        var object = snapshot()
        // Older daemon tab.close deltas omit lifecycle while retaining running.
        object["terminals"] = [["id": "term-detached", "running": running,
                                "tab_id": NSNull(), "tab_ids": [], "cwd": "/home/cmux"]]
        let fromDelta = try state(object)
        var fullTerminal = try #require((object["terminals"] as? [[String: Any]])?.first)
        fullTerminal["lifecycle"] = running ? "running" : "exited"
        object["terminals"] = [fullTerminal]
        let fullSnapshot = try state(object)
        #expect(fromDelta != fullSnapshot, "The exported wire documents stay lossless")
        #expect(fromDelta.hasSameRevisionedContent(as: fullSnapshot))
        #expect(fullSnapshot.hasSameRevisionedContent(as: fromDelta))

        fullTerminal["lifecycle"] = "launching"
        object["terminals"] = [fullTerminal]
        #expect(try !fromDelta.hasSameRevisionedContent(as: state(object)))
        fullTerminal["lifecycle"] = running ? "running" : "exited"
        fullTerminal["future_field"] = "changed"
        object["terminals"] = [fullTerminal]
        #expect(try !fromDelta.hasSameRevisionedContent(as: state(object)))
    }

    @Test("Delta insertion order and full-snapshot resource order describe the same graph")
    func resourceWireOrderDoesNotInvalidateTheGraph() throws {
        var object = snapshot()
        object["workspaces"] = [
            ["id": "ws-a", "name": "A", "index": 0],
            ["id": "ws-b", "name": "B", "index": 1],
        ]
        object["screens"] = [
            ["id": "screen-a", "workspace_id": "ws-a", "index": 0],
            ["id": "screen-b", "workspace_id": "ws-b", "index": 0],
        ]
        object["panes"] = [
            ["id": "pane-a", "screen_id": "screen-a"],
            ["id": "pane-b", "screen_id": "screen-b"],
        ]
        let first: [String: Any] = ["id": "tab-a0", "pane_id": "pane-a", "index": 0,
                                    "content_kind": "terminal", "content_id": "term-a0"]
        let other: [String: Any] = ["id": "tab-b0", "pane_id": "pane-b", "index": 0,
                                    "content_kind": "terminal", "content_id": "term-b0"]
        let appended: [String: Any] = ["id": "tab-a1", "pane_id": "pane-a", "index": 1,
                                       "content_kind": "terminal", "content_id": "term-a1"]
        object["tabs"] = [first, other, appended]
        object["terminals"] = ["term-a0", "term-b0", "term-a1"].map {
            ["id": $0, "running": true, "lifecycle": "running"] as [String: Any]
        }
        let fromDeltas = try state(object)

        object["tabs"] = [first, appended, other]
        object["terminals"] = ["term-a0", "term-a1", "term-b0"].map {
            ["id": $0, "running": true, "lifecycle": "running"] as [String: Any]
        }
        for key in ["workspaces", "screens", "panes"] {
            let rows = try #require(object[key] as? [[String: Any]])
            object[key] = Array(rows.reversed())
        }
        let fullSnapshot = try state(object)
        #expect(fromDeltas != fullSnapshot, "Exports retain their original wire order")
        #expect(fromDeltas.hasSameRevisionedContent(as: fullSnapshot))
        #expect(fullSnapshot.hasSameRevisionedContent(as: fromDeltas))

        var reordered = appended
        reordered["index"] = 0
        object["tabs"] = [first, reordered, other]
        #expect(try !fromDeltas.hasSameRevisionedContent(as: state(object)), "Semantic tab order stays strict")
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
