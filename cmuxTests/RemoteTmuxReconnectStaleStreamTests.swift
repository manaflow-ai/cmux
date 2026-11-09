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
        let fullURL = root.appendingPathComponent("full")
        #expect(mkfifo(goURL.path, 0o600) == 0)
        #expect(mkfifo(fullURL.path, 0o600) == 0)

        // The control client enters control mode, answers its attach, and waits for the test. It
        // then writes far more pane %1 output than the reader may hold, without blocking, and says
        // "full" once the pipe has stayed full for a second: the reader stopped at its bound. The
        // rest follows with ordinary blocking writes, then one line for pane %2, which the test
        // waits for. Commands from the connection are read and ignored.
        let floodURL = root.appendingPathComponent("flood.py")
        try writeExecutable(
            at: floodURL,
            contents: """
            import os, select, sys, threading
            go, full = sys.argv[1], sys.argv[2]
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
            with open(go, "rb") as f:
                f.read()
            block = memoryview((b"%output %1 " + b"x" * 1000 + b"\\n") * 64)
            total, written, offset, said_full = 48 << 20, 0, 0, False
            os.set_blocking(1, False)
            while written < total:
                try:
                    n = os.write(1, block[offset:])
                except BlockingIOError:
                    if said_full:
                        select.select([], [1], [])
                    elif not select.select([], [1], [], 1.0)[1]:
                        with open(full, "w") as f:
                            f.write("full\\n")
                        said_full = True
                    continue
                written += n
                offset = (offset + n) % len(block)
            os.set_blocking(1, True)
            if offset:
                write_all(block[offset:])
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
            exec /usr/bin/env python3 -I '\(floodURL.path)' '\(goURL.path)' '\(fullURL.path)'
            """
        )
        let previousSSH = getenv(sshOverrideKey).map { String(cString: $0) }
        setenv(sshOverrideKey, sshURL.path, 1)
        defer {
            if let previousSSH { setenv(sshOverrideKey, previousSSH, 1) } else { unsetenv(sshOverrideKey) }
        }

        let host = RemoteTmuxHost(destination: "backlog-\(UUID().uuidString)@example.test")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "dev")
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

        let fullFD = open(fullURL.path, O_RDONLY | O_NONBLOCK)
        try #require(fullFD >= 0)
        defer { close(fullFD) }
        let goFD = open(goURL.path, O_WRONLY)
        try #require(goFD >= 0)
        close(goFD)
        // The main actor is held until the reader has stopped, so the whole backlog is waiting.
        var full = pollfd(fd: fullFD, events: Int16(POLLIN), revents: 0)
        try #require(poll(&full, 1, 60_000) == 1, "the reader never stopped at its bound")

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
