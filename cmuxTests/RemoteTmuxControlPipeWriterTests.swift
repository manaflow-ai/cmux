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
