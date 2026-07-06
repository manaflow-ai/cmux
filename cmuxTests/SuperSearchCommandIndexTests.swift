import XCTest
import CmuxAgentChat

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SuperSearchCommandIndexTests: XCTestCase {
    func testCommandAndOutputTokensRoute() async throws {
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
            sessionID: "session-command",
            batch: SuperSearchTestSupport.batch(
                appended: [
                    SuperSearchTestSupport.message(
                        seq: 7,
                        kind: .terminal(ChatTerminalCapture(
                            command: "mkfifo-zzq81",
                            output: "outtok-77x"
                        ))
                    )
                ],
                discoveredTitle: "Session"
            )
        )
        await indexer.flushNow(sessionID: "session-command")

        let commandHits = try await index.search("mkfifo-zzq81", limit: 10)
        XCTAssertEqual(commandHits.count, 1)
        XCTAssertEqual(commandHits.first?.kind, .command)
        XCTAssertEqual(commandHits.first?.workspaceID, routing.workspaceID)
        XCTAssertEqual(commandHits.first?.panelID, routing.panelID)

        let outputHits = try await index.search("outtok-77x", limit: 10)
        XCTAssertEqual(outputHits.count, 1)
        XCTAssertEqual(outputHits.first?.kind, .command)
        XCTAssertEqual(outputHits.first?.workspaceID, routing.workspaceID)
        XCTAssertEqual(outputHits.first?.panelID, routing.panelID)
    }

    func testCommandOutputIsLimitedToFirstFourThousandCharacters() async throws {
        let fixture = try SuperSearchTestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let index = try SearchIndex(databaseURL: fixture.databaseURL)
        let routing = SuperSearchTestSupport.makeRouting()
        let indexer = GlobalSearchTranscriptIndexer(
            index: index,
            routing: { _, _ in routing },
            debounce: .seconds(3600)
        )

        let prefix = String(repeating: "a", count: GlobalSearchIndexingLimits.maxCommandOutputCharacters)
        let output = prefix + " beyond-cap-token"
        await indexer.ingest(
            sessionID: "session-command-cap",
            batch: SuperSearchTestSupport.batch(
                appended: [
                    SuperSearchTestSupport.message(
                        seq: 1,
                        kind: .terminal(ChatTerminalCapture(
                            command: "echo capped-output",
                            output: output
                        ))
                    )
                ]
            )
        )
        await indexer.flushNow(sessionID: "session-command-cap")

        let truncatedHits = try await index.search("beyond-cap-token", limit: 10)
        XCTAssertEqual(truncatedHits, [])
        let hits = try await index.search("capped-output", limit: 10)
        XCTAssertEqual(hits.count, 1)
    }
}
