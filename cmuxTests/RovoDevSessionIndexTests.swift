import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RovoDevSessionIndexTests: XCTestCase {
    func testRovoDevSessionIndexReadsMetadataAndResumeCommand() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        try writeSession(
            in: fixture.sessionsRoot,
            id: "older-session",
            title: "Unrelated chat",
            cwd: "/tmp/other repo",
            modified: Date(timeIntervalSince1970: 100)
        )
        try writeSession(
            in: fixture.sessionsRoot,
            id: "session with space",
            title: "Ship Rovo Dev support",
            cwd: "/tmp/rovo repo",
            modified: Date(timeIntervalSince1970: 200)
        )

        let outcome = SessionIndexStore.loadRovoDevEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path,
            needle: "ROVO",
            cwdFilter: "/tmp/rovo repo"
        )

        XCTAssertEqual(outcome.errors, [])
        let entry = try XCTUnwrap(outcome.entries.first)
        XCTAssertEqual(outcome.entries.count, 1)
        XCTAssertEqual(entry.agent, .rovodev)
        XCTAssertEqual(entry.sessionId, "session with space")
        XCTAssertEqual(entry.title, "Ship Rovo Dev support")
        XCTAssertEqual(entry.cwd, "/tmp/rovo repo")
        XCTAssertEqual(entry.fileURL?.lastPathComponent, "session_context.json")
        XCTAssertEqual(entry.resumeCommand, "acli rovodev run --restore 'session with space'")
        XCTAssertEqual(
            entry.resumeCommandWithCwd,
            "cd '/tmp/rovo repo' && acli rovodev run --restore 'session with space'"
        )
    }

    func testRovoDevSessionIndexReportsMalformedMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let sessionDir = fixture.sessionsRoot.appendingPathComponent("broken-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        try Data("{".utf8).write(to: metadataURL)

        let outcome = SessionIndexStore.loadRovoDevEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path
        )

        XCTAssertEqual(outcome.entries, [])
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertTrue(outcome.errors[0].contains("Rovo Dev: cannot read metadata"))
        XCTAssertTrue(outcome.errors[0].contains("metadata.json"))
    }

    func testRovoDevSessionIndexMissingRootIsEmptyWithoutError() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let missingRoot = fixture.tempDir.appendingPathComponent("missing", isDirectory: true)
        let outcome = SessionIndexStore.loadRovoDevEntriesForTesting(
            sessionsRoot: missingRoot.path
        )

        XCTAssertEqual(outcome.entries, [])
        XCTAssertEqual(outcome.errors, [])
    }

    private func makeFixture() throws -> (tempDir: URL, sessionsRoot: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-session-index-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        return (tempDir, sessionsRoot)
    }

    private func writeSession(
        in sessionsRoot: URL,
        id: String,
        title: String,
        cwd: String,
        modified: Date
    ) throws {
        let sessionDir = sessionsRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        let data = try JSONSerialization.data(
            withJSONObject: [
                "title": title,
                "workspace_path": cwd,
            ],
            options: [.sortedKeys]
        )
        try data.write(to: metadataURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: metadataURL.path
        )

        let sessionContextURL = sessionDir.appendingPathComponent("session_context.json")
        try Data(#"{"messages":[]}"#.utf8).write(to: sessionContextURL)
    }
}
