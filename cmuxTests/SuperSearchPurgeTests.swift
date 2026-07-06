import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class SuperSearchPurgeTests: XCTestCase {
    func testClosePurgesAllKinds() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let windowID = UUID()
        let workspaceID = UUID()
        let panelID = UUID()

        try await index.upsert(
            SearchIndexDocument(
                id: GlobalSearchDocuments.workspaceMetadataDocumentID(workspaceID: workspaceID),
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: nil,
                kind: .workspace,
                title: "Workspace",
                location: "Window > Workspace",
                anchor: "workspace",
                text: "workspace-close-token"
            )
        )
        try await index.upsert(
            SearchIndexDocument(
                id: "session:test:transcript:0",
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                kind: .transcript,
                title: "Session",
                location: "Window > Workspace",
                anchor: "0",
                text: "transcript-close-token"
            )
        )
        try await index.upsert(
            SearchIndexDocument(
                id: "session:test:command:0",
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                kind: .command,
                title: "Session",
                location: "Window > Workspace",
                anchor: "0",
                text: "command-close-token"
            )
        )

        try await index.deletePanel(panelID)
        XCTAssertEqual(try await index.search("transcript-close-token", limit: 10), [])
        XCTAssertEqual(try await index.search("command-close-token", limit: 10), [])
        XCTAssertEqual(try await index.search("workspace-close-token", limit: 10).count, 1)

        try await index.deleteWorkspace(workspaceID)
        XCTAssertEqual(try await index.search("workspace-close-token", limit: 10), [])
    }
}
