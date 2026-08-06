import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SessionIndexJSONLReaderTests {
    enum ReadDirection: Sendable {
        case start
        case tail

        func read(url: URL) -> SessionIndexJSONLReadMetrics {
            switch self {
            case .start:
                SessionIndexJSONLReader().fromStart(url: url) { _ in false }
            case .tail:
                SessionIndexJSONLReader().fromTail(url: url, maxBytes: 64 * 1024) { _ in false }
            }
        }
    }

    private final class ReadResult: Sendable {
        private let storage = OSAllocatedUnfairLock<SessionIndexJSONLReadMetrics?>(initialState: nil)

        var value: SessionIndexJSONLReadMetrics? {
            storage.withLock { $0 }
        }

        func store(_ value: SessionIndexJSONLReadMetrics) {
            storage.withLock { $0 = value }
        }
    }

    @Test(
        "Reader rejects a FIFO without waiting for a writer",
        .timeLimit(.minutes(1)),
        arguments: [ReadDirection.start, .tail]
    )
    func readerRejectsFIFOWithoutBlocking(_ direction: ReadDirection) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-special-file-\(UUID().uuidString).fifo")
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(Darwin.mkfifo(url.path, 0o600) == 0)

        let result = ReadResult()
        let started = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            result.store(direction.read(url: url))
            completed.signal()
        }

        try #require(started.wait(timeout: .now() + 1) == .success)
        let returnedWithoutWriter = completed.wait(timeout: .now() + 1) == .success
        if !returnedWithoutWriter {
            let writerCompleted = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                let descriptor = Darwin.open(url.path, O_WRONLY)
                if descriptor >= 0 {
                    Darwin.close(descriptor)
                }
                writerCompleted.signal()
            }
            _ = completed.wait(timeout: .now() + 2)
            _ = writerCompleted.wait(timeout: .now() + 2)
        }

        #expect(returnedWithoutWriter)
        #expect(result.value == SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0))
    }

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
    func startReaderSkipsOversizedRecordAndContinuesToLaterMatch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-oversized-record-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let oversized = #"{"sessionId":"oversized","display":"\#(String(repeating: "x", count: 512))"}"#
        let matching = #"{"sessionId":"matching","display":"found after oversized record"}"#
        try Data((oversized + "\n" + matching + "\n").utf8).write(to: url)

        var visitedSessionIDs: [String] = []
        let metrics = SessionIndexJSONLReader(
            chunkSize: 31,
            maximumRecordBytes: 128
        ).fromStart(url: url) { object in
            if let sessionID = object["sessionId"] as? String {
                visitedSessionIDs.append(sessionID)
            }
            return false
        }

        #expect(visitedSessionIDs == ["matching"])
        #expect(metrics.recordsVisited == 2)
        #expect(metrics.bytesRead == Data((oversized + "\n" + matching + "\n").utf8).count)
    }

    @Test(arguments: [ReadDirection.start, .tail])
    func readerReportsMalformedRecords(_ direction: ReadDirection) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-malformed-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let history = [
            #"{"sessionId":"older"}"#,
            #"{"sessionId":"malformed""#,
            #"{"sessionId":"newer"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(history.utf8).write(to: url)

        let metrics = direction.read(url: url)

        #expect(metrics.recordsVisited == 3)
        #expect(metrics.didEncounterMalformedRecord)
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
    func tailPaginationKeepsReadingTheOpenedFileAfterPathReplacement() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-rotated-pages-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let originalSessionIDs = (0..<20).map { "original-\($0)" }
        let originalHistory = originalSessionIDs.map {
            #"{"sessionId":"\#($0)"}"#
        }.joined(separator: "\n") + "\n"
        try Data(originalHistory.utf8).write(to: url)

        var replacementError: Error?
        var didReplacePath = false
        var visitedSessionIDs: [String] = []
        let metrics = SessionIndexJSONLReader().fromTailPages(
            url: url,
            maxBytesPerPage: 80
        ) { object in
            if let sessionID = object["sessionId"] as? String {
                visitedSessionIDs.append(sessionID)
            }
            if !didReplacePath {
                didReplacePath = true
                do {
                    try Data("{\"sessionId\":\"replacement\"}\n".utf8).write(
                        to: url,
                        options: .atomic
                    )
                } catch {
                    replacementError = error
                    return true
                }
            }
            return false
        }

        try #require(replacementError == nil)
        #expect(Set(visitedSessionIDs) == Set(originalSessionIDs))
        #expect(!visitedSessionIDs.contains("replacement"))
        #expect(metrics.didReachStart)
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
