import XCTest
import CmuxAgentChat

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SuperSearchScopeTests: XCTestCase {
    func testUnstructuredScrollbackNotIndexed() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let routing = SuperSearchTestSupport.makeRouting()
        let indexer = GlobalSearchTranscriptIndexer(
            index: index,
            routing: { _, _ in routing },
            debounce: .seconds(3600)
        )

        await indexer.ingest(
            sessionID: "session-scope",
            batch: SuperSearchTestSupport.batch(
                appended: [
                    SuperSearchTestSupport.message(
                        seq: 1,
                        kind: .fileEdit(ChatFileEdit(
                            filePath: "/tmp/note.txt",
                            operation: .edit,
                            unifiedDiff: "rawscrolltoken"
                        ))
                    ),
                    SuperSearchTestSupport.message(
                        seq: 2,
                        kind: .permissionRequest(ChatPermissionRequest(
                            title: "Prompt",
                            subject: "rawscrolltoken"
                        ))
                    ),
                    SuperSearchTestSupport.message(
                        seq: 3,
                        kind: .attachment(ChatAttachment(
                            media: .file,
                            displayName: "rawscrolltoken"
                        ))
                    )
                ]
            )
        )
        await indexer.flushNow(sessionID: "session-scope")

        let hits = try await index.search("rawscrolltoken", limit: 10)
        XCTAssertEqual(hits, [])
    }
}
