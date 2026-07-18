import Foundation
import Testing
import CMUXAgentLaunch
import CmuxFoundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Codex transcript monitor manager", .serialized)
struct CodexTranscriptMonitorManagerTests {
    @Test func oneThousandStartsUseLinearAdmissionAndKeepEveryMonitor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-monitor-scale-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("pending.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"task_started"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = CodexTranscriptMonitorGateClock()
        let ownerResolver = CodexTranscriptMonitorOwnerResolverProbe()
        let manager = CodexTranscriptMonitorManager(
            maximumMonitorCount: 4_096,
            ownerCheckInterval: 3_600,
            admissionBatchDelay: .milliseconds(50),
            watcherRebuildDelay: .seconds(3_599),
            clock: clock,
            ownerResolver: { targets in
                await ownerResolver.resolve(targets)
            },
            eventSink: { _, _, _ in },
            watcherProvider: { _ in nil }
        )
        let startedAt = ContinuousClock.now
        for index in 0..<1_000 {
            let result = await manager.start(try request(
                sessionID: "session-\(index)",
                turnID: "turn-\(index)",
                transcriptPath: transcript.path
            ))
            guard case .started = result else {
                Issue.record("Unexpected admission result at \(index): \(result)")
                break
            }
        }

        #expect(await manager.activeMonitorCount() == 1_000)
        #expect(startedAt.duration(to: .now) < .seconds(10))
        await clock.waitForSleep(for: .milliseconds(50))
        #expect(await clock.sleeperCount(for: .milliseconds(50)) == 1)
        await clock.waitForSleep(for: .seconds(3_599))
        #expect(await clock.sleeperCount(for: .seconds(3_599)) == 1)
        await clock.waitForSleep(for: .seconds(3_600))
        #expect(await clock.sleeperCount(for: .seconds(3_600)) == 1)
        await clock.advance(.milliseconds(50))
        await ownerResolver.waitForBatchCount(1)
        #expect(await ownerResolver.batchSizes == [1_000])
        await manager.shutdown()
    }

    @Test func repeatedSameSessionReplacementStaysFastAndKeepsTheNewestTurn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-monitor-replacements-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("pending.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"task_started"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = makeManager()
        let startedAt = ContinuousClock.now
        for index in 0..<10_000 {
            _ = await manager.start(try request(
                sessionID: "one-session",
                turnID: "turn-\(index)",
                transcriptPath: transcript.path
            ))
        }

        #expect(await manager.activeMonitorCount() == 1)
        #expect(await manager.activeTurnID(sessionID: "one-session") == "turn-9999")
        #expect(startedAt.duration(to: .now) < .seconds(10))
        await manager.shutdown()
    }

