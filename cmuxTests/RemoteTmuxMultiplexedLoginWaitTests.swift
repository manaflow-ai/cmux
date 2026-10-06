import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An attach over the shared connection that stops for a login hands the caller the interactive
/// sign-in and keeps its stream, so the retry after the login resumes that stream instead of
/// opening another connection. On a host that authenticates every connection, another connection
/// is another prompt.
@MainActor
@Suite(.serialized) struct RemoteTmuxMultiplexedLoginWaitTests {
    private let sshOverrideKey = "CMUX_REMOTE_TMUX_SSH_FOR_TESTING"

    @Test(.timeLimit(.minutes(2)))
    func anAttachThatStopsForALoginKeepsItsSharedStream() async throws {
        // The fake ssh is a process-wide override, so hold the app-context gate for the whole body:
        // another suite that suspends here must not start a connection through it.
        try await AppContextSerialGate.withExclusiveAppContext {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-login-wait-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            // A host that wants an interactive sign-in: every connection is refused the way ssh
            // refuses one in BatchMode when only keyboard-interactive is left.
            let sshURL = root.appendingPathComponent("ssh")
            try """
            #!/bin/sh
            echo 'user@login-wait.test: Permission denied (publickey,keyboard-interactive).' >&2
            exit 255
            """.write(to: sshURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sshURL.path)
            let previousSSH = getenv(sshOverrideKey).map { String(cString: $0) }
            setenv(sshOverrideKey, sshURL.path, 1)
            defer {
                if let previousSSH { setenv(sshOverrideKey, previousSSH, 1) } else { unsetenv(sshOverrideKey) }
            }

            let appDelegate = try #require(AppDelegate.shared)
            let controller = appDelegate.remoteTmuxController
            let host = RemoteTmuxHost(destination: "login-wait-\(UUID().uuidString)@example.test")
            defer { _ = controller.stopMultiplexedHost(host: host) }

            let outcome = try await controller.attachHostMultiplexed(
                host: host, windowTarget: .contextualWindow(nil), activate: false)

            guard case .authRequired = outcome else {
                Issue.record("a host that wants a sign-in should hand back the interactive login, got \(outcome)")
                return
            }
            let view = controller.multiplexedViewsByHost[host.connectionHash]
            #expect(view != nil, "the attach stopped its shared stream while telling the caller to sign in and retry")
            #expect(view?.connection != nil, "the kept view has no stream left to resume after the login")
        }
    }
}
