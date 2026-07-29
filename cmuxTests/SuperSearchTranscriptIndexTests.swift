import XCTest
import CmuxAgentChat

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SuperSearchTranscriptIndexTests: XCTestCase {
    func testTranscriptBatchTokenRoutesToPanel() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let routing = SuperSearchTestSupport.makeRouting()
        let indexer = GlobalSearchTranscriptIndexer(
            index: index,
            routing: { _, _ in routing },
            debounce: .seconds(3600)
        )

        await indexer.updateSessionBinding(
            sessionID: "session-1",
            workspaceID: routing.workspaceID.uuidString,
            panelID: routing.panelID.uuidString,
            title: "Claude Session"
        )
        await indexer.ingest(
            sessionID: "session-1",
            batch: SuperSearchTestSupport.batch(
                appended: [
                    SuperSearchTestSupport.message(
                        seq: 1,
                        kind: .prose(ChatProse(text: "transcript-needle-unique"))
                    )
                ],
                discoveredTitle: "Claude Session"
            )
        )
        await indexer.flushNow(sessionID: "session-1")

        let hits = try await index.search("transcript-needle-unique", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.kind, .transcript)
        XCTAssertEqual(hits.first?.workspaceID, routing.workspaceID)
        XCTAssertEqual(hits.first?.panelID, routing.panelID)
        XCTAssertEqual(hits.first?.title, "Claude Session")
    }

    func testUnroutableTranscriptSessionSkipsIndexing() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let indexer = GlobalSearchTranscriptIndexer(
            index: index,
            routing: { _, _ in nil },
            debounce: .seconds(3600)
        )

        await indexer.ingest(
            sessionID: "session-2",
            batch: SuperSearchTestSupport.batch(
                appended: [
                    SuperSearchTestSupport.message(
                        seq: 3,
                        kind: .prose(ChatProse(text: "unroutable-transcript-token"))
                    )
                ]
            )
        )
        await indexer.flushNow(sessionID: "session-2")

        let hits = try await index.search("unroutable-transcript-token", limit: 10)
        XCTAssertEqual(hits, [])
    }

    func testTranscriptResetDeletesPreviousSessionDocuments() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let routing = SuperSearchTestSupport.makeRouting()
        let indexer = GlobalSearchTranscriptIndexer(
            index: index,
            routing: { _, _ in routing },
            debounce: .seconds(3600)
        )

        await indexer.updateSessionBinding(
            sessionID: "session-reset",
            workspaceID: routing.workspaceID.uuidString,
            panelID: routing.panelID.uuidString,
            title: "Session"
        )
        await indexer.ingest(
            sessionID: "session-reset",
            batch: SuperSearchTestSupport.batch(
                appended: [
                    SuperSearchTestSupport.message(
                        seq: 1,
                        kind: .prose(ChatProse(text: "before-reset-token"))
                    )
                ]
            )
        )
        await indexer.flushNow(sessionID: "session-reset")
        let indexedHits = try await index.search("before-reset-token", limit: 10)
        XCTAssertEqual(indexedHits.count, 1)

        await indexer.ingest(
            sessionID: "session-reset",
            batch: SuperSearchTestSupport.batch(didReset: true)
        )

        let hitsAfterReset = try await index.search("before-reset-token", limit: 10)
        XCTAssertEqual(hitsAfterReset, [])
    }
}