    @Test func identicalRetryReplacesInPlaceWithoutDeletingItsLease() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-monitor-retry-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("pending.jsonl")
        let lease = root.appendingPathComponent("lease.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        try #"{"sessionId":"session-1","turnId":"turn-1","retiredAt":null}"#
            .write(to: lease, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = makeManager()
        let monitorRequest = try request(
            sessionID: "session-1",
            turnID: "turn-1",
            transcriptPath: transcript.path,
            leasePath: lease.path
        )
        _ = await manager.start(monitorRequest)
        let retry = await manager.start(monitorRequest)

        #expect(retry == .replaced(activeCount: 1))
        #expect(FileManager.default.fileExists(atPath: lease.path))
        await manager.scanNow()
        #expect(await manager.activeMonitorCount() == 1)
        await manager.shutdown()
    }

    @Test func transcriptEventsRemainFunctionalAfterThePromptCLIHasReturned() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-monitor-after-cli-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("pending.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let (events, continuation) = AsyncStream<CodexTranscriptMonitorUpdate>.makeStream()
        let manager = makeManager { _, _, update in continuation.yield(update) }
        _ = await manager.start(try request(
            sessionID: "session-1",
            turnID: "turn-1",
            transcriptPath: transcript.path
        ))
        await manager.scanNow()

        let inputLine = #"{"type":"event_msg","payload":{"type":"request_user_input","turn_id":"turn-1","call_id":"call-1","questions":[{"question":"Choose one"}]}}"#
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + inputLine + "\n").utf8))
        try handle.close()
        await manager.scanNow()

        var iterator = events.makeAsyncIterator()
        let update = await iterator.next()
        guard case .userInput(let input)? = update else {
            Issue.record("Expected a user-input update, saw \(String(describing: update))")
            await manager.shutdown()
            return
        }
        #expect(input.callID == "call-1")
        #expect(input.question == "Choose one")
        await manager.shutdown()
        continuation.finish()
    }

    @Test func actionableEventsUseTheSurfaceCurrentWorkspaceAfterAMove() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-monitor-moved-surface-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("pending.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let movedTarget = CodexTranscriptMonitorTarget(
            workspaceID: try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")),
            surfaceID: try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        )
        let eventProbe = CodexTranscriptMonitorEventProbe()
        let manager = makeManager(
            ownerResolver: { targets in
                targets.mapValues { _ in .alive(movedTarget) }
            },
            eventSink: { request, target, update in
                await eventProbe.record(request: request, target: target, update: update)
            }
        )
        _ = await manager.start(try request(
            sessionID: "session-1",
            turnID: "turn-1",
            transcriptPath: transcript.path
        ))
        await manager.refreshOwnersNow()

        let inputLine = #"{"type":"event_msg","payload":{"type":"request_user_input","turn_id":"turn-1","call_id":"call-1","questions":[{"question":"Choose one"}]}}"#
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + inputLine + "\n").utf8))
        try handle.close()
        await manager.scanNow()

        #expect(await eventProbe.targets == [movedTarget])
        await manager.shutdown()
    }

    @Test func discoversTheTranscriptUnderTheHooksCustomCodexHome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-monitor-custom-home-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("custom codex", isDirectory: true)
        var calendar = Calendar.current
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        let sessionDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", try #require(components.year)), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", try #require(components.month)), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", try #require(components.day)), isDirectory: true)
        let transcript = sessionDirectory.appendingPathComponent("rollout-session-custom.jsonl")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"turn-1","last_agent_message":"done"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = makeManager()
        _ = await manager.start(try request(
            sessionID: "session-custom",
            turnID: "turn-1",
            transcriptPath: nil,
            codexHome: codexHome.path
        ))
        await manager.scanNow()

        #expect(await manager.activeMonitorCount() == 0)
        await manager.shutdown()
    }

    @Test func capacityRejectsWithoutEvictingLiveMonitorsButReclaimsRetiredOnes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-monitor-capacity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("pending.jsonl")
        try #"{"type":"event_msg","payload":{"type":"task_started"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let firstLease = root.appendingPathComponent("first-lease.json")
        try #"{"retiredAt":null}"#.write(to: firstLease, atomically: true, encoding: .utf8)

        let manager = makeManager(maximumMonitorCount: 2)
        _ = await manager.start(try request(
            sessionID: "first", turnID: "one", transcriptPath: transcript.path, leasePath: firstLease.path
        ))
        _ = await manager.start(try request(
            sessionID: "second", turnID: "two", transcriptPath: transcript.path
        ))
        let rejected = await manager.start(try request(
            sessionID: "third", turnID: "three", transcriptPath: transcript.path
        ))
        #expect(rejected == .resourceExhausted(limit: 2))
        #expect(await manager.activeMonitorCount() == 2)

        try #"{"retiredAt":1}"#.write(to: firstLease, atomically: true, encoding: .utf8)
        let admitted = await manager.start(try request(
            sessionID: "third", turnID: "three", transcriptPath: transcript.path
        ))
        #expect(admitted == .started(activeCount: 2))
        #expect(await manager.activeMonitorCount() == 2)
        await manager.shutdown()
    }

    @Test func expiredMonitorsAreRemovedBeforeTheNextAdmission() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-monitor-expiry-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("pending.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"task_started"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let dateSource = CodexTranscriptMonitorDateSource(Date(timeIntervalSince1970: 1_000))
        let manager = CodexTranscriptMonitorManager(
            maximumMonitorAge: 60,
            ownerCheckInterval: 3_600,
            admissionBatchDelay: .seconds(3_600),
            watcherRebuildDelay: .seconds(3_600),
            now: { dateSource.value },
            ownerResolver: { targets in targets.mapValues { .alive($0) } },
            eventSink: { _, _, _ in },
            watcherProvider: { _ in nil }
        )
        _ = await manager.start(try request(
            sessionID: "expired", turnID: "old", transcriptPath: transcript.path
        ))
        dateSource.advance(by: 61)
        let result = await manager.start(try request(
            sessionID: "current", turnID: "new", transcriptPath: transcript.path
        ))

        #expect(result == .started(activeCount: 1))
        #expect(await manager.activeTurnID(sessionID: "expired") == nil)
        #expect(await manager.activeTurnID(sessionID: "current") == "new")
        await manager.shutdown()
    }

    @Test func shutdownCannotSignalAnUnrelatedProcess() async throws {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer {
            if unrelated.isRunning { unrelated.terminate() }
            unrelated.waitUntilExit()
        }

        let manager = makeManager()
        await manager.shutdown()
        #expect(unrelated.isRunning)
    }

    private func makeManager(
        maximumMonitorCount: Int = 4_096,
        ownerResolver: @escaping CodexTranscriptMonitorManager.OwnerResolver = { targets in
            targets.mapValues { .alive($0) }
        },
        eventSink: @escaping CodexTranscriptMonitorManager.EventSink = { _, _, _ in }
    ) -> CodexTranscriptMonitorManager {
        CodexTranscriptMonitorManager(
            maximumMonitorCount: maximumMonitorCount,
            ownerCheckInterval: 3_600,
            admissionBatchDelay: .seconds(3_600),
            watcherRebuildDelay: .seconds(3_600),
            ownerResolver: ownerResolver,
            eventSink: eventSink,
            watcherProvider: { _ in nil }
        )
    }

    private func request(
        sessionID: String,
        turnID: String,
        transcriptPath: String?,
        leasePath: String? = nil,
        codexHome: String? = nil
    ) throws -> CodexTranscriptMonitorRequest {
        try #require(CodexTranscriptMonitorRequest(
            sessionID: sessionID,
            turnID: turnID,
            transcriptPath: transcriptPath,
            workingDirectory: nil,
            workspaceID: "11111111-1111-1111-1111-111111111111",
            surfaceID: "22222222-2222-2222-2222-222222222222",
            leasePath: leasePath,
            homeDirectory: nil,
            codexHome: codexHome,
            stateDirectory: nil
        ))
    }
}

