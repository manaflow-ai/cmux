import CmuxRemoteSession
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A control stream that has been torn down for a reconnect must stop feeding the connection.
///
/// The stdout reader hands chunks to the connection through a buffered stream, and cancelling the
/// consumer does not empty that buffer. Whatever the old client had already written is still
/// delivered afterwards, into a connection that now belongs to the next client.
@MainActor
@Suite(.serialized, .exclusiveAppContext) struct RemoteTmuxReconnectStaleStreamTests {
    private let sshOverrideKey = "CMUX_REMOTE_TMUX_SSH_FOR_TESTING"

    @Test func bytesBufferedFromATornDownStreamAreNotIngested() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launchesURL = root.appendingPathComponent("launches")
        let wroteURL = root.appendingPathComponent("first-client-wrote")
        #expect(mkfifo(wroteURL.path, 0o600) == 0)

        // Each control client enters control mode and answers its own attach. The first one then
        // writes far more `%output` than a pipe holds, so the reader has to buffer it, and says
        // when it is done. Any other ssh call (a master exit, for one) succeeds and prints nothing.
        let sshURL = root.appendingPathComponent("ssh")
        try writeExecutable(
            at: sshURL,
            contents: """
            #!/bin/sh
            case "$*" in *-CC*) ;; *) exit 0 ;; esac
            echo launch >> '\(launchesURL.path)'
            launches=$(wc -l < '\(launchesURL.path)')
            printf '\\033P1000p%%begin 1 1 0\\n%%end 1 1 0\\n'
            if [ "$launches" -eq 1 ]; then
              i=0
              while [ "$i" -lt 4000 ]; do
                printf '%%output %%1 written-by-the-first-client-%0100d\\n' "$i"
                i=$((i + 1))
              done
              echo done > '\(wroteURL.path)'
            fi
            exec cat > /dev/null
            """
        )
        let previousSSH = getenv(sshOverrideKey).map { String(cString: $0) }
        setenv(sshOverrideKey, sshURL.path, 1)
        defer {
            if let previousSSH { setenv(sshOverrideKey, previousSSH, 1) } else { unsetenv(sshOverrideKey) }
        }

        let wroteFD = open(wroteURL.path, O_RDONLY | O_NONBLOCK)
        try #require(wroteFD >= 0)
        defer { close(wroteFD) }

