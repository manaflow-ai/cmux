import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PiSessionIndexTests: XCTestCase {
    // MARK: - Fixtures

    private func makeFixture() throws -> (tempDir: URL, sessionsRoot: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-session-index-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        return (tempDir, sessionsRoot)
    }

    /// Build a pi session JSONL file at the canonical path for `cwd`. Returns the URL.
    @discardableResult
    private func writeSession(
        in sessionsRoot: URL,
        id: String,
        cwd: String,
        timestamp: String = "2026-05-05T15:00:00.000Z",
        version: Int = 3,
        sessionInfoName: String? = nil,
        firstUserMessage: String? = nil,
        latestModelChange: (provider: String, modelId: String)? = nil,
        modified: Date? = nil
    ) throws -> URL {
        let dirName = SessionIndexStore.piEncodedSessionDirName(cwd: cwd)
        let dir = sessionsRoot.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Filename: <iso-timestamp-with-: replaced>_<uuid>.jsonl
        let safeTs = timestamp
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let url = dir.appendingPathComponent("\(safeTs)_\(id).jsonl", isDirectory: false)

        var lines: [String] = []
        // Session header
        var header: [String: Any] = [
            "type": "session",
            "version": version,
            "id": id,
            "timestamp": timestamp,
            "cwd": cwd,
        ]
        lines.append(try jsonLine(header))

        // First user message (if any)
        if let firstUserMessage {
            let msgEntry: [String: Any] = [
                "type": "message",
                "id": "msg-\(UUID().uuidString.prefix(8))",
                "parentId": NSNull(),
                "timestamp": timestamp,
                "message": [
                    "role": "user",
                    "content": firstUserMessage,
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                ],
            ]
            lines.append(try jsonLine(msgEntry))
        }

        // Latest model change (if any)
        if let latestModelChange {
            let mc: [String: Any] = [
                "type": "model_change",
                "id": "mc-\(UUID().uuidString.prefix(8))",
                "parentId": NSNull(),
                "timestamp": timestamp,
                "provider": latestModelChange.provider,
                "modelId": latestModelChange.modelId,
            ]
            lines.append(try jsonLine(mc))
        }

        // session_info (if name set; goes LAST so test verifies "last wins")
        if let sessionInfoName {
            let info: [String: Any] = [
                "type": "session_info",
                "id": "info-\(UUID().uuidString.prefix(8))",
                "parentId": NSNull(),
                "timestamp": timestamp,
                "name": sessionInfoName,
            ]
            lines.append(try jsonLine(info))
        }

        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    private func jsonLine(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Cases

    func testParsesNamedSessionWithModelChangeAndCwd() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        try writeSession(
            in: fixture.sessionsRoot,
            id: "019dfabc-0001-7000-8000-000000000001",
            cwd: "/tmp/pi-vault-test",
            sessionInfoName: "Refactor the auth module",
            firstUserMessage: "Help me refactor src/auth.ts",
            latestModelChange: (provider: "anthropic", modelId: "claude-sonnet-4-5"),
            modified: Date(timeIntervalSince1970: 200)
        )

        let outcome = await SessionIndexStore.loadPiEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path
        )

        XCTAssertEqual(outcome.errors, [])
        let entry = try XCTUnwrap(outcome.entries.first)
        XCTAssertEqual(outcome.entries.count, 1)
        XCTAssertEqual(entry.agent, .pi)
        XCTAssertEqual(entry.sessionId, "019dfabc-0001-7000-8000-000000000001")
        XCTAssertEqual(entry.title, "Refactor the auth module")
        XCTAssertEqual(entry.cwd, "/tmp/pi-vault-test")

        // Resume command shape — note shellQuote leaves alphanumerics + `_./:=+-`
        // unquoted, so the bare uuid, simple model strings, AND the cwd
        // (only `/`, `-`, alphanumerics) all come out unquoted.
        XCTAssertEqual(
            entry.resumeCommand,
            "pi --session 019dfabc-0001-7000-8000-000000000001 --provider anthropic --model claude-sonnet-4-5"
        )
        XCTAssertEqual(
            entry.resumeCommandWithCwd,
            "cd /tmp/pi-vault-test && pi --session 019dfabc-0001-7000-8000-000000000001 --provider anthropic --model claude-sonnet-4-5"
        )
    }

    func testFallsBackToFirstUserMessageWhenNoSessionInfoName() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        try writeSession(
            in: fixture.sessionsRoot,
            id: "019dfabc-0001-7000-8000-000000000002",
            cwd: "/tmp/pi-vault-test",
            firstUserMessage: "How do I refactor this codebase to use a different state machine library?",
            latestModelChange: (provider: "anthropic", modelId: "claude-sonnet-4-5")
        )

        let outcome = await SessionIndexStore.loadPiEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path
        )

        XCTAssertEqual(outcome.errors, [])
        let entry = try XCTUnwrap(outcome.entries.first)
        XCTAssertEqual(
            entry.title,
            "How do I refactor this codebase to use a different state machine library?"
        )
    }

    func testTruncatesLongFirstUserMessageTitleToEightyChars() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let longMessage = String(repeating: "abcdefghij", count: 10) // 100 chars
        try writeSession(
            in: fixture.sessionsRoot,
            id: "019dfabc-0001-7000-8000-000000000003",
            cwd: "/tmp/pi-vault-test",
            firstUserMessage: longMessage
        )

        let outcome = await SessionIndexStore.loadPiEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path
        )

        let entry = try XCTUnwrap(outcome.entries.first)
        // 80 chars + ellipsis
        XCTAssertEqual(entry.title.count, 81)
        XCTAssertTrue(entry.title.hasSuffix("\u{2026}"))
        XCTAssertEqual(String(entry.title.dropLast()), String(longMessage.prefix(80)))
    }

    func testSkipsFilesWithUnsupportedVersion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        try writeSession(
            in: fixture.sessionsRoot,
            id: "v3-ok",
            cwd: "/tmp/pi-vault-test",
            version: 3,
            sessionInfoName: "Good v3 session"
        )
        try writeSession(
            in: fixture.sessionsRoot,
            id: "v99-future",
            cwd: "/tmp/pi-vault-test",
            version: 99,
            sessionInfoName: "Future schema"
        )

        let outcome = await SessionIndexStore.loadPiEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path
        )

        XCTAssertEqual(outcome.errors, [])
        XCTAssertEqual(outcome.entries.count, 1)
        XCTAssertEqual(outcome.entries.first?.sessionId, "v3-ok")
    }

    func testSkipsFilesWithoutSessionHeader() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        // Plant a directory + jsonl that's missing the session header (e.g.
        // empty or starts with a stray message).
        let dir = fixture.sessionsRoot.appendingPathComponent("--Users-broken--", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("2026-05-05_broken.jsonl", isDirectory: false)
        try "".write(to: url, atomically: true, encoding: .utf8)

        let outcome = await SessionIndexStore.loadPiEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path
        )

        XCTAssertEqual(outcome.errors, [])
        XCTAssertEqual(outcome.entries, [])
    }

    func testEmptyJSONLProducesNoEntry() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let dir = fixture.sessionsRoot.appendingPathComponent("--Users-atin--", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("empty.jsonl")
        try Data().write(to: url)

        let outcome = await SessionIndexStore.loadPiEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path
        )

        XCTAssertEqual(outcome.entries, [])
        // Empty files are NOT recorded in the error bag — pi creates the
        // JSONL synchronously on session start but the header write isn't
        // necessarily atomic; flagging zero-byte files as parse errors
        // would surface transient init-state files as corruption.
        XCTAssertEqual(outcome.errors, [])
    }

    /// Regression: a file that exists with non-trivial bytes but no parseable
    /// session header (e.g. truncated mid-write, hand-edited, accidentally
    /// piped output) is recorded in the ErrorBag so the index UI can show
    /// a count + first path. Sibling loaders (RovoDev) record per-file
    /// inspect/read failures the same way.
    func testCorruptJSONLProducesErrorBagSummary() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let dir = fixture.sessionsRoot.appendingPathComponent("--tmp-corrupt--", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Two corrupt files: each has bytes but no `"type":"session"` line.
        let urlA = dir.appendingPathComponent("a.jsonl")
        let urlB = dir.appendingPathComponent("b.jsonl")
        try "not even json {{{".data(using: .utf8)!.write(to: urlA)
        try "{\"type\":\"message\"}\n".data(using: .utf8)!.write(to: urlB)

        // And one good file alongside, to confirm the good entry still ranks
        // and the error summary is additive (doesn't suppress success).
        try writeSession(
            in: fixture.sessionsRoot,
            id: "019dfabc-good",
            cwd: "/tmp/corrupt-mix",
            sessionInfoName: "Healthy session"
        )

        let outcome = await SessionIndexStore.loadPiEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path
        )

        XCTAssertEqual(outcome.entries.count, 1)
        XCTAssertEqual(outcome.entries.first?.title, "Healthy session")
        XCTAssertEqual(
            outcome.errors.count, 1,
            "Expected one summary line for the two corrupt files; got \(outcome.errors)"
        )
        let summary = outcome.errors.first ?? ""
        XCTAssertTrue(summary.hasPrefix("Pi: skipped 2 session file(s)"), "got: \(summary)")
        // The summary references one of the two corrupt paths so an operator
        // can locate the offender without depending on iteration order.
        XCTAssertTrue(
            summary.contains(urlA.path) || summary.contains(urlB.path),
            "summary should reference at least one offending path; got: \(summary)"
        )
    }

    func testCwdFilterRestrictsToMatchingDirectory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        try writeSession(
            in: fixture.sessionsRoot,
            id: "session-a",
            cwd: "/tmp/repo-a",
            sessionInfoName: "Repo A work"
        )
        try writeSession(
            in: fixture.sessionsRoot,
            id: "session-b",
            cwd: "/tmp/repo-b",
            sessionInfoName: "Repo B work"
        )

        let outcome = await SessionIndexStore.loadPiEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path,
            cwdFilter: "/tmp/repo-b"
        )

        XCTAssertEqual(outcome.errors, [])
        XCTAssertEqual(outcome.entries.count, 1)
        XCTAssertEqual(outcome.entries.first?.title, "Repo B work")
        XCTAssertEqual(outcome.entries.first?.cwd, "/tmp/repo-b")
    }

    /// Regression: cwd-scoped scan with a populated encoded dir must NOT
    /// also walk every other top-level dir under sessionsRoot.
    ///
    /// Before the fix, the second scan was unconditional and produced a
    /// global mtime-sorted candidate list that, with searchMaxFiles=1500,
    /// could evict older sessions from the *requested* cwd. This test
    /// pins the requested cwd's older session as still being returned
    /// even when sessions in an unrelated cwd have newer mtimes.
    func testCwdFilterDoesNotEvictOlderRequestedSessionsForNewerForeignOnes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        // Older session in the requested cwd.
        try writeSession(
            in: fixture.sessionsRoot,
            id: "session-requested-old",
            cwd: "/tmp/requested-cwd",
            sessionInfoName: "Older requested-cwd session",
            modified: Date(timeIntervalSince1970: 1_000)
        )
        // Many newer sessions in an unrelated cwd. Pre-fix, these would
        // outrank the older requested-cwd session in the global mtime
        // sort and could push it past the searchMaxFiles cap.
        for index in 0..<5 {
            try writeSession(
                in: fixture.sessionsRoot,
                id: "session-other-\(index)",
                cwd: "/tmp/other-cwd",
                sessionInfoName: "Other-cwd session \(index)",
                modified: Date(timeIntervalSince1970: 10_000 + TimeInterval(index))
            )
        }

        let outcome = await SessionIndexStore.loadPiEntriesForTesting(
            sessionsRoot: fixture.sessionsRoot.path,
            cwdFilter: "/tmp/requested-cwd"
        )

        XCTAssertEqual(outcome.errors, [])
        XCTAssertEqual(outcome.entries.count, 1, "only the requested cwd's session should be returned")
        XCTAssertEqual(outcome.entries.first?.cwd, "/tmp/requested-cwd")
        XCTAssertEqual(outcome.entries.first?.title, "Older requested-cwd session")
    }

    func testMissingRootIsEmptyWithoutError() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let missingRoot = fixture.tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let outcome = await SessionIndexStore.loadPiEntriesForTesting(
            sessionsRoot: missingRoot.path
        )

        XCTAssertEqual(outcome.entries, [])
        XCTAssertEqual(outcome.errors, [])
    }

    func testEncodedDirNameMatchesPiConvention() {
        XCTAssertEqual(
            SessionIndexStore.piEncodedSessionDirName(cwd: "/Users/atin/projects/workbench"),
            "--Users-atin-projects-workbench--"
        )
        XCTAssertEqual(
            SessionIndexStore.piEncodedSessionDirName(cwd: "/Users/atin"),
            "--Users-atin--"
        )
        // Windows-style separators and `:` get the same `-` treatment.
        // Each char is replaced individually: `:` → `-`, `\` → `-`, so
        // "C:\Users\atin" → "C--Users-atin" (a literal mirror of pi's
        // session-manager.js encoder; `replace(/[/\\:]/g, "-")` runs
        // per-character with no collapsing).
        XCTAssertEqual(
            SessionIndexStore.piEncodedSessionDirName(cwd: "C:\\Users\\atin"),
            "--C--Users-atin--"
        )
    }
}
