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
        #expect(WorkspaceLinksDayGrouping.dayKey(for: date, calendar: calendar) == Date(timeIntervalSince1970: 86_400))
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

    @Test
    func titleFetcherRefusesPrivateHostsWithoutNetwork() {
        #expect(!LinkTitleFetcher.mayFetchTitle(url: "https://localhost/a", hostKey: "localhost"))
        #expect(!LinkTitleFetcher.mayFetchTitle(url: "https://10.0.0.1/a", hostKey: "10.0.0.1"))
        #expect(!LinkTitleFetcher.mayFetchTitle(url: "file:///tmp/a", hostKey: nil))
        #expect(!LinkTitleFetcher.mayFetchTitle(url: "https://[::1]:8080/a", hostKey: "::1:8080"))
        #expect(LinkTitleFetcher.mayFetchTitle(url: "https://example.com/a", hostKey: "example.com"))
    }
}