        let host = RemoteTmuxHost(destination: "stale-\(UUID().uuidString)@example.test")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "dev")
        try connection.start()
        defer { connection.stop() }

        // The main actor is held from here to `beginReconnecting`, so the connection consumes
        // nothing in between: everything the first client wrote is still waiting in the buffer.
        var wrote = pollfd(fd: wroteFD, events: Int16(POLLIN), revents: 0)
        try #require(poll(&wrote, 1, 30_000) == 1, "the first client never finished writing")
        #expect(connection.snapshot().totalOutputBytes == 0)

        connection.beginReconnecting()
        let connected = await connection.waitUntilConnected()

        #expect(connected)
        let launches = (try? String(contentsOf: launchesURL, encoding: .utf8)) ?? ""
        #expect(
            launches.split(separator: "\n").count == 2,
            "the connection must come back through a second client, not through the first one's leftovers"
        )
        #expect(
            connection.snapshot().totalOutputBytes == 0,
            "pane output written by the torn-down client reached the connection"
        )
    }

    /// Output that piles up faster than the connection reads it is stale by the time it is read.
    ///
    /// A transport that held output through a network drop releases it all at once, and the reader
    /// then stops at its bound. Drawing every held byte before the current screen is what made the
    /// mirror take half a minute to show the end of a flood. The connection must instead drop the
    /// backlog for each pane and repaint the pane from tmux, the way a reconnect would, without
    /// leaving the connection.
    @Test(.timeLimit(.minutes(2))) func backlogPastTheReadBoundRepaintsPanesInsteadOfDrawingIt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-backlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goURL = root.appendingPathComponent("go")
        #expect(mkfifo(goURL.path, 0o600) == 0)

        // The control client enters control mode, answers its attach, and waits for the test. It
        // then writes far more pane %1 output than the reader may hold, then one line for pane %2,
        // which the test waits for. Commands from the connection are read and ignored.
        let floodURL = root.appendingPathComponent("flood.py")
        try writeExecutable(
            at: floodURL,
            contents: """
            import os, sys, threading
            def ignore_commands():
                while os.read(0, 65536):
                    pass
            reader = threading.Thread(target=ignore_commands, daemon=True)
            reader.start()
            def write_all(data):
                view = memoryview(data)
                while view:
                    view = view[os.write(1, view):]
            write_all(b"\\033P1000p%begin 1 1 0\\n%end 1 1 0\\n")
            with open(sys.argv[1], "rb") as f:
                f.read()
            block = (b"%output %1 " + b"x" * 1000 + b"\\n") * 64
            for _ in range((48 << 20) // len(block) + 1):
                write_all(block)
            write_all(b"%output %2 flood-end\\n")
            reader.join()
            """
        )
        let sshURL = root.appendingPathComponent("ssh")
        try writeExecutable(
            at: sshURL,
            contents: """
            #!/bin/sh
            case "$*" in *-CC*) ;; *) exit 0 ;; esac
            exec /usr/bin/env python3 -I '\(floodURL.path)' '\(goURL.path)'
            """
        )
        let previousSSH = getenv(sshOverrideKey).map { String(cString: $0) }
        setenv(sshOverrideKey, sshURL.path, 1)
        defer {
            if let previousSSH { setenv(sshOverrideKey, previousSSH, 1) } else { unsetenv(sshOverrideKey) }
        }

        // The reader says on its own queue when it stops at its bound, so the test can wait for
        // that while it holds the main actor.
        // The write handle lives as long as the reader holds the callback.
        let pauses = Pipe()
        let pauseWriter = pauses.fileHandleForWriting
        let host = RemoteTmuxHost(destination: "backlog-\(UUID().uuidString)@example.test")
        let connection = RemoteTmuxControlConnection(
            host: host,
            sessionName: "dev",
            onStdoutReaderPause: { try? pauseWriter.write(contentsOf: Data("p".utf8)) }
        )
        var paneOneBytes = 0
        let (floodEnded, floodEndedContinuation) = AsyncStream<Void>.makeStream()
        let token = connection.addObserver(onPaneOutput: { paneId, data in
            if paneId == 1 { paneOneBytes += data.count }
            if paneId == 2, String(decoding: data, as: UTF8.self).contains("flood-end") {
                floodEndedContinuation.yield()
            }
        })
        defer { connection.removeObserver(token) }
        try connection.start()
        defer { connection.stop() }
        #expect(await connection.waitUntilConnected())
        // The client never answers list-windows, so give the connection its one window here.
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(1))
        )

        let goFD = open(goURL.path, O_WRONLY)
        try #require(goFD >= 0)
        close(goFD)
        // The main actor is held until the reader has stopped at its bound, so the whole backlog
        // is waiting. The deadline only catches a reader that never stops.
        var paused = pollfd(fd: pauses.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        try #require(poll(&paused, 1, 60_000) == 1, "the reader never stopped at its bound")

        for await _ in floodEnded { break }

        let events = connection.snapshot().recentEvents
        #expect(connection.connectionState == .connected)
        #expect(!events.contains("reconnecting"))
        #expect(
            paneOneBytes < 4 << 20,
            "drew \(paneOneBytes) bytes of backlog instead of repainting the pane"
        )
        #expect(
            connection.pendingPaneSeeds[1]?.first?.kind == .fullHistory,
            "the pane was not repainted from tmux"
        )
        #expect(
            !events.contains { $0.hasPrefix("pane-seed-backpressure") || $0.hasPrefix("pane-seed-total-backpressure") },
            "the dropped backlog was retained against the seed budget: \(events)"
        )
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
