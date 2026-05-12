import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SearchIndexTests: XCTestCase {
    func testSearchFindsBrowserAndMarkdownDocuments() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let windowID = UUID()
        let workspaceID = UUID()
        let browserPanelID = UUID()
        let markdownPanelID = UUID()

        try await index.upsert(
            SearchIndexDocument(
                id: "browser-doc",
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: browserPanelID,
                kind: .browser,
                title: "Release Notes",
                location: "https://example.test/releases",
                anchor: "https://example.test/releases",
                text: "The browser panel contains apricot release details.",
                timestamp: Date(timeIntervalSince1970: 200)
            )
        )
        try await index.upsert(
            SearchIndexDocument(
                id: "markdown-doc",
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: markdownPanelID,
                kind: .markdown,
                title: "Plan.md",
                location: "/tmp/Plan.md",
                anchor: "/tmp/Plan.md",
                text: "Markdown notes mention blueberry architecture.",
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )

        let browserHits = try await index.search("apricot", limit: 10)
        XCTAssertEqual(browserHits.map(\.id), ["browser-doc"])
        XCTAssertEqual(browserHits.first?.kind, .browser)
        XCTAssertEqual(browserHits.first?.panelID, browserPanelID)

        let markdownHits = try await index.search("blueberry", limit: 10)
        XCTAssertEqual(markdownHits.map(\.id), ["markdown-doc"])
        XCTAssertEqual(markdownHits.first?.kind, .markdown)
        XCTAssertEqual(markdownHits.first?.panelID, markdownPanelID)
    }

    func testUpsertReplacesExistingDocumentText() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let windowID = UUID()
        let workspaceID = UUID()
        let panelID = UUID()

        let original = SearchIndexDocument(
            id: "doc",
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            kind: .markdown,
            title: "Draft",
            location: "/tmp/draft.md",
            anchor: "/tmp/draft.md",
            text: "oldtoken"
        )
        try await index.upsert(original)

        let replacement = SearchIndexDocument(
            id: "doc",
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            kind: .markdown,
            title: "Draft",
            location: "/tmp/draft.md",
            anchor: "/tmp/draft.md",
            text: "newtoken"
        )
        try await index.upsert(replacement)

        XCTAssertEqual(try await index.search("oldtoken", limit: 10), [])
        XCTAssertEqual(try await index.search("newtoken", limit: 10).map(\.id), ["doc"])
    }

    func testPanelStableIDReplacesDocumentAfterNavigationOrMove() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let panelID = UUID()
        let documentID = SearchIndexDocument.panelStableID(panelID: panelID, kind: .browser)

        try await index.upsert(
            SearchIndexDocument(
                id: documentID,
                windowID: UUID(),
                workspaceID: UUID(),
                panelID: panelID,
                kind: .browser,
                title: "Old Page",
                location: "https://example.test/old",
                anchor: "https://example.test/old",
                text: "oldnavigationtoken"
            )
        )

        let movedWindowID = UUID()
        let movedWorkspaceID = UUID()
        try await index.upsert(
            SearchIndexDocument(
                id: documentID,
                windowID: movedWindowID,
                workspaceID: movedWorkspaceID,
                panelID: panelID,
                kind: .browser,
                title: "New Page",
                location: "https://example.test/new",
                anchor: "https://example.test/new",
                text: "newnavigationtoken"
            )
        )

        XCTAssertEqual(try await index.search("oldnavigationtoken", limit: 10), [])
        let hits = try await index.search("newnavigationtoken", limit: 10)
        XCTAssertEqual(hits.map(\.id), [documentID])
        XCTAssertEqual(hits.first?.windowID, movedWindowID)
        XCTAssertEqual(hits.first?.workspaceID, movedWorkspaceID)
        XCTAssertEqual(hits.first?.location, "https://example.test/new")
    }

    func testSearchLowercasesUppercaseFTSOperatorTokens() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)

        try await index.upsert(
            SearchIndexDocument(
                id: "operator-doc",
                windowID: UUID(),
                workspaceID: UUID(),
                panelID: UUID(),
                kind: .markdown,
                title: "Operator Notes",
                location: "/tmp/operator.md",
                anchor: "/tmp/operator.md",
                text: "andromeda orbit notes"
            )
        )

        XCTAssertEqual(try await index.search("AND", limit: 10).map(\.id), ["operator-doc"])
    }

    func testDeletePanelRemovesIndexedDocuments() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let windowID = UUID()
        let workspaceID = UUID()
        let panelID = UUID()

        try await index.upsert(
            SearchIndexDocument(
                id: "doc",
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                kind: .browser,
                title: "Searchable",
                location: "https://example.test",
                anchor: "https://example.test",
                text: "kiwifruit"
            )
        )

        XCTAssertEqual(try await index.search("kiwifruit", limit: 10).count, 1)
        try await index.deletePanel(panelID)
        XCTAssertEqual(try await index.search("kiwifruit", limit: 10), [])
    }

    func testDeleteAllClearsPersistentDocuments() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)

        try await index.upsert(
            SearchIndexDocument(
                id: "stale-doc",
                windowID: UUID(),
                workspaceID: UUID(),
                panelID: UUID(),
                kind: .title,
                title: "Stale",
                location: "Old Window",
                anchor: "title",
                text: "stalesessiontoken"
            )
        )

        XCTAssertEqual(try await index.search("stalesessiontoken", limit: 10).count, 1)
        try await index.deleteAll()
        XCTAssertEqual(try await index.search("stalesessiontoken", limit: 10), [])
    }

    private func makeFixture() throws -> (directoryURL: URL, databaseURL: URL) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-search-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return (directoryURL, directoryURL.appendingPathComponent("search.db", isDirectory: false))
    }
}
