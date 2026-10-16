import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The control stream's stdin writer and the bursts it has to carry on a host with many
/// sessions and windows.
///
/// A host with 15 mirrored sessions reconnected every few seconds. Each attach queued a few
/// hundred KB of commands in one main-actor turn, the writer counted bytes the pipe had already
/// taken as still pending (they were only released by a main-actor task that the busy attach
/// had not run yet), and the 256 KiB budget tripped. The stream was torn down and the next
/// attach did the same thing.
@MainActor
@Suite struct RemoteTmuxControlPipeWriterTests {
    /// Bytes the pipe already took stop counting against the budget even while the main actor
    /// is busy. The whole test runs in one main-actor turn, which is what a long attach burst
    /// looks like to the writer.
    @Test func bytesThePipeTookFreeTheBudgetWhileTheMainActorIsBusy() {
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        let budget = 64 * 1024
        let finished = DispatchSemaphore(value: 0)
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-writer-budget-test",
            maxPendingBytes: budget,
            onWriteFinished: { finished.signal() },
            onFailure: {}
        )
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            writer.close()
        }

        let chunk = Data(repeating: UInt8(ascii: "x"), count: budget / 2)
        #expect(writer.enqueue(chunk))
        #expect(writer.enqueue(chunk))
        // Both writes return once the draining pipe has taken the bytes.
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(finished.wait(timeout: .now() + 10) == .success)

        #expect(
            writer.enqueue(chunk),
            "the pipe took the first two chunks, so a third fits in the budget"
        )
    }

    /// A clock the test moves by hand, so the stall limit is exercised without waiting it out.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private let start = ContinuousClock.now
        private var offset: Duration = .zero
        func set(_ value: Duration) { lock.lock(); offset = value; lock.unlock() }
        func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return start + offset }
    }

    /// Larger than any pipe buffer, so a write of it blocks until someone reads.
    private static let blockingSize = 1 << 20

    /// A pipe that takes no bytes for the stall limit is dead; before that it is only slow.
    @Test func aPipeThatStopsTakingBytesIsReportedDeadAfterTheStallLimit() throws {
        let pipe = Pipe()
        let clock = ManualClock()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting, label: "remote-tmux-writer-stall-test",
            maxPendingBytes: 8 << 20, stallLimit: .seconds(30), now: { clock.now() }, onFailure: {}
        )

        #expect(writer.enqueue(Data(count: Self.blockingSize)))
        clock.set(.seconds(29))
        #expect(writer.enqueue(Data("x\n".utf8)), "29 s without progress is a slow pipe, not a dead one")
        clock.set(.seconds(30))
        #expect(!writer.enqueue(Data("y\n".utf8)), "30 s without any write returning is a dead pipe")

        writer.close()
        _ = try pipe.fileHandleForReading.readToEnd()
    }

    /// Every write that returns is progress. A long transfer through a slow pipe keeps
    /// finishing writes, so it is never mistaken for a dead one, and an idle writer has
    /// nothing waiting that could stall.
    @Test func eachFinishedWriteRestartsTheStallLimit() throws {
        let pipe = Pipe()
        let clock = ManualClock()
        let finished = DispatchSemaphore(value: 0)
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting, label: "remote-tmux-writer-progress-test",
            maxPendingBytes: 8 << 20, stallLimit: .seconds(30), now: { clock.now() },
            onWriteFinished: { finished.signal() }, onFailure: {}
        )

        #expect(writer.enqueue(Data(count: Self.blockingSize)))
        #expect(writer.enqueue(Data(count: Self.blockingSize)))
        clock.set(.seconds(25))
        // Take the first payload; its write returns at t=25 while the second still waits.
        let reader = pipe.fileHandleForReading
        let firstTaken = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var taken = 0
            while taken < Self.blockingSize {
                let chunk = reader.readData(ofLength: Self.blockingSize - taken)
                if chunk.isEmpty { break }
                taken += chunk.count
            }
            firstTaken.signal()
        }
        #expect(firstTaken.wait(timeout: .now() + 10) == .success)
        #expect(finished.wait(timeout: .now() + 10) == .success)

        clock.set(.seconds(50))
        #expect(writer.enqueue(Data("x\n".utf8)), "the last write returned 25 s ago, under the limit")
        clock.set(.seconds(55))
        #expect(!writer.enqueue(Data("y\n".utf8)), "30 s since the last write returned")

        writer.close()
        _ = try reader.readToEnd()
    }

    /// Stands in for the writer's watchdog timer: records each arm, and fires on demand.
    private final class FakeScheduler: @unchecked Sendable {
        private struct Entry {
            let delay: Duration
            let action: @Sendable () -> Void
            var live = true
        }
        private let lock = NSLock()
        private var entries: [Entry] = []

        /// How many times a timer was armed.
        var armCount: Int {
            lock.lock(); defer { lock.unlock() }
            return entries.count
        }

        func schedule(_ delay: Duration, _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            lock.lock(); defer { lock.unlock() }
            entries.append(Entry(delay: delay, action: action))
            let index = entries.count - 1
            return { [self] in
                lock.lock(); entries[index].live = false; lock.unlock()
            }
        }

        /// Delays of the timers armed and not cancelled or fired.
        var armed: [Duration] {
            lock.lock(); defer { lock.unlock() }
            return entries.filter(\.live).map(\.delay)
        }

        /// Fires every timer ever armed, cancelled ones included: a cancel that lost a race
        /// with its timer must still do nothing.
        func fireEvenCancelled() {
            lock.lock()
            let actions = entries.map(\.action)
            entries.indices.forEach { entries[$0].live = false }
            lock.unlock()
            actions.forEach { $0() }
        }

        /// Fires every live timer once, as the clock reaching them would.
        func fireArmed() {
            lock.lock()
            let due = entries.indices.filter { entries[$0].live }
            due.forEach { entries[$0].live = false }
            let actions = due.map { entries[$0].action }
            lock.unlock()
            actions.forEach { $0() }
        }
    }

    /// Counts `onFailure` calls, which arrive on the main actor, and lets a test await a count
    /// with a deadline instead of guessing how long the delivery takes.
    @MainActor
    private final class FailureSignal {
        private(set) var value = 0
        private var waiters: [(count: Int, continuation: CheckedContinuation<Bool, Never>)] = []

        func record() {
            value += 1
            let ready = waiters.filter { $0.count <= value }
            waiters.removeAll { $0.count <= value }
            ready.forEach { $0.continuation.resume(returning: true) }
        }

        /// True once `count` failures have arrived; false if the deadline passes first.
        func wait(for count: Int, seconds: Double = 10) async -> Bool {
            if value >= count { return true }
            return await withCheckedContinuation { continuation in
                waiters.append((count, continuation))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard let self, let index = self.waiters.firstIndex(where: { $0.count == count }) else { return }
                    self.waiters.remove(at: index).continuation.resume(returning: false)
                }
            }
        }
    }

    /// A write that blocks with nothing else to send is still reported. The writer's own
    /// watchdog fires at the stall limit and reports the pipe dead, which reconnects; no
    /// further send is needed to notice.
    @Test func aBlockedWriteIsReportedWithoutAnotherSend() async throws {
        let pipe = Pipe()
        let clock = ManualClock()
        let scheduler = FakeScheduler()
        let failures = FailureSignal()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting, label: "remote-tmux-writer-watchdog-test",
            maxPendingBytes: 8 << 20, stallLimit: .seconds(30), now: { clock.now() },
            stallScheduler: scheduler.schedule, onFailure: { failures.record() }
        )

        #expect(writer.enqueue(Data(count: Self.blockingSize)))
        #expect(scheduler.armed == [.seconds(30)], "bytes started waiting, so the watchdog is armed")
        clock.set(.seconds(30))
        scheduler.fireArmed()
        #expect(await failures.wait(for: 1), "30 s with no write returning reports the pipe dead")
        #expect(failures.value == 1)

        writer.close()
        _ = try pipe.fileHandleForReading.readToEnd()
    }

    /// A write that returns is progress, and it moves the watchdog out to a full limit from then.
    @Test func aFinishedWritePushesTheWatchdogOut() async throws {
        let pipe = Pipe()
        let clock = ManualClock()
        let scheduler = FakeScheduler()
        let failures = FailureSignal()
        let finished = DispatchSemaphore(value: 0)
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting, label: "remote-tmux-writer-watchdog-progress-test",
            maxPendingBytes: 8 << 20, stallLimit: .seconds(30), now: { clock.now() },
            stallScheduler: scheduler.schedule,
            onWriteFinished: { finished.signal() }, onFailure: { failures.record() }
        )
        #expect(writer.enqueue(Data(count: Self.blockingSize)))
        #expect(writer.enqueue(Data(count: Self.blockingSize)))
        clock.set(.seconds(25))
        let reader = pipe.fileHandleForReading
        DispatchQueue.global().async {
            var taken = 0
            while taken < Self.blockingSize {
                let chunk = reader.readData(ofLength: Self.blockingSize - taken)
                if chunk.isEmpty { break }
                taken += chunk.count
            }
        }
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(scheduler.armed == [.seconds(30)], "the first write returned at 25 s and re-armed for a full limit")
        #expect(scheduler.armCount == 2, "armed when bytes started waiting, then again when a write returned")

        clock.set(.seconds(50))
        scheduler.fireArmed()
        // The firing decided synchronously: it re-armed for the time that remains rather than
        // reporting. Any report it had made would reach the main actor before the next one.
        #expect(scheduler.armed == [.seconds(5)], "the watchdog waits out the 5 s that remain")

        clock.set(.seconds(55))
        scheduler.fireArmed()
        #expect(await failures.wait(for: 1), "30 s since the last write returned")
        #expect(failures.value == 1, "the firing at 50 s, 25 s after the last write, reported nothing")

        writer.close()
        _ = try reader.readToEnd()
    }

    /// Nothing waiting means nothing to watch: a drained ledger and a closed writer cancel it.
    /// Both use a zero stall limit, so any firing that got past those checks would report.
    @Test func aDrainedOrClosedWriterCancelsTheWatchdog() async throws {
        let scheduler = FakeScheduler()
        let failures = FailureSignal()
        let drained = Pipe()
        drained.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        let finished = DispatchSemaphore(value: 0)
        let draining = RemoteTmuxControlPipeWriter(
            handle: drained.fileHandleForWriting, label: "remote-tmux-writer-watchdog-drain-test",
            maxPendingBytes: 8 << 20, stallLimit: .zero, stallScheduler: scheduler.schedule,
            onWriteFinished: { finished.signal() }, onFailure: { failures.record() }
        )
        #expect(draining.enqueue(Data("x\n".utf8)))
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(scheduler.armed.isEmpty, "the ledger drained, so the watchdog is cancelled")

        let blocked = Pipe()
        let closing = RemoteTmuxControlPipeWriter(
            handle: blocked.fileHandleForWriting, label: "remote-tmux-writer-watchdog-close-test",
            maxPendingBytes: 8 << 20, stallLimit: .zero, stallScheduler: scheduler.schedule,
            onFailure: { failures.record() }
        )
        #expect(closing.enqueue(Data(count: Self.blockingSize)))
        #expect(scheduler.armed.count == 1)
        closing.close()
        #expect(scheduler.armed.isEmpty, "closing the writer cancels its watchdog")
        // Even if those cancelled timers fire anyway, a drained writer (still open) or a closed
        // writer reports nothing.
        scheduler.fireEvenCancelled()

        // A witness that does stall, fired after them: its report reaches the main actor behind
        // any report the drained or closed writer made, so one failure means they made none.
        let witnessPipe = Pipe()
        let witnessScheduler = FakeScheduler()
        let witness = RemoteTmuxControlPipeWriter(
            handle: witnessPipe.fileHandleForWriting, label: "remote-tmux-writer-watchdog-witness-test",
            maxPendingBytes: 8 << 20, stallLimit: .zero, stallScheduler: witnessScheduler.schedule,
            onFailure: { failures.record() }
        )
        #expect(witness.enqueue(Data(count: Self.blockingSize)))
        witnessScheduler.fireArmed()
        #expect(await failures.wait(for: 1), "the witness's stall is reported")
        #expect(failures.value == 1, "the drained and the closed writer reported nothing")
        witness.close()
        draining.close()
        drained.fileHandleForReading.readabilityHandler = nil
        _ = try witnessPipe.fileHandleForReading.readToEnd()
        _ = try blocked.fileHandleForReading.readToEnd()
    }

    /// Unwritten bytes past the memory ceiling are refused even on a pipe that is moving.
    @Test func theMemoryCeilingStillHolds() throws {
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting, label: "remote-tmux-writer-ceiling-test",
            maxPendingBytes: Self.blockingSize * 2, onFailure: {}
        )
        #expect(writer.enqueue(Data(count: Self.blockingSize)))
        #expect(writer.enqueue(Data(count: Self.blockingSize)))
        #expect(!writer.enqueue(Data(count: 1)), "neither 1 MiB write can finish with nobody reading, so 2 MiB is still unwritten")
        writer.close()
        _ = try pipe.fileHandleForReading.readToEnd()
    }
}

