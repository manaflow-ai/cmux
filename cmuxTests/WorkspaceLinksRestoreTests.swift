import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite
struct WorkspaceLinksRestoreTests {
    @Test
    func persistedCollectionDecodesAtRetentionCap() throws {
        let snapshot = SessionWorkspaceLinkSnapshot(entry: makeEntry(
            url: "https://example.com/bounded",
            sourcePanelID: nil,
            lastSeen: Date(timeIntervalSince1970: 1)
        ))
        let encoded = try JSONEncoder().encode(Array(
            repeating: snapshot,
            count: WorkspaceLinksIngestConfiguration.maximumRetentionLimit + 1
        ))

        let decoded = try JSONDecoder().decode(
            SessionWorkspaceLinksSnapshotCollection.self,
            from: encoded
        )

        #expect(decoded.snapshots.count == WorkspaceLinksIngestConfiguration.maximumRetentionLimit)
    }

    @Test
    func oversizedPersistedStringsAreRejected() {
        var oversizedURL = SessionWorkspaceLinkSnapshot(entry: makeEntry(
            url: "https://example.com/valid",
            sourcePanelID: nil,
            lastSeen: Date(timeIntervalSince1970: 1)
        ))
        oversizedURL.url = "https://example.com/" + String(repeating: "a", count: 4_096)

        var oversizedTitle = SessionWorkspaceLinkSnapshot(entry: makeEntry(
            url: "https://example.com/title",
            sourcePanelID: nil,
            lastSeen: Date(timeIntervalSince1970: 2)
        ))
        oversizedTitle.fetchedTitle = String(repeating: "t", count: 2_049)

        #expect(oversizedURL.linkEntry == nil)
        #expect(oversizedTitle.linkEntry == nil)
    }

    @MainActor
    @Test
    func restoreRetargetsMappedSourcesAndClearsMissingSources() throws {
        let oldPanelID = UUID()
        let mappedPanelID = UUID()
        let missingPanelID = UUID()
        var snapshot = makeWorkspaceSnapshot()
        snapshot.links = SessionWorkspaceLinksSnapshotCollection([
            SessionWorkspaceLinkSnapshot(entry: makeEntry(
                url: "https://example.com/mapped",
                sourcePanelID: oldPanelID,
                lastSeen: Date(timeIntervalSince1970: 2)
            )),
            SessionWorkspaceLinkSnapshot(entry: makeEntry(
                url: "https://example.com/missing",
                sourcePanelID: missingPanelID,
                lastSeen: Date(timeIntervalSince1970: 1)
            )),
        ])
        let workspace = Workspace()

        workspace.restoreLinksState(
            from: snapshot,
            panelIDMap: [oldPanelID: mappedPanelID]
        )

        #expect(workspace.linksState.entries.first { $0.url.hasSuffix("/mapped") }?.sourcePanelId == mappedPanelID)
        #expect(workspace.linksState.entries.first { $0.url.hasSuffix("/missing") }?.sourcePanelId == nil)
    }

    @MainActor
    @Test
    func identicalLiveSettingsAreANoOp() {
        let state = WorkspaceLinksState(retentionLimit: 500, fetchTitlesEnabled: false)
        let structuralRevision = state.structuralRevision
        let persistenceRevision = state.persistenceRevision

        state.applySettings(retentionLimit: 500, fetchTitlesEnabled: false)

        #expect(state.structuralRevision == structuralRevision)
        #expect(state.persistenceRevision == persistenceRevision)
        #expect(state.retentionLimit == 500)
        #expect(!state.fetchTitlesEnabled)
    }

    private func makeEntry(
        url: String,
        sourcePanelID: UUID?,
        lastSeen: Date
    ) -> WorkspaceCapturedLink {
        WorkspaceCapturedLink(
            id: UUID(),
            url: url,
            hostKey: "example.com",
            firstSeen: lastSeen,
            lastSeen: lastSeen,
            count: 1,
            sourcePanelId: sourcePanelID,
            sourceSurfaceTitle: "Terminal",
            origin: .detected,
            fetchedTitle: nil
        )
    }

    private func makeWorkspaceSnapshot() -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )
    }
}
