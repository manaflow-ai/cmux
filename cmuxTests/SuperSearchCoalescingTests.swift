import XCTest
import CmuxAgentChat

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SuperSearchCoalescingTests: XCTestCase {
    func testBurstCoalescesToBoundedUpserts() async throws {
        let index = CountingSearchIndex()
        let routing = SuperSearchTestSupport.makeRouting()
        let indexer = GlobalSearchTranscriptIndexer(
            index: index,
            routing: { _, _ in routing },
            debounce: .seconds(3600)
        )

        for batchOrdinal in 0..<4 {
            let base = batchOrdinal * 50
            let messages = (0..<50).map { offset -> ChatMessage in
                let seq = base + offset
                if seq.isMultiple(of: 2) {
                    return SuperSearchTestSupport.message(
                        seq: seq,
                        kind: .prose(ChatProse(text: "prose-\(seq)"))
                    )
                }
                return SuperSearchTestSupport.message(
                    seq: seq,
                    kind: .terminal(ChatTerminalCapture(
                        command: "command-\(seq)",
                        output: "output-\(seq)"
                    ))
                )
            }
            await indexer.ingest(
                sessionID: "session-burst",
                batch: SuperSearchTestSupport.batch(appended: messages)
            )
        }

        let initialUpsertCount = await index.upsertedDocuments.count
        XCTAssertEqual(initialUpsertCount, 0)

        await indexer.flushNow(sessionID: "session-burst")

        let documents = await index.upsertedDocuments
        XCTAssertLessThanOrEqual(documents.count, 8)
        XCTAssertEqual(Set(documents.map(\.id)).count, documents.count)
    }

    func testChunkRetentionEvictsOldOrdinalsAndDeletesIndexedDocuments() async throws {
        let index = CountingSearchIndex()
        let routing = SuperSearchTestSupport.makeRouting()
        let indexer = GlobalSearchTranscriptIndexer(
            index: index,
            routing: { _, _ in routing },
            debounce: .seconds(3600)
        )

        let retainedCount = GlobalSearchIndexingLimits.maxTranscriptChunksPerSession
        let totalChunks = retainedCount + 2
        for ordinal in 0..<totalChunks {
            let base = ordinal * GlobalSearchTranscriptIndexer.messagesPerChunk
            let messages = (0..<GlobalSearchTranscriptIndexer.messagesPerChunk).map { offset in
                SuperSearchTestSupport.message(
                    seq: base + offset,
                    kind: .terminal(ChatTerminalCapture(
                        command: "retention-command-\(ordinal)-\(offset)",
                        output: "retention-output-\(ordinal)-\(offset)"
                    ))
                )
            }
            await indexer.ingest(
                sessionID: "session-retention",
                batch: SuperSearchTestSupport.batch(appended: messages)
            )
        }

        let trackedOrdinals = await indexer.trackedChunkOrdinals(sessionID: "session-retention")
        XCTAssertEqual(trackedOrdinals.count, retainedCount)
        XCTAssertEqual(trackedOrdinals, Array(2..<totalChunks))

        let deletedIDs = await index.deletedDocumentIDs
        XCTAssertTrue(deletedIDs.contains(
            GlobalSearchTranscriptDocuments.transcriptDocumentID(sessionID: "session-retention", ordinal: 0)
        ))
        XCTAssertTrue(deletedIDs.contains(
            GlobalSearchTranscriptDocuments.commandDocumentID(sessionID: "session-retention", ordinal: 0)
        ))
        XCTAssertTrue(deletedIDs.contains(
            GlobalSearchTranscriptDocuments.transcriptDocumentID(sessionID: "session-retention", ordinal: 1)
        ))
        XCTAssertTrue(deletedIDs.contains(
            GlobalSearchTranscriptDocuments.commandDocumentID(sessionID: "session-retention", ordinal: 1)
        ))
    }

    func testTranscriptChunkTextIsCappedAtConfiguredLimit() async throws {
        let index = CountingSearchIndex()
        let routing = SuperSearchTestSupport.makeRouting()
        let indexer = GlobalSearchTranscriptIndexer(
            index: index,
            routing: { _, _ in routing },
            debounce: .seconds(3600)
        )

        let oversizedText = String(
            repeating: "t",
            count: GlobalSearchIndexingLimits.maxTranscriptChunkCharacters + 500
        )
        await indexer.ingest(
            sessionID: "session-transcript-cap",
            batch: SuperSearchTestSupport.batch(
                appended: [
                    SuperSearchTestSupport.message(
                        seq: 1,
                        kind: .prose(ChatProse(text: oversizedText))
                    )
                ]
            )
        )
        await indexer.flushNow(sessionID: "session-transcript-cap")

        let documents = await index.upsertedDocuments
        let transcriptDocument = try XCTUnwrap(documents.first { $0.kind == .transcript })
        XCTAssertEqual(transcriptDocument.text.count, GlobalSearchIndexingLimits.maxTranscriptChunkCharacters)
    }
}
