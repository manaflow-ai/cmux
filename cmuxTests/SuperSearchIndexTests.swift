import XCTest
import CmuxAgentChat
import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct SuperSearchTestSupport {
    struct Fixture {
        let directoryURL: URL
        let databaseURL: URL
    }

    static func makeFixture() throws -> Fixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-super-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return Fixture(
            directoryURL: directoryURL,
            databaseURL: directoryURL.appendingPathComponent("search.db", isDirectory: false)
        )
    }

    static func makeRouting(
        windowID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        panelID: UUID = UUID(),
        workspaceTitle: String = "Workspace",
        panelTitle: String = "Agent Session",
        location: String = "Window > Workspace"
    ) -> GlobalSearchTranscriptRouting {
        GlobalSearchTranscriptRouting(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            workspaceTitle: workspaceTitle,
            panelTitle: panelTitle,
            location: location
        )
    }

    static func message(
        id: String? = nil,
        seq: Int,
        role: ChatRole = .agent,
        timestamp: Date = .init(timeIntervalSince1970: 1),
        kind: ChatMessageKind
    ) -> ChatMessage {
        ChatMessage(
            id: id ?? "message-\(seq)",
            seq: seq,
            role: role,
            timestamp: timestamp,
            kind: kind
        )
    }

    static func batch(
        appended: [ChatMessage] = [],
        updated: [ChatMessage] = [],
        discoveredTitle: String? = nil,
        didReset: Bool = false
    ) -> AgentChatTranscriptTailer.Batch {
        AgentChatTranscriptTailer.Batch(
            appended: appended,
            updated: updated,
            discoveredTitle: discoveredTitle,
            didReset: didReset
        )
    }
}

actor CountingSearchIndex: SearchIndexWriting {
    private(set) var upsertedDocuments: [SearchIndexDocument] = []
    private(set) var deletedDocumentIDs: [String] = []
    private(set) var deletedPrefixes: [String] = []
    private(set) var deletedPanelIDs: [UUID] = []
    private(set) var deletedWorkspaceIDs: [UUID] = []

    func upsert(_ document: SearchIndexDocument) throws {
        upsertedDocuments.append(document)
    }

    func deleteDocument(id: String) throws {
        deletedDocumentIDs.append(id)
    }

    func deleteDocuments(idPrefix: String) throws {
        deletedPrefixes.append(idPrefix)
    }

    func deletePanel(_ panelID: UUID) throws {
        deletedPanelIDs.append(panelID)
    }

    func deleteWorkspace(_ workspaceID: UUID) throws {
        deletedWorkspaceIDs.append(workspaceID)
    }
}

@MainActor
final class SuperSearchIndexTests: XCTestCase {
    func testUniqueMetadataTokenRoutesToWorkspace() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let windowID = UUID()
        let workspaceID = UUID()
        let otherWorkspaceID = UUID()
        let workspaceDocument = GlobalSearchDocuments.workspaceMetadataDocument(
            windowID: windowID,
            workspaceID: workspaceID,
            workspaceTitle: "Alpha Workspace",
            location: "Window > Alpha Workspace",
            snapshot: GlobalSearchWorkspaceMetadataSnapshot(
                currentDirectory: "/tmp/project-alpha",
                workspaceGitBranch: SidebarGitBranchState(branch: "branch-unique-zulu", isDirty: false),
                workspacePullRequest: nil,
                statusEntries: [],
                progress: nil,
                metadataBlocks: [],
                logEntries: [],
                panels: []
            )
        )

        try await index.upsert(workspaceDocument)
        try await index.upsert(
            GlobalSearchDocuments.workspaceMetadataDocument(
                windowID: windowID,
                workspaceID: otherWorkspaceID,
                workspaceTitle: "Beta Workspace",
                location: "Window > Beta Workspace",
                snapshot: GlobalSearchWorkspaceMetadataSnapshot(
                    currentDirectory: "/tmp/project-beta",
                    workspaceGitBranch: SidebarGitBranchState(branch: "main", isDirty: false),
                    workspacePullRequest: nil,
                    statusEntries: [],
                    progress: nil,
                    metadataBlocks: [],
                    logEntries: [],
                    panels: []
                )
            )
        )

        let hits = try await index.search("branch-unique-zulu", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.workspaceID, workspaceID)
        XCTAssertEqual(hits.first?.kind, .workspace)
        XCTAssertNil(hits.first?.panelID)
    }

    func testReupsertYieldsSingleHit() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let documentID = "session:test:transcript:0"
        let windowID = UUID()
        let workspaceID = UUID()
        let panelID = UUID()

        try await index.upsert(
            SearchIndexDocument(
                id: documentID,
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                kind: .transcript,
                title: "Session",
                location: "Window > Workspace",
                anchor: "0",
                text: "reroute-token"
            )
        )
        try await index.upsert(
            SearchIndexDocument(
                id: documentID,
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                kind: .transcript,
                title: "Session",
                location: "Window > Workspace",
                anchor: "0",
                text: "reroute-token updated"
            )
        )

        let hits = try await index.search("reroute-token", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, documentID)
    }

    func testDeleteWorkspaceAndPrefixRemoveIndexedDocuments() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let workspaceID = UUID()
        let panelID = UUID()

        try await index.upsert(
            SearchIndexDocument(
                id: "session:abc:transcript:0",
                windowID: UUID(),
                workspaceID: workspaceID,
                panelID: panelID,
                kind: .transcript,
                title: "Transcript",
                location: "Window > Workspace",
                anchor: "0",
                text: "prefixpurgetoken"
            )
        )
        try await index.upsert(
            SearchIndexDocument(
                id: GlobalSearchDocuments.workspaceMetadataDocumentID(workspaceID: workspaceID),
                windowID: UUID(),
                workspaceID: workspaceID,
                panelID: nil,
                kind: .workspace,
                title: "Workspace",
                location: "Window > Workspace",
                anchor: "workspace",
                text: "workspacepurgetoken"
            )
        )

        try await index.deleteDocuments(idPrefix: "session:abc:")
        XCTAssertEqual(try await index.search("prefixpurgetoken", limit: 10), [])

        try await index.deleteWorkspace(workspaceID)
        XCTAssertEqual(try await index.search("workspacepurgetoken", limit: 10), [])
    }

    func testEmptyQueryAndEmptyIndexAreSafe() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        XCTAssertEqual(try await index.search("", limit: 10), [])
        XCTAssertEqual(try await index.search("   ", limit: 10), [])
        XCTAssertEqual(try await index.search("missing", limit: 10), [])
    }
}
