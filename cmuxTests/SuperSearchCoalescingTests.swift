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

        XCTAssertEqual(await index.upsertedDocuments.count, 0)

        await indexer.flushNow(sessionID: "session-burst")

        let documents = await index.upsertedDocuments
        XCTAssertLessThanOrEqual(documents.count, 8)
        XCTAssertEqual(Set(documents.map(\.id)).count, documents.count)
    }
}
