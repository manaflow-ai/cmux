import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SuperSearchQueryIsolationTests: XCTestCase {
    func testQueryReturnsTranscriptHitsWithZeroLivePanels() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let windowID = UUID()
        let workspaceID = UUID()
        let panelID = UUID()
        try await index.upsert(
            SearchIndexDocument(
                id: "session:preloaded:transcript:0",
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                kind: .transcript,
                title: "Preloaded Session",
                location: "Detached Window > Workspace",
                anchor: "0",
                text: "index-only-query-token"
            )
        )

        let hits = try await index.search("index-only-query-token", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.kind, .transcript)
        XCTAssertEqual(hits.first?.workspaceID, workspaceID)
        XCTAssertEqual(hits.first?.panelID, panelID)
    }
}
