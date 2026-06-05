import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AmpSessionIndexTests: XCTestCase {
    func testReadsHookStoreSortedFilteredWithResumeCommand() throws {
        let storeURL = try writeStore([
            "T-older": [
                "sessionId": "T-older",
                "cwd": "/tmp/other repo",
                "updatedAt": 100.0,
            ],
            "T-newer": [
                "sessionId": "T-newer",
                "cwd": "/tmp/amp repo",
                "updatedAt": 200.0,
            ],
        ])
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        // No filter: newest first.
        let all = SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL)
        XCTAssertEqual(all.errors, [])
        XCTAssertEqual(all.entries.map(\.sessionId), ["T-newer", "T-older"])
        XCTAssertTrue(all.entries.allSatisfy { $0.agent == .amp })

        // cwd filter narrows to a single session and builds the documented resume command.
        let filtered = SessionIndexStore.loadAmpEntriesForTesting(
            storeURL: storeURL,
            cwdFilter: "/tmp/amp repo"
        )
        let entry = try XCTUnwrap(filtered.entries.first)
        XCTAssertEqual(filtered.entries.count, 1)
        XCTAssertEqual(entry.sessionId, "T-newer")
        XCTAssertEqual(entry.cwd, "/tmp/amp repo")
        XCTAssertNil(entry.fileURL)
        // Title is synthesized from the cwd basename (Amp has no local title).
        XCTAssertEqual(entry.title, "Amp session in amp repo")
        let resume = try XCTUnwrap(entry.resumeCommand)
        XCTAssertTrue(
            resume.hasSuffix("amp threads continue T-newer"),
            "unexpected resume command: \(resume)"
        )
        XCTAssertTrue(resume.contains("/tmp/amp repo"), "resume should cd into the cwd: \(resume)")
    }

    func testResumeCommandWithoutCwd() throws {
        // Whitespace-containing id so the assertion independently verifies
        // shell-quoting rather than echoing SessionEntry.shellQuote back.
        let storeURL = try writeStore([
            "T nocwd": ["sessionId": "T nocwd", "updatedAt": 50.0],
        ])
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let entry = try XCTUnwrap(SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL).entries.first)
        XCTAssertNil(entry.cwd)
        XCTAssertEqual(entry.title, "Amp session")
        XCTAssertEqual(entry.resumeCommand, "amp threads continue 'T nocwd'")
    }

    func testPrefersRecordTitleWhenPresent() throws {
        let storeURL = try writeStore([
            "T-titled": [
                "sessionId": "T-titled",
                "cwd": "/tmp/repo",
                "title": "Ship Amp Session Index",
                "updatedAt": 10.0,
            ],
        ])
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let entry = try XCTUnwrap(SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL).entries.first)
        XCTAssertEqual(entry.title, "Ship Amp Session Index")
    }

    func testMalformedStoreReportsErrorWithoutCrashing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("amp-hook-sessions.json")
        try Data("{".utf8).write(to: storeURL)

        let outcome = SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL)
        XCTAssertEqual(outcome.entries, [])
        XCTAssertEqual(outcome.errors.count, 1)
        // Sanitized: generic copy, no internal filename or path.
        XCTAssertTrue(outcome.errors[0].contains("Amp: couldn't read saved sessions"))
        XCTAssertFalse(outcome.errors[0].contains(storeURL.path))
    }

    func testMissingStoreIsEmptyWithoutError() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-missing-\(UUID().uuidString)")
            .appendingPathComponent("amp-hook-sessions.json")
        let outcome = SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL)
        XCTAssertEqual(outcome.entries, [])
        XCTAssertEqual(outcome.errors, [])
    }

    private func writeStore(_ sessions: [String: [String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("amp-hook-sessions.json")
        let payload: [String: Any] = ["version": 1, "sessions": sessions]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: storeURL)
        return storeURL
    }
}
