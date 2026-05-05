import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class DeepSeekTUISessionIndexTests: XCTestCase {
    func testDeepSeekTUISessionIndexReadsMetadataAndResumeCommand() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        try writeSession(
            in: fixture.sessionsRoot,
            id: "older-session",
            title: "Unrelated chat",
            workspace: "/tmp/other repo",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try writeSession(
            in: fixture.sessionsRoot,
            id: "session with space",
            title: "Ship DeepSeek-TUI support",
            workspace: "/tmp/deepseek repo",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let outcome = SessionIndexStore.loadDeepSeekTUIEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path,
            needle: "deepseek",
            cwdFilter: "/tmp/deepseek repo"
        )

        XCTAssertEqual(outcome.errors, [])
        let entry = try XCTUnwrap(outcome.entries.first)
        XCTAssertEqual(outcome.entries.count, 1)
        XCTAssertEqual(entry.agent, .deepseekTUI)
        XCTAssertEqual(entry.sessionId, "session with space")
        XCTAssertEqual(entry.title, "Ship DeepSeek-TUI support")
        XCTAssertEqual(entry.cwd, "/tmp/deepseek repo")
        XCTAssertEqual(entry.fileURL?.lastPathComponent, "session with space.json")
        XCTAssertEqual(entry.resumeCommand, "deepseek resume 'session with space'")
        XCTAssertEqual(
            entry.resumeCommandWithCwd,
            "cd '/tmp/deepseek repo' && deepseek resume 'session with space'"
        )
    }

    func testDeepSeekTUISessionIndexReportsMalformedMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let sessionURL = fixture.sessionsRoot.appendingPathComponent("broken-session.json")
        try Data("{".utf8).write(to: sessionURL)

        let outcome = SessionIndexStore.loadDeepSeekTUIEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path
        )

        XCTAssertEqual(outcome.entries, [])
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertTrue(outcome.errors[0].contains("DeepSeek-TUI: cannot read session"))
        XCTAssertTrue(outcome.errors[0].contains("broken-session.json"))
    }

    func testDeepSeekTUISessionIndexMissingRootIsEmptyWithoutError() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let missingRoot = fixture.tempDir.appendingPathComponent("missing", isDirectory: true)
        let outcome = SessionIndexStore.loadDeepSeekTUIEntriesForTesting(
            sessionsRoot: missingRoot.path
        )

        XCTAssertEqual(outcome.entries, [])
        XCTAssertEqual(outcome.errors, [])
    }

    private func makeFixture() throws -> (tempDir: URL, sessionsRoot: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-deepseek-tui-session-index-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        return (tempDir, sessionsRoot)
    }

    private func writeSession(
        in sessionsRoot: URL,
        id: String,
        title: String,
        workspace: String,
        updatedAt: Date
    ) throws {
        let sessionURL = sessionsRoot.appendingPathComponent("\(id).json")
        let dateString = Self.iso8601.string(from: updatedAt)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "metadata": [
                    "id": id,
                    "title": title,
                    "created_at": dateString,
                    "updated_at": dateString,
                    "message_count": 2,
                    "total_tokens": 42,
                    "model": "deepseek-chat",
                    "workspace": workspace,
                    "mode": "agent",
                ],
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "text",
                                "text": "hello",
                            ],
                        ],
                    ],
                ],
            ],
            options: [.sortedKeys]
        )
        try data.write(to: sessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: updatedAt],
            ofItemAtPath: sessionURL.path
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
