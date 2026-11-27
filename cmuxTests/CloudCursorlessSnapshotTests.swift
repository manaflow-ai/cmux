import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A legacy daemon sends snapshots without a cursor. Two missing cursors carry
/// no ordering information, so they must not be treated as the same cursor.
@MainActor
@Suite("Cursorless daemon snapshots", .timeLimit(.minutes(1)))
struct CloudCursorlessSnapshotTests {
    private func snapshot(workspaceName: String, cursor: [String: String]? = nil) -> [String: Any] {
        var document: [String: Any] = [
            "workspaces": [["id": "ws_main", "name": workspaceName, "focused": true]],
            "screens": [["id": "screen", "workspace_id": "ws_main"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": [["id": "tab", "pane_id": "pane", "content_kind": "terminal", "content_id": "term", "focused": true]],
            "terminals": [["id": "term", "title": "bash", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ]
        if let cursor { document["cursor"] = cursor }
        return document
    }

    private func makeProvider() -> (CmuxTuiSurfaceProvider, SurfaceCatalog) {
        let summary = VMSummary(id: "cursorless", provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)
        let catalog = SurfaceCatalog()
        let provider = CmuxTuiSurfaceProvider(
            summary: summary,
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }),
            catalog: catalog
        )
        return (provider, catalog)
    }

    @Test("A changed cursorless snapshot replaces the previous cursorless graph")
    func changedCursorlessSnapshotInstalls() throws {
        let (provider, _) = makeProvider()
        let first = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot(workspaceName: "Before"), machine: provider.machine))
        #expect(first.cursor == nil)
        #expect(provider.installSnapshotIfNewer(first))

        let second = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot(workspaceName: "After"), machine: provider.machine))
        #expect(provider.installSnapshotIfNewer(second), "a missing cursor is not an equal cursor")
        #expect(provider.cloudState?.lookupIndex.workspace(id: "ws_main")?.name == "After")
    }

    @Test("A cursorless read that started before a newer install does not overwrite it")
    func staleCursorlessReadIsRefused() throws {
        let (provider, _) = makeProvider()
        // The first install moves the install version from 0 to 1.
        let first = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot(workspaceName: "Newer"), machine: provider.machine))
        #expect(provider.installSnapshotIfNewer(first))

        let stale = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot(workspaceName: "Older"), machine: provider.machine))
        #expect(!provider.installSnapshotIfNewer(stale, requestVersion: 0))
        #expect(provider.cloudState?.lookupIndex.workspace(id: "ws_main")?.name == "Newer")
        #expect(provider.installSnapshotIfNewer(stale, requestVersion: 1))
    }

    @Test("A cursorless snapshot still never replaces a journaled graph")
    func cursorlessSnapshotDoesNotReplaceCursoredGraph() throws {
        let (provider, _) = makeProvider()
        let journaled = try #require(CmuxTuiSnapshotParser.state(
            fromSnapshot: snapshot(workspaceName: "Journaled", cursor: ["generation": "daemon", "revision": "3"]),
            machine: provider.machine
        ))
        #expect(provider.installSnapshotIfNewer(journaled))

        let legacy = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot(workspaceName: "Legacy"), machine: provider.machine))
        #expect(!provider.installSnapshotIfNewer(legacy))
        #expect(provider.cloudState?.lookupIndex.workspace(id: "ws_main")?.name == "Journaled")
    }
}
