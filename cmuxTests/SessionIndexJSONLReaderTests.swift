import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SessionIndexJSONLReaderTests {
    @Test
    func tailReaderReturnsNewestRecordsWithoutReadingTheWholeHistory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let padding = String(repeating: "x", count: 512)
        let history = (0..<2_000).map { index in
            "{\"sessionId\":\"session-\(index)\",\"display\":\"\(padding)\"}"
        }.joined(separator: "\n") + "\n"
        try Data(history.utf8).write(to: url)

        var visitedSessionIDs: [String] = []
        let byteLimit = 64 * 1024
        let metrics = SessionIndexJSONLReader().fromTail(
            url: url,
            maxBytes: byteLimit
        ) { object in
            if let sessionID = object["sessionId"] as? String {
                visitedSessionIDs.append(sessionID)
            }
            return visitedSessionIDs.count == 30
        }

        #expect(visitedSessionIDs.first == "session-1999")
        #expect(visitedSessionIDs.count == 30)
        #expect(metrics.bytesRead <= byteLimit)
        #expect(metrics.recordsVisited < 2_000)
        #expect(!metrics.didReachStart)
    }

    @Test
    func tailReaderPreservesRecordAtExactNewlineBoundary() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-boundary-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let older = "{\"sessionId\":\"older\"}\n"
        let newer = "{\"sessionId\":\"newer\"}\n"
        try Data((older + newer).utf8).write(to: url)

        var visitedSessionIDs: [String] = []
        let metrics = SessionIndexJSONLReader().fromTail(
            url: url,
            maxBytes: Data(newer.utf8).count + 1
        ) { object in
            if let sessionID = object["sessionId"] as? String {
                visitedSessionIDs.append(sessionID)
            }
            return false
        }

        #expect(visitedSessionIDs == ["newer"])
        #expect(!metrics.didReachStart)
    }

    @Test
    func antigravityTailPreviewPlacesTruncationBeforeVisibleTurns() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-antigravity-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let sessionID = "antigravity-session"
        let history = (0...500).map { index in
            "{\"conversationId\":\"\(sessionID)\",\"display\":\"prompt-\(index)\"}"
        }.joined(separator: "\n") + "\n"
        try Data(history.utf8).write(to: url)

        let entry = SessionEntry(
            id: "antigravity:\(url.path)",
            agent: .registered(RegisteredSessionAgent(id: "antigravity")),
            sessionId: sessionID,
            title: "Antigravity",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: .distantPast,
            fileURL: url,
            specifics: .rovodev
        )

        let turns = try await SessionTranscriptLoader.load(entry: entry)

        #expect(turns.first?.role == .event)
        #expect(
            turns.first?.text == String(
                localized: "sessionIndex.preview.truncated",
                defaultValue: "Preview truncated"
            )
        )
        #expect(turns.last?.text.contains("prompt-500") == true)
    }

    @Test
    func antigravitySearchPagesPastTailCapAndPreviewDisclosesOmittedHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-antigravity-pages-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("history.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var history = Data(#"{"conversationId":"old-session","display":"needle-old","timestamp":1}"#.utf8)
        history.append(0x0a)
        history.append(Data(#"{"conversationId":"padding","display":""#.utf8))
        history.append(Data(repeating: 0x78, count: SessionIndexStore.antigravityHistoryByteCap + 1_024))
        history.append(Data(#"","timestamp":2}"#.utf8))
        history.append(0x0a)
        history.append(Data(#"{"conversationId":"active-session","display":"latest prompt","timestamp":3}"#.utf8))
        history.append(0x0a)
        try history.write(to: url)

        var registration = CmuxVaultAgentRegistration.builtInAntigravity
        registration.sessionDirectory = root.path
        let initialEntries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: SessionIndexStore.perAgentLimit
        )
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "needle-old",
            cwdFilter: nil,
            offset: 0,
            limit: 1
        )
        let previewEntry = SessionEntry(
            id: "antigravity:active-session",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "active-session",
            title: "Active",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: .distantPast,
            fileURL: url,
            specifics: .registered(registration)
        )
        let turns = try await SessionTranscriptLoader.load(entry: previewEntry)

        #expect(initialEntries.map(\.sessionId) == ["active-session"])
        #expect(entries.map(\.sessionId) == ["old-session"])
        #expect(turns.first?.role == .event)
        #expect(turns.last?.text == "latest prompt")
    }
}