private actor CodexTranscriptMonitorOwnerResolverProbe {
    private(set) var batchSizes: [Int] = []
    private var batchWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func resolve(
        _ targets: [String: CodexTranscriptMonitorTarget]
    ) -> [String: CodexTranscriptMonitorOwnership] {
        batchSizes.append(targets.count)
        let ready = batchWaiters.filter { batchSizes.count >= $0.0 }
        batchWaiters.removeAll { batchSizes.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        return targets.mapValues { .alive($0) }
    }

    func waitForBatchCount(_ count: Int) async {
        guard batchSizes.count < count else { return }
        await withCheckedContinuation { continuation in
            batchWaiters.append((count, continuation))
        }
    }
}

private actor CodexTranscriptMonitorEventProbe {
    private(set) var targets: [CodexTranscriptMonitorTarget] = []

    func record(
        request _: CodexTranscriptMonitorRequest,
        target: CodexTranscriptMonitorTarget,
        update _: CodexTranscriptMonitorUpdate
    ) {
        targets.append(target)
    }
}

private actor CodexTranscriptMonitorGateClock: FileWatchClock {
    private struct Sleep {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct ArrivalWaiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Never>
    }

    private var sleeps: [UUID: Sleep] = [:]
    private var arrivalWaiters: [ArrivalWaiter] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleeps[id] = Sleep(duration: duration, continuation: continuation)
                resumeArrivalWaiters(for: duration)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitForSleep(for duration: Duration) async {
        guard !sleeps.values.contains(where: { $0.duration == duration }) else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(ArrivalWaiter(duration: duration, continuation: continuation))
        }
    }

    func sleeperCount(for duration: Duration) -> Int {
        sleeps.values.count { $0.duration == duration }
    }

    func advance(_ duration: Duration) {
        let readyIDs = sleeps.compactMap { id, sleep in
            sleep.duration == duration ? id : nil
        }
        for id in readyIDs {
            sleeps.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        sleeps.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func resumeArrivalWaiters(for duration: Duration) {
        let ready = arrivalWaiters.filter { $0.duration == duration }
        arrivalWaiters.removeAll { $0.duration == duration }
        for waiter in ready { waiter.continuation.resume() }
    }
}

private final class CodexTranscriptMonitorDateSource: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var value: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(interval)
        lock.unlock()
    }
}
