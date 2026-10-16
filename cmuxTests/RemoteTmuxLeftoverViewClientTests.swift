import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A reconnect kills the local transport. Over a transport whose remote half outlives
/// its client, the old `tmux -CC` client stays attached to the view, one more per
/// reconnect (74 on one host, most of them days old). The new stream detaches them.
@Suite struct RemoteTmuxLeftoverViewClientTests {
    private let view = "cmux-view-v1-OWNER-abc"

    @Test func detachesOtherControlClientsOnTheView() {
        let rows = [
            "/dev/pts/3 1 \(view)",
            "/dev/pts/9 1 \(view)",
            "/dev/pts/12 1 \(view)",
        ]
        #expect(RemoteTmuxViewConnection.leftoverViewClients(
            rows: rows, viewSessionName: view, ownClientName: "/dev/pts/12") == ["/dev/pts/3", "/dev/pts/9"])
    }

    @Test func leavesClientsOnOtherSessionsAlone() {
        let rows = [
            "/dev/pts/1 0 main",
            "/dev/pts/2 1 main",
            "/dev/pts/4 1 cmux-view-v1-OTHER-def",
            "/dev/pts/5 1 \(view)",
        ]
        #expect(RemoteTmuxViewConnection.leftoverViewClients(
            rows: rows, viewSessionName: view, ownClientName: "/dev/pts/5").isEmpty)
    }

    @Test func leavesAPersonAttachedToTheViewAlone() {
        // A terminal someone attached to the view by hand is not a control client.
        let rows = ["/dev/pts/6 0 \(view)", "/dev/pts/7 1 \(view)"]
        #expect(RemoteTmuxViewConnection.leftoverViewClients(
            rows: rows, viewSessionName: view, ownClientName: "/dev/pts/7").isEmpty)
    }

    @Test func detachesNothingWithoutItsOwnName() {
        // Without its own name the stream cannot tell itself from a leftover.
        let rows = ["/dev/pts/3 1 \(view)", "/dev/pts/9 1 \(view)"]
        #expect(RemoteTmuxViewConnection.leftoverViewClients(
            rows: rows, viewSessionName: view, ownClientName: "").isEmpty)
    }

    @Test func ignoresMalformedRows() {
        let rows = ["", "/dev/pts/3", "/dev/pts/4 1", "/dev/pts/5 1 \(view)"]
        #expect(RemoteTmuxViewConnection.leftoverViewClients(
            rows: rows, viewSessionName: view, ownClientName: "/dev/pts/9") == ["/dev/pts/5"])
    }
}

/// The leftover cleanup asks tmux for this stream's client name, then lists the clients. If the
/// stream reconnects between the two, the list comes from the new stream, where this install's
/// new client has a different name; comparing it with the old name would detach the new client.
@MainActor
@Suite struct RemoteTmuxLeftoverViewClientReconnectTests {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    }

    /// A writer whose pipe is drained into `sink`, like ssh reading the control client's stdin.
    private func attachWriter(_ conn: RemoteTmuxControlConnection, sink: Sink) -> (RemoteTmuxControlPipeWriter, Pipe) {
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { sink.append($0.availableData) }
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting, label: "remote-tmux-leftover-reconnect-test",
            maxPendingBytes: 1 << 20, onFailure: {})
        conn.installStdinWriterForTesting(writer)
        return (writer, pipe)
    }

    /// Answers queued commands, giving `rawLines` to raw queries and an empty block to the rest.
    private func answerAll(_ conn: RemoteTmuxControlConnection, rawLines: [String]) {
        var number = 50
        while let kind = conn.pendingCommandKindsForTesting.first {
            let lines: [String]
            if case .rawQuery = kind { lines = rawLines } else { lines = [] }
            conn.handleMessageForTesting(.commandResult(commandNumber: number, lines: lines, isError: false))
            number += 1
        }
    }

    /// Waits until `condition` holds, or the deadline passes. Returns whether it held.
    private func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    @MainActor private final class Flag { var isSet = false }

    @Test func aReconnectBetweenTheNameAndTheClientListDetachesNothing() async {
        let host = RemoteTmuxHost(destination: "user@leftover-reconnect.test")
        let view = RemoteTmuxViewConnection(host: host, ownerId: "leftover-reconnect-owner")
        let viewName = view.view.sessionName
        let conn = RemoteTmuxControlConnection(host: host, sessionName: viewName)
        conn.isSharedViewStream = true
        view.connection = conn
        let oldSink = Sink()
        let (oldWriter, oldPipe) = attachWriter(conn, sink: oldSink)
        conn.handleMessageForTesting(.enter)
        conn.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
        answerAll(conn, rawLines: [])

        let done = Flag()
        let cleanup = Task { @MainActor in
            await view.detachLeftoverViewClients(conn)
            done.isSet = true
        }
        let asked = await waitUntil {
            conn.pendingCommandKindsForTesting.first.map { if case .rawQuery = $0 { true } else { false } } == true
        }
        #expect(asked, "the cleanup asked for its own client name")
        // tmux names the old stream's client, and the stream drops before the cleanup resumes.
        answerAll(conn, rawLines: ["/dev/pts/1"])
        conn.beginReconnecting()
        let newSink = Sink()
        let (newWriter, newPipe) = attachWriter(conn, sink: newSink)
        conn.handleMessageForTesting(.enter)
        conn.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
        // On the new stream this install's client is /dev/pts/2; /dev/pts/1 is the old one.
        // Answer whatever the cleanup asks the new stream until it finishes.
        let finished = await waitUntil {
            answerAll(conn, rawLines: ["/dev/pts/1 1 \(viewName)", "/dev/pts/2 1 \(viewName)"])
            return done.isSet
        }
        #expect(finished, "the cleanup finished")
        await cleanup.value
        // Everything the new stream wrote before this marker has been read once the marker has.
        #expect(conn.send("display-message -p end-of-test"))
        let deadline = ContinuousClock.now + .seconds(10)
        while !newSink.text.contains("end-of-test"), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(newSink.text.contains("end-of-test"), "the new stream's writes were read")

        #expect(!newSink.text.contains("detach-client"), "sent on the new stream: \(newSink.text)")
        #expect(!oldSink.text.contains("detach-client"))
        conn.stop()
        oldWriter.close(); newWriter.close()
        oldPipe.fileHandleForReading.readabilityHandler = nil
        newPipe.fileHandleForReading.readabilityHandler = nil
    }
}
