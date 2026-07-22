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
    func startReaderParsesCompleteRecordEndingAtByteCap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-start-boundary-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let record = #"{"sessionId":"exact-cap"}"#
        try Data(record.utf8).write(to: url)

        var visitedSessionIDs: [String] = []
        let metrics = SessionIndexJSONLReader().fromStart(
            url: url,
            maxBytes: Data(record.utf8).count
        ) { object in
            if let sessionID = object["sessionId"] as? String {
                visitedSessionIDs.append(sessionID)
            }
            return false
        }

        #expect(visitedSessionIDs == ["exact-cap"])
        #expect(metrics.bytesRead == Data(record.utf8).count)
        #expect(metrics.recordsVisited == 1)
    }

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
    func antigravityShowMoreAndSearchPagePastTailCap() async throws {
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
        let expandedEntries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 100
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
        let oldPreviewEntry = SessionEntry(
            id: "antigravity:old-session",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "old-session",
            title: "Old",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: .distantPast,
            fileURL: url,
            specifics: .registered(registration)
        )
        let oldTurns = try await SessionTranscriptLoader.load(entry: oldPreviewEntry)

        #expect(initialEntries.map(\.sessionId) == ["active-session"])
        #expect(Set(expandedEntries.map(\.sessionId)) == ["active-session", "old-session"])
        let initialSection = IndexSection(
            key: .agent(.registered(RegisteredSessionAgent(registration: registration))),
            title: "Antigravity",
            icon: .agent(.registered(RegisteredSessionAgent(registration: registration))),
            entries: initialEntries
        )
        #expect(initialSection.shouldOfferShowMore(rowLimit: 5))
        #expect(entries.map(\.sessionId) == ["old-session"])
        #expect(turns.first?.role == .event)
        #expect(turns.last?.text == "latest prompt")
        #expect(oldTurns.contains { $0.text == "needle-old" })
    }

    @Test
    func antigravityReverseScanKeepsNewestMetadataWhenTimestampsAreMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-antigravity-equal-dates-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("history.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = """
        {"conversationId":"same-session","display":"older title","cwd":"/tmp/older"}
        {"conversationId":"same-session","display":"newest title","cwd":"/tmp/newest"}

        """
        try Data(history.utf8).write(to: url)

        var registration = CmuxVaultAgentRegistration.builtInAntigravity
        registration.sessionDirectory = root.path
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: SessionIndexStore.perAgentLimit
        )

        #expect(entries.count == 1)
        #expect(entries.first?.title == "newest title")
        #expect(entries.first?.cwd == "/tmp/newest")
    }

    @Test
    func antigravityPaginationIsStableWhenTimestampsAreMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-antigravity-stable-pages-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("history.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let olderSessionIDs = (0..<100).map { String(format: "a-%03d", $0) }
        let newerSessionIDs = (0..<100).map { String(format: "z-%03d", $0) }
        let history = (olderSessionIDs + newerSessionIDs).map { sessionID in
            #"{"conversationId":"\#(sessionID)","display":"\#(sessionID)"}"#
        }.joined(separator: "\n") + "\n"
        try Data(history.utf8).write(to: url)

        var registration = CmuxVaultAgentRegistration.builtInAntigravity
        registration.sessionDirectory = root.path
        let firstPage = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 100
        )
        let secondPage = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 100,
            limit: 100
        )
        let combinedSessionIDs = (firstPage + secondPage).map(\.sessionId)

        #expect(firstPage.count == 100)
        #expect(secondPage.count == 100)
        #expect(Set(combinedSessionIDs).count == 200)
    }
}
