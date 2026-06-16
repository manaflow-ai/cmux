import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Amp session index")
struct AmpSessionIndexTests {
    @Test func readsHookStoreSortedFilteredWithResumeCommand() throws {
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
                "launchCommand": [
                    "launcher": "amp",
                    "executablePath": "/opt/amp/bin/amp",
                    "arguments": [
                        "/opt/amp/bin/amp",
                        "threads",
                        "continue",
                        "T-old",
                        "-l",
                        "scratch",
                        "--mode",
                        "smart",
                        "--effort",
                        "high",
                    ],
                    "workingDirectory": "/tmp/amp repo",
                    "environment": [
                        "AMP_SETTINGS_FILE": "/tmp/amp-settings.json",
                        "OPENAI_API_KEY": "secret",
                    ],
                    "capturedAt": 123.0,
                    "source": "process",
                ],
            ],
        ])
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        // No filter: newest first.
        let all = SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL)
        #expect(all.errors == [])
        #expect(all.entries.map(\.sessionId) == ["T-newer", "T-older"])
        #expect(all.entries.allSatisfy { $0.agent == .amp })

        // cwd filter narrows to a single session and builds the documented resume command.
        let filtered = SessionIndexStore.loadAmpEntriesForTesting(
            storeURL: storeURL,
            cwdFilter: "/tmp/amp repo"
        )
        let entry = try #require(filtered.entries.first)
        #expect(filtered.entries.count == 1)
        #expect(entry.sessionId == "T-newer")
        #expect(entry.cwd == "/tmp/amp repo")
        #expect(entry.fileURL == nil)
        // Title is synthesized from the cwd basename (Amp has no local title).
        #expect(entry.title == "Amp session in amp repo")
        let resume = try #require(entry.resumeCommand)
        #expect(
            resume == "cd '/tmp/amp repo' && 'env' 'AMP_SETTINGS_FILE=/tmp/amp-settings.json' '/opt/amp/bin/amp' 'threads' 'continue' '--mode' 'smart' '--effort' 'high' 'T-newer'",
            "unexpected resume command: \(resume)"
        )
    }

    @Test func resumeCommandWithoutCwd() throws {
        // Whitespace-containing id so the assertion independently verifies
        // shell-quoting rather than echoing SessionEntry.shellQuote back.
        let storeURL = try writeStore([
            "T nocwd": ["sessionId": "T nocwd", "updatedAt": 50.0],
        ])
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let entry = try #require(SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL).entries.first)
        #expect(entry.cwd == nil)
        #expect(entry.title == "Amp session")
        #expect(entry.resumeCommand == "amp threads continue 'T nocwd'")
    }

    @Test func prefersRecordTitleWhenPresent() throws {
        let storeURL = try writeStore([
            "T-titled": [
                "sessionId": "T-titled",
                "cwd": "/tmp/repo",
                "title": "Ship Amp Session Index",
                "updatedAt": 10.0,
            ],
        ])
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let entry = try #require(SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL).entries.first)
        #expect(entry.title == "Ship Amp Session Index")
    }

    @Test func skipsTypeDriftedRecordsWithoutBlankingListing() throws {
        // One record has a type-drifted field (`cwd` as a number). The whole
        // listing must survive — only the bad record is dropped.
        let storeURL = try writeStore([
            "T-bad": ["sessionId": "T-bad", "cwd": 12345, "updatedAt": 300.0],
            "T-good": ["sessionId": "T-good", "cwd": "/tmp/good", "updatedAt": 200.0],
        ])
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let outcome = SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL)
        #expect(outcome.errors == [])
        #expect(outcome.entries.map(\.sessionId) == ["T-good"])
    }

    @Test func malformedStoreReportsErrorWithoutCrashing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("amp-hook-sessions.json")
        try Data("{".utf8).write(to: storeURL)

        let outcome = SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL)
        #expect(outcome.entries == [])
        #expect(outcome.errors.count == 1)
        // Sanitized: filename-only copy, no absolute path or decode detail.
        #expect(outcome.errors[0].contains("Amp: cannot read amp-hook-sessions.json"))
        #expect(!outcome.errors[0].contains(storeURL.path))
    }

    @Test func missingStoreIsEmptyWithoutError() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-missing-\(UUID().uuidString)")
            .appendingPathComponent("amp-hook-sessions.json")
        let outcome = SessionIndexStore.loadAmpEntriesForTesting(storeURL: storeURL)
        #expect(outcome.entries == [])
        #expect(outcome.errors == [])
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
