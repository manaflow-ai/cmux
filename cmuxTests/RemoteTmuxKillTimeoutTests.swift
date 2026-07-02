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

    /// Verifies `killSessions` returns when the SSH process itself hangs holding the pipe.
    ///
    /// Unlike the descendant case, here the process never exits on its own, so the
    /// hard timeout must terminate it and the poll-based pipe drains must observe
    /// cancellation within a tick rather than parking in a blocking `read(2)` forever.
    @Test func killSessionsReturnsWhenSSHItselfHangs() async throws {
        let root = try temporaryDirectory(prefix: "remote-tmux-hung-ssh")
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeSSH = root.appendingPathComponent("ssh")
        try writeExecutable(
            at: fakeSSH,
            contents: """
            #!/bin/sh
            exec sleep 30
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
        let completion = CompletionLatch()
        let workTask = Task.detached {
            await work()
            await completion.complete(.workFinished)
        }
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: .seconds(guardSeconds))
                await completion.complete(.timedOut)
            } catch {}
        }

        switch await completion.wait() {
        case .workFinished:
            timeoutTask.cancel()
        case .timedOut:
            workTask.cancel()
            Issue.record(
                "remote tmux kill did not return within \(guardSeconds)s after its timeout fired",
                sourceLocation: sourceLocation
            )
            throw TimedOutWaiting()
        }
    }

    /// Sentinel thrown by the guard task when the regression hangs.
    private struct TimedOutWaiting: Error {}

    /// One-shot completion race for the unstructured work and timeout tasks.
    private actor CompletionLatch {
        private var outcome: CompletionOutcome?
        private var continuation: CheckedContinuation<CompletionOutcome, Never>?

        func wait() async -> CompletionOutcome {
            if let outcome { return outcome }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func complete(_ outcome: CompletionOutcome) {
            guard self.outcome == nil else { return }
            self.outcome = outcome
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    private enum CompletionOutcome {
        case workFinished
        case timedOut
    }
}
