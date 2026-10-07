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
@Suite(.serialized) struct RemoteTmuxReconnectStaleStreamTests {
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

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
