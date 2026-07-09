import CmuxFoundation
import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class RipgrepSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [(pid_t, Int32)] = []

    func append(_ signal: (pid_t, Int32)) {
        lock.withLock {
            signals.append(signal)
        }
    }

    var snapshot: [(pid_t, Int32)] {
        lock.withLock { signals }
    }
}

final class RovoDevSessionIndexTests: XCTestCase {
    func testRipgrepCancellationDoesNotSignalBeforeProcessStarts() {
        let sentSignals = RipgrepSignalRecorder()
        let cancellation = RipgrepProcessCancellation { processIdentifier, signal in
            sentSignals.append((processIdentifier, signal))
            return 0
        }

        cancellation.cancel()

        XCTAssertTrue(sentSignals.snapshot.isEmpty)
    }

    func testRipgrepCancellationSignalsActiveProcess() {
        let sentSignals = RipgrepSignalRecorder()
        let cancellation = RipgrepProcessCancellation { processIdentifier, signal in
            sentSignals.append((processIdentifier, signal))
            return 0
        }

        cancellation.markStarted(processIdentifier: 12345)
        cancellation.cancel()
        cancellation.cancel()
        cancellation.markFinished(processIdentifier: 12345)
        cancellation.cancel()

        let signals = sentSignals.snapshot
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.0, 12345)
        XCTAssertEqual(signals.first?.1, SIGTERM)
    }

    func testRipgrepCancellationDoesNotResurrectFinishedProcess() {
        let sentSignals = RipgrepSignalRecorder()
        let cancellation = RipgrepProcessCancellation { processIdentifier, signal in
            sentSignals.append((processIdentifier, signal))
            return 0
        }

        cancellation.markFinished(processIdentifier: 12345)
        cancellation.markStarted(processIdentifier: 12345)
        cancellation.cancel()

        XCTAssertTrue(sentSignals.snapshot.isEmpty)
    }

    func testRipgrepMatchingPathsCancellationDoesNotReportFailure() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        // The fake rg touches a readiness marker as its first action, then
        // blocks. The test waits on that marker (the real "process has started"
        // signal) instead of guessing at a fixed sleep, so the cancellation
        // below deterministically lands while the launched process is running
        // and exercises the active-process SIGTERM path.
        let startedMarker = fixture.tempDir.appendingPathComponent("rg-started")
        let fakeRipgrep = fixture.tempDir.appendingPathComponent("rg")
        try """
        #!/bin/sh
        : > '\(startedMarker.path)'
        exec /bin/sleep 10
        """.write(to: fakeRipgrep, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeRipgrep.path
        )

        let task = Task {
            await SessionIndexStore.ripgrepMatchingPaths(
                needle: "needle",
                root: fixture.tempDir.path,
                fileGlob: "*.jsonl",
                ripgrepPath: fakeRipgrep.path
            )
        }
        try await waitForFile(at: startedMarker)
        task.cancel()

        let matches = await task.value

        XCTAssertEqual(matches, [])
    }

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
        XCTAssertEqual(
            entry.resumeCommand,
            "cd -- '/tmp/rovo repo' 2>/dev/null || [ ! -d '/tmp/rovo repo' ] && acli rovodev run --restore 'session with space'"
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

    /// Deadline-bounded wait on a real readiness predicate: returns the instant
    /// `url` exists, fails only if it never appears within `timeout`. Polls
    /// instead of sleeping a fixed duration so the caller proceeds as soon as
    /// the watched process signals readiness, with no timing race.
    private func waitForFile(
        at url: URL,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(
            "Timed out waiting for \(url.lastPathComponent) to appear",
            file: file,
            line: line
        )
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
