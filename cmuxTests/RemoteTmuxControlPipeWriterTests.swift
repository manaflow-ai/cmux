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
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-writer-budget-test",
            maxPendingBytes: budget,
            onFailure: {}
        )
        let finished = DispatchSemaphore(value: 0)
        writer.writeFinishedForTesting = { finished.signal() }
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
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting, label: "remote-tmux-writer-progress-test",
            maxPendingBytes: 8 << 20, stallLimit: .seconds(30), now: { clock.now() }, onFailure: {}
        )
        let finished = DispatchSemaphore(value: 0)
        writer.writeFinishedForTesting = { finished.signal() }

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
}
