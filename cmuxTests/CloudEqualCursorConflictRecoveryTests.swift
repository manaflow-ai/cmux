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
    /// The provider holds its catalog `unowned`, so the suite owns it for the
    /// whole test; a temporary would be freed before the provider touches it.
    private let catalog = SurfaceCatalog()

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
            catalog: catalog
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

    @Test("Only the arming install asks for a recovery read")
    func onlyArmingSchedulesRecovery() throws {
        let provider = makeProvider()
        #expect(provider.installSnapshotIfNewer(try state(provider, "Applied")))
        let fresh = try state(provider, "Daemon")
        #expect(!provider.installSnapshotIfNewer(fresh, requestVersion: 1))
        #expect(provider.equalCursorConflictArmedByLastInstall)
        // A stale read at the armed cursor cannot adopt, so it must not spend
        // another recovery read either.
        #expect(!provider.installSnapshotIfNewer(fresh, requestVersion: 0))
        #expect(!provider.equalCursorConflictArmedByLastInstall)
        #expect(provider.equalCursorConflict == fresh.cursor)
    }

    @Test("A pending rename's predecessor is never adopted, however often it conflicts")
    func renameFenceHoldsWhileArmed() throws {
        let provider = makeProvider()
        #expect(provider.installSnapshotIfNewer(try state(provider, "Applied")))
        let fresh = try state(provider, "Daemon")
        provider.recordPendingRemoteRename(tabID: "tab", name: "Renamed", receipt: try #require(fresh.cursor))
        #expect(!provider.installSnapshotIfNewer(fresh, requestVersion: 1))
        #expect(!provider.installSnapshotIfNewer(fresh, requestVersion: 1))
        #expect(name(provider) == "Applied")
        #expect(provider.equalCursorConflict == nil)
    }

    @Test("Suspending clears an armed conflict so the first read after resume cannot adopt")
    func suspendClearsConflict() throws {
        let provider = makeProvider()
        #expect(provider.installSnapshotIfNewer(try state(provider, "Applied")))
        #expect(!provider.installSnapshotIfNewer(try state(provider, "Daemon"), requestVersion: 1))
        #expect(provider.equalCursorConflict != nil)
        provider.suspendForFeatureFlag()
        #expect(provider.equalCursorConflict == nil)
    }

    @Test("An install at a newer cursor clears an armed conflict")
    func newerInstallClearsConflict() throws {
        let provider = makeProvider()
        #expect(provider.installSnapshotIfNewer(try state(provider, "Applied")))
        #expect(!provider.installSnapshotIfNewer(try state(provider, "Daemon"), requestVersion: 1))
        #expect(provider.equalCursorConflict != nil)
        #expect(provider.installSnapshotIfNewer(try state(provider, "Next", revision: 4)))
        #expect(provider.equalCursorConflict == nil)

        // A conflict at the new cursor starts over: the first one keeps the graph.
        #expect(!provider.installSnapshotIfNewer(try state(provider, "Other", revision: 4), requestVersion: 2))
        #expect(name(provider) == "Next")
    }

    @Test("An equal-content install at the armed cursor clears the conflict")
    func equalContentInstallClearsConflict() throws {
        let provider = makeProvider()
        #expect(provider.installSnapshotIfNewer(try state(provider, "Applied")))
        #expect(!provider.installSnapshotIfNewer(try state(provider, "Daemon"), requestVersion: 1))
        #expect(provider.equalCursorConflict != nil)
        #expect(provider.installSnapshotIfNewer(try state(provider, "Applied"), requestVersion: 1))
        #expect(provider.equalCursorConflict == nil)
        #expect(name(provider) == "Applied")
    }
}