/// Connection-level: every mirrored session publishing its identity at once, through the real
/// connection, its real writer budget, and real session channels.
@MainActor
@Suite struct RemoteTmuxManySessionStdinBurstTests {
    private struct Wire {
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
    }

    /// A connection in control mode whose attach is drained, writing into a pipe nobody reads
    /// until the test collects it.
    private func connectedWire() -> Wire {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@many-sessions.test"), sessionName: "view"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-many-session-burst",
            maxPendingBytes: RemoteTmuxControlConnection.maxPendingStdinBytes,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
        connection.pendingAttachRedrawKick = false
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 1, lines: ["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] main"], isError: false
        ))
        answerEverything(connection)
        return Wire(connection: connection, writer: writer, pipe: pipe)
    }

    private func answerEverything(_ connection: RemoteTmuxControlConnection) {
        var number = 2
        while let kind = connection.pendingCommandKindsForTesting.first {
            let lines: [String]
            if case .paneRects = kind { lines = ["%0 0 0 80 24 1 off :0 \"host\""] } else { lines = [] }
            connection.handleMessageForTesting(.commandResult(commandNumber: number, lines: lines, isError: false))
            number += 1
        }
    }

    private func collect(_ wire: Wire) throws -> [String] {
        wire.writer.close()
        let data = try wire.pipe.fileHandleForReading.readToEnd() ?? Data()
        try? wire.pipe.fileHandleForReading.close()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func makeChannels(_ connection: RemoteTmuxControlConnection, count: Int) -> [RemoteTmuxSessionChannel] {
        (1...count).map { index in
            RemoteTmuxSessionChannel(
                underlying: connection, sessionName: "s\(index)", sessionId: index, windowIds: [100 + index]
            )
        }
    }

    /// Fifteen or so sessions publish their identity in the same turn, as they do on every attach
    /// and reconnect. The connection is healthy, so it must stay up.
    @Test func everySessionPublishingAtOnceKeepsTheStreamUp() throws {
        let wire = connectedWire()
        let channels = makeChannels(wire.connection, count: 16)
        for channel in channels {
            channel.setMirrorEnvironment(["CMUX_WORKSPACE_ID": "workspace"])
        }

        #expect(wire.connection.connectionState == .connected)
        #expect(!wire.connection.snapshot().recentEvents.contains("stdin-write-backpressure"))
        let sent = try collect(wire)
        for index in 1...16 {
            #expect(sent.contains("set-environment -t $\(index) CMUX_REMOTE_TMUX_MIRROR '1'"))
        }
        channels.forEach { $0.detach() }
        wire.connection.stop()
    }

    /// A link slower than the burst leaves far more queued than the pipe holds: here every
    /// pane's seed commands at once, about 1.8 MB, into a pipe nobody reads yet. That is a
    /// slow pipe, not a dead one, so the stream stays up and every byte arrives in order.
    @Test func aBurstLargerThanThePipeHoldsKeepsTheStreamUp() throws {
        let wire = connectedWire()
        for paneId in 1...1_500 {
            wire.connection.seedPane(paneId: paneId, clearScrollback: true)
        }

        #expect(wire.connection.connectionState == .connected)
        #expect(wire.writer.unwrittenBytes > 256 * 1024, "the burst must outgrow what the pipe holds")
        let sent = try collect(wire)
        #expect(sent.contains { $0.contains("%1500") }, "the last pane's seed reached the pipe")
        wire.connection.stop()
    }

    /// The agent hook installer carries a 17 KB payload. Sending one copy per session made
    /// every attach of a 15-session host queue about 255 KB of the same bytes. Sessions that
    /// ask while an install is out wait for it and then share one payload.
    @Test func sessionsShareOneAgentHookInstallerPayload() throws {
        let wire = connectedWire()
        let channels = makeChannels(wire.connection, count: 16)
        for channel in channels {
            channel.setMirrorEnvironment(["CMUX_WORKSPACE_ID": "workspace"])
        }
        // tmux answers each command; the first install's answer releases the rest.
        answerEverything(wire.connection)

        let installs = try collect(wire).filter { $0.contains("'\\''--install'\\''") }
        // The first is the view session's own, sent and answered during the attach.
        let sessionInstalls = Array(installs.dropFirst())
        #expect(
            sessionInstalls.count == 2,
            "one install goes out at once and the other 15 sessions share the next"
        )
        for index in 1...16 {
            #expect(
                sessionInstalls.contains { $0.contains("'\\''$\(index)'\\''") },
                "session $\(index) is installed"
            )
        }
        channels.forEach { $0.detach() }
        wire.connection.stop()
    }
}
