import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A full snapshot and the applied deltas can disagree at the same cursor. The
/// first such conflict from a full refresh arms a recovery read; a second one
/// at the same cursor adopts the fresh snapshot, so the graph never stays
/// wedged, while a single race cannot throw away the installed graph.
@MainActor
@Suite("Equal-cursor conflict recovery", .timeLimit(.minutes(1)))
struct CloudEqualCursorConflictRecoveryTests {
    private func snapshot(workspaceName: String, revision: Int = 3) -> [String: Any] {
        [
            "cursor": ["generation": "daemon", "revision": String(revision)],
            "workspaces": [["id": "ws_main", "name": workspaceName, "focused": true]],
            "screens": [["id": "screen", "workspace_id": "ws_main"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": [["id": "tab", "pane_id": "pane", "content_kind": "terminal", "content_id": "term", "focused": true]],
            "terminals": [["id": "term", "title": "bash", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ]
    }

    private func makeProvider() -> CmuxTuiSurfaceProvider {
        let summary = VMSummary(id: "equal-cursor", provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)
        return CmuxTuiSurfaceProvider(
            summary: summary,
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }),
            catalog: SurfaceCatalog()
        )
    }

    private func state(_ provider: CmuxTuiSurfaceProvider, _ name: String, revision: Int = 3) throws -> CloudVMState {
        try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot(workspaceName: name, revision: revision), machine: provider.machine))
    }

    private func name(_ provider: CmuxTuiSurfaceProvider) -> String? {
        provider.cloudState?.lookupIndex.workspace(id: "ws_main")?.name
    }

    @Test("The first full-refresh conflict keeps the graph and arms recovery; a second adopts the fresh snapshot")
    func secondConflictAdopts() throws {
        let provider = makeProvider()
        #expect(provider.installSnapshotIfNewer(try state(provider, "Applied")))

        let fresh = try state(provider, "Daemon")
        #expect(!provider.installSnapshotIfNewer(fresh, requestVersion: 1))
        #expect(name(provider) == "Applied")
        #expect(provider.equalCursorConflict == fresh.cursor)

        #expect(provider.installSnapshotIfNewer(fresh, requestVersion: 1), "a repeated conflict at the same cursor must break the wedge")
        #expect(name(provider) == "Daemon")
        #expect(provider.equalCursorConflict == nil)
    }

    @Test("An event-feed snapshot conflict never adopts")
    func eventConflictNeverAdopts() throws {
        let provider = makeProvider()
        #expect(provider.installSnapshotIfNewer(try state(provider, "Applied")))
        let fresh = try state(provider, "Daemon")
        #expect(!provider.installSnapshotIfNewer(fresh))
        #expect(!provider.installSnapshotIfNewer(fresh))
        #expect(name(provider) == "Applied")
    }

    @Test("A read that started before a newer install never adopts")
    func staleReadNeverAdopts() throws {
        let provider = makeProvider()
        #expect(provider.installSnapshotIfNewer(try state(provider, "Applied")))
        let fresh = try state(provider, "Daemon")
        #expect(!provider.installSnapshotIfNewer(fresh, requestVersion: 0))
        #expect(!provider.installSnapshotIfNewer(fresh, requestVersion: 0))
        #expect(name(provider) == "Applied")
    }

    @Test("An install at a newer cursor clears an armed conflict")
    func newerInstallClearsConflict() throws {
        let provider = makeProvider()
        #expect(provider.installSnapshotIfNewer(try state(provider, "Applied")))
        #expect(!provider.installSnapshotIfNewer(try state(provider, "Daemon"), requestVersion: 1))
        #expect(provider.installSnapshotIfNewer(try state(provider, "Next", revision: 4)))
        #expect(provider.equalCursorConflict == nil)

        // A conflict at the new cursor starts over: the first one keeps the graph.
        #expect(!provider.installSnapshotIfNewer(try state(provider, "Other", revision: 4), requestVersion: 2))
        #expect(name(provider) == "Next")
    }
}
