import XCTest
import SQLite3

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

        let oldTokenHits = try await index.search("oldtoken", limit: 10)
        XCTAssertEqual(oldTokenHits, [])

        let newTokenHits = try await index.search("newtoken", limit: 10)
        XCTAssertEqual(newTokenHits.map(\.id), ["doc"])
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

        let oldNavigationHits = try await index.search("oldnavigationtoken", limit: 10)
        XCTAssertEqual(oldNavigationHits, [])

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

        let hits = try await index.search("AND", limit: 10)
        XCTAssertEqual(hits.map(\.id), ["operator-doc"])
    }

    func testSearchTreatsFTSMetacharactersAsTokenSeparators() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)

        try await index.upsert(
            SearchIndexDocument(
                id: "quoted-doc",
                windowID: UUID(),
                workspaceID: UUID(),
                panelID: UUID(),
                kind: .markdown,
                title: "Quoted Notes",
                location: "/tmp/quoted.md",
                anchor: "/tmp/quoted.md",
                text: "quoted token content"
            )
        )

        let hits = try await index.search("\"quoted\" + token", limit: 10)
        XCTAssertEqual(hits.map(\.id), ["quoted-doc"])
    }

    func testQueryTokensMatchSearchTokenization() {
        XCTAssertEqual(
            SearchIndex.queryTokens(for: "  Alpha-beta AND gamma_delta  "),
            ["alpha", "beta", "and", "gamma", "delta"]
        )
    }

    func testBrowserInlineNeedleUsesMatchingSearchToken() {
        let hit = SearchIndexHit(
            id: "browser-doc",
            windowID: UUID(),
            workspaceID: UUID(),
            panelID: UUID(),
            kind: .browser,
            title: "Result",
            location: "https://example.test",
            anchor: "https://example.test",
            snippet: "The rendered page contains bar but not the complete raw query.",
            rank: 0,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(
            GlobalSearchInlineSearch.browserNeedle(for: "foo bar", hit: hit),
            "bar"
        )
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

        let indexedHits = try await index.search("kiwifruit", limit: 10)
        XCTAssertEqual(indexedHits.count, 1)

        try await index.deletePanel(panelID)

        let deletedHits = try await index.search("kiwifruit", limit: 10)
        XCTAssertEqual(deletedHits, [])
    }

    func testDeleteDocumentRemovesOnlyMatchingDocument() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let windowID = UUID()
        let workspaceID = UUID()
        let panelID = UUID()
        let titleID = SearchIndexDocument.panelStableID(panelID: panelID, kind: .title)
        let markdownID = SearchIndexDocument.panelStableID(panelID: panelID, kind: .markdown)

        try await index.upsert(
            SearchIndexDocument(
                id: titleID,
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                kind: .title,
                title: "Unavailable.md",
                location: "Window > Workspace",
                anchor: "title",
                text: "stabletitlekeyword"
            )
        )
        try await index.upsert(
            SearchIndexDocument(
                id: markdownID,
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                kind: .markdown,
                title: "Unavailable.md",
                location: "/tmp/Unavailable.md",
                anchor: "/tmp/Unavailable.md",
                text: "staledocumentkeyword"
            )
        )

        try await index.deleteDocument(id: markdownID)

        let staleDocumentHits = try await index.search("staledocumentkeyword", limit: 10)
        XCTAssertEqual(staleDocumentHits, [])

        let titleHits = try await index.search("stabletitlekeyword", limit: 10)
        XCTAssertEqual(titleHits.map(\.id), [titleID])
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

        let indexedHits = try await index.search("stalesessiontoken", limit: 10)
        XCTAssertEqual(indexedHits.count, 1)

        try await index.deleteAll()

        let deletedHits = try await index.search("stalesessiontoken", limit: 10)
        XCTAssertEqual(deletedHits, [])
    }

    func testInitializationBackfillsLegacyRowsIntoFTS() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let windowID = UUID()
        let workspaceID = UUID()
        let panelID = UUID()
        try makeLegacyDatabase(
            at: fixture.databaseURL,
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID
        )

        let index = try SearchIndex(databaseURL: fixture.databaseURL)

        let hits = try await index.search("legacybackfilltoken", limit: 10)
        XCTAssertEqual(hits.map(\.id), ["legacy-doc"])
        XCTAssertEqual(hits.first?.windowID, windowID)
        XCTAssertEqual(hits.first?.workspaceID, workspaceID)
        XCTAssertEqual(hits.first?.panelID, panelID)
    }

    func testSearchAcceptsLimitBeyondInt32Range() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        try await index.upsert(
            SearchIndexDocument(
                id: "wide-limit-doc",
                windowID: UUID(),
                workspaceID: UUID(),
                panelID: UUID(),
                kind: .markdown,
                title: "Wide Limit",
                location: "/tmp/wide-limit.md",
                anchor: "/tmp/wide-limit.md",
                text: "widelimittoken"
            )
        )

        let hits = try await index.search("widelimittoken", limit: Int(Int32.max) + 1)
        XCTAssertEqual(hits.map(\.id), ["wide-limit-doc"])
    }

    private func makeFixture() throws -> (directoryURL: URL, databaseURL: URL) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-search-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return (directoryURL, directoryURL.appendingPathComponent("search.db", isDirectory: false))
    }

    private func makeLegacyDatabase(
        at databaseURL: URL,
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID
    ) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite open failure"
            sqlite3_close(database)
            throw SearchIndexTestError.sqlite(message)
        }
        defer { sqlite3_close(database) }

        try executeLegacySQL(
            """
            CREATE TABLE chunks (
                rowid INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                window_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                panel_id TEXT,
                kind TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                location TEXT NOT NULL DEFAULT '',
                anchor TEXT NOT NULL DEFAULT '',
                ts REAL NOT NULL,
                text TEXT NOT NULL DEFAULT ''
            )
            """,
            database: database
        )
        try executeLegacySQL(
            """
            INSERT INTO chunks (
                id, window_id, workspace_id, panel_id, kind,
                title, location, anchor, ts, text
            )
            VALUES (
                'legacy-doc',
                '\(windowID.uuidString)',
                '\(workspaceID.uuidString)',
                '\(panelID.uuidString)',
                'markdown',
                'Legacy',
                '/tmp/Legacy.md',
                '/tmp/Legacy.md',
                1,
                'legacybackfilltoken'
            )
            """,
            database: database
        )
        try executeLegacySQL("PRAGMA user_version = 0", database: database)
    }

    private func executeLegacySQL(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SearchIndexTestError.sqlite(message)
        }
    }
}

private enum SearchIndexTestError: Error {
    case sqlite(String)
}
