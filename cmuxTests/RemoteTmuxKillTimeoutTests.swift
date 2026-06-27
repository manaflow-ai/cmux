import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for remote tmux kill timeout behavior.
@Suite struct RemoteTmuxKillTimeoutTests {
    /// Verifies `killSessions` returns when an SSH descendant keeps output pipes open.
    @Test func killSessionsReturnsWhenSSHDescendantKeepsPipesOpen() async throws {
        let root = try temporaryDirectory(prefix: "remote-tmux-hung-kill")
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeSSH = root.appendingPathComponent("ssh")
        try writeExecutable(
            at: fakeSSH,
            contents: """
            #!/bin/sh
            sleep 3 &
            exit 0
            """
        )

        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@example.test"),
            sshExecutablePath: fakeSSH.path
        )

        try await expectCompletes(within: 1) {
            await RemoteTmuxSSHTransport.killSessions(
                [(transport: transport, target: "hung")],
                timeout: .milliseconds(100)
            )
        }
    }

    /// Creates a unique temporary directory for fake SSH executables.
    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes an executable shell script at `url`.
    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Fails the test if `work` does not complete before `guardSeconds`.
    private func expectCompletes(
        within guardSeconds: Double,
        _ work: @Sendable @escaping () async -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(guardSeconds))
                throw TimedOutWaiting()
            }
            do {
                _ = try await group.next()
                group.cancelAll()
            } catch is TimedOutWaiting {
                group.cancelAll()
                Issue.record(
                    "remote tmux kill did not return within \(guardSeconds)s after its timeout fired",
                    sourceLocation: sourceLocation
                )
                throw TimedOutWaiting()
            }
        }
    }

    /// Sentinel thrown by the guard task when the regression hangs.
    private struct TimedOutWaiting: Error {}
}
