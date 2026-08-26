import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite
struct WorkspaceLinksTests {
    private func makeSnapshot() -> SessionWorkspaceSnapshot {
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

    @MainActor
    @Test
    func ingestDedupesAndMovesRepeatToFront() {
        let state = WorkspaceLinksState()
        let config = WorkspaceLinksIngestConfiguration(ignoreHosts: [])
        let first = Date(timeIntervalSince1970: 10)
        let second = Date(timeIntervalSince1970: 20)
        let source = UUID()

        state.ingest(
            url: "https://example.com/a",
            origin: .detected,
            sourcePanelId: source,
            sourceSurfaceTitle: "Terminal",
            configuration: config,
            now: first
        )
        state.ingest(
            url: "https://other.example/b",
            origin: .detected,
            sourcePanelId: nil,
            sourceSurfaceTitle: nil,
            configuration: config,
            now: first
        )
        state.ingest(
            url: "https://example.com/a",
            origin: .osc8,
            sourcePanelId: source,
            sourceSurfaceTitle: "Terminal",
            configuration: config,
            now: second
        )

        #expect(state.entries.map(\.url) == ["https://example.com/a", "https://other.example/b"])
        #expect(state.entries[0].count == 2)
        #expect(state.entries[0].lastSeen == second)
        #expect(state.entries[0].origin == .osc8)
    }

    @MainActor
    @Test
    func appliesRetentionIgnoreHostsFileFilterAndOrdering() {
        let state = WorkspaceLinksState()
        let config = WorkspaceLinksIngestConfiguration(
            includeFilePaths: false,
            ignoreHosts: ["localhost:31034", "*.internal.example"],
            retentionLimit: 10
        )

        state.ingest(url: "http://localhost:31034/status", origin: .detected, sourcePanelId: nil, sourceSurfaceTitle: nil, configuration: config)
        state.ingest(url: "https://api.internal.example/a", origin: .detected, sourcePanelId: nil, sourceSurfaceTitle: nil, configuration: config)
        state.ingest(url: "file:///tmp/report.html", origin: .detected, sourcePanelId: nil, sourceSurfaceTitle: nil, configuration: config)
        for index in 0..<12 {
            state.ingest(
                url: "https://example.com/\(index)",
                origin: .detected,
                sourcePanelId: nil,
                sourceSurfaceTitle: nil,
                configuration: config,
                now: Date(timeIntervalSince1970: Double(index))
            )
        }

        #expect(state.entries.count == 10)
        #expect(state.entries.first?.url == "https://example.com/11")
        #expect(state.entries.last?.url == "https://example.com/2")
        #expect(!state.entries.contains { $0.url.contains("localhost") || $0.url.hasPrefix("file://") })
    }

    @Test
    func dayGroupingUsesStartOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 86_400 + 123)
        #expect(calendar.startOfDay(for: date) == Date(timeIntervalSince1970: 86_400))
    }

    @Test
    func linkSnapshotRoundTripsEntry() throws {
        let id = UUID()
        let source = UUID()
        let entry = WorkspaceCapturedLink(
            id: id,
            url: "https://example.com/a",
            hostKey: "example.com",
            firstSeen: Date(timeIntervalSince1970: 1),
            lastSeen: Date(timeIntervalSince1970: 2),
            count: 3,
            sourcePanelId: source,
            sourceSurfaceTitle: "Terminal",
            origin: .osc8,
            fetchedTitle: "Example"
        )
        let snapshot = SessionWorkspaceLinkSnapshot(entry: entry)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionWorkspaceLinkSnapshot.self, from: data)
        #expect(decoded.linkEntry == entry)
    }

    @Test
    func workspaceSnapshotWithoutLinksDecodes() throws {
        let snapshot = makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["links"] == nil)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.links == nil)
        #expect(decoded.restoredLinks.isEmpty)
    }

    @MainActor
    @Test
    func loweringRetentionTrimsExistingEntriesWithoutNewOutput() {
        let state = WorkspaceLinksState()
        let config = WorkspaceLinksIngestConfiguration(ignoreHosts: [], retentionLimit: 100)
        for index in 0..<20 {
            state.ingest(
                url: "https://example.com/\(index)",
                origin: .detected,
                sourcePanelId: nil,
                sourceSurfaceTitle: nil,
                configuration: config
            )
        }

        state.applyRetentionLimit(10)

        #expect(state.entries.count == 10)
        #expect(state.entries.first?.url == "https://example.com/19")
        #expect(state.entries.last?.url == "https://example.com/10")
    }

    @MainActor
    @Test
    func titleFetchFailureStateStaysBoundToRetainedEntry() throws {
        let state = WorkspaceLinksState(fetchTitlesEnabled: true)
        let config = WorkspaceLinksIngestConfiguration(ignoreHosts: [])
        let entry = try #require(state.ingest(
            url: "https://example.com/title",
            origin: .detected,
            sourcePanelId: nil,
            sourceSurfaceTitle: nil,
            configuration: config
        ))

        #expect(state.beginTitleFetch(for: entry.id) != nil)
        #expect(state.beginTitleFetch(for: entry.id) == nil)
        state.finishTitleFetch(for: entry.id, title: nil)
        #expect(state.beginTitleFetch(for: entry.id) == nil)

        state.ingest(
            url: entry.url,
            origin: .detected,
            sourcePanelId: nil,
            sourceSurfaceTitle: nil,
            configuration: config
        )
        #expect(state.beginTitleFetch(for: entry.id) != nil)
        state.cancelTitleFetch(for: entry.id)
        #expect(state.beginTitleFetch(for: entry.id) != nil)
    }

    @MainActor
    @Test
    func liveTitleSettingEnablesExistingEntriesAndCancelsInFlightState() throws {
        let state = WorkspaceLinksState(fetchTitlesEnabled: false)
        let entry = try #require(state.ingest(
            url: "https://example.com/live-setting",
            origin: .detected,
            sourcePanelId: nil,
            sourceSurfaceTitle: nil,
            configuration: WorkspaceLinksIngestConfiguration(ignoreHosts: [])
        ))
        #expect(state.beginTitleFetch(for: entry.id) == nil)

        state.applySettings(retentionLimit: 500, fetchTitlesEnabled: true)
        #expect(state.beginTitleFetch(for: entry.id) != nil)

        state.applySettings(retentionLimit: 500, fetchTitlesEnabled: false)
        #expect(state.beginTitleFetch(for: entry.id) == nil)
        state.applySettings(retentionLimit: 500, fetchTitlesEnabled: true)
        #expect(state.beginTitleFetch(for: entry.id) != nil)
    }

    @MainActor
    @Test
    func persistenceRevisionChangesOnlyWhenLinkStateMutates() {
        let state = WorkspaceLinksState()
        let initialRevision = state.persistenceRevision
        _ = state.entries
        #expect(state.persistenceRevision == initialRevision)

        state.ingest(
            url: "https://example.com/revision",
            origin: .detected,
            sourcePanelId: nil,
            sourceSurfaceTitle: nil,
            configuration: WorkspaceLinksIngestConfiguration(ignoreHosts: [])
        )
        #expect(state.persistenceRevision != initialRevision)
        let ingestedRevision = state.persistenceRevision
        _ = state.entries
        #expect(state.persistenceRevision == ingestedRevision)
    }

    @MainActor
    @Test
    func linksPanelCannotDetachFromItsWorkspaceOwner() throws {
        let workspace = Workspace()
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(workspace.newWorkspaceLinksSurface(inPane: paneID))

        #expect(!PanelType.links.allowsCrossContainerTransfer)
        #expect(workspace.detachSurface(panelId: panel.id) == nil)
        #expect(workspace.panels[panel.id] === panel)
    }

    @MainActor
    @Test
    func ingressUsesCurrentSurfaceOwnerAfterWorkspaceMove() {
        let originalWorkspace = Workspace()
        let currentWorkspace = Workspace()
        let surfaceID = UUID()
        let ingress = TerminalLinkCaptureIngress { preferredWorkspaceID, panelID in
            #expect(preferredWorkspaceID == originalWorkspace.id)
            return panelID == surfaceID ? currentWorkspace : originalWorkspace
        }

        ingress.ingest(
            [TerminalCapturedLink(url: "https://example.com/moved", source: .detected)],
            workspaceID: originalWorkspace.id,
            sourcePanelId: surfaceID,
            settings: LinkCaptureSettingsSnapshot(
                enabled: true,
                includeFilePaths: false,
                ignoreHosts: [],
                retentionLimit: 500,
                fetchTitles: false
            )
        )

        #expect(originalWorkspace.linksState.entries.isEmpty)
        #expect(currentWorkspace.linksState.entries.map(\.url) == ["https://example.com/moved"])
    }
}
