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
            let windowId = appDelegate.createMainWindow(shouldActivate: false)
            defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId) }
            let host = RemoteTmuxHost(destination: "login-wait-\(UUID().uuidString)@example.test")
            defer { _ = controller.stopMultiplexedHost(host: host) }

            let outcome = try await controller.attachHostMultiplexed(
                host: host, windowTarget: .explicitWindow(windowId), activate: false)

            guard case .authRequired = outcome else {
                Issue.record("a host that wants a sign-in should hand back the interactive login, got \(outcome)")
                return
            }
            let view = controller.multiplexedViewsByHost[host.connectionHash]
            #expect(view != nil, "the attach stopped its shared stream while telling the caller to sign in and retry")
            #expect(view?.connection != nil, "the kept view has no stream left to resume after the login")
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["authenticate", "detach", "dismiss"])
    func callerOwnedLoginResumesOrDetachesWithoutALoginWorkspace(action: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-cli-login-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let checked = root.appendingPathComponent("checked")
            let authenticated = root.appendingPathComponent("authenticated")
            let resumed = root.appendingPathComponent("resumed")
            let ssh = root.appendingPathComponent("ssh")
            try """
            #!/bin/sh
            case "$*" in
              *'-O check'*)
                if [ -f '\(authenticated.path)' ]; then exit 0; fi
                touch '\(checked.path)'
                exit 1 ;;
              *-CC*)
                if [ -f '\(authenticated.path)' ]; then
                  touch '\(resumed.path)'
                  printf '\\033P1000p%%begin 1 1 0\\n%%end 1 1 0\\n'
                  exec cat > /dev/null
                fi
                echo 'Permission denied (publickey,keyboard-interactive).' >&2
                exit 255 ;;
              *) exit 0 ;;
            esac
            """.write(to: ssh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
            let previousSSH = getenv(sshOverrideKey).map { String(cString: $0) }
            setenv(sshOverrideKey, ssh.path, 1)
            defer {
                if let previousSSH { setenv(sshOverrideKey, previousSSH, 1) } else { unsetenv(sshOverrideKey) }
            }

            let appDelegate = try #require(AppDelegate.shared)
            let controller = appDelegate.remoteTmuxController
            let windowId = appDelegate.createMainWindow(shouldActivate: false)
            defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId) }
            let host = RemoteTmuxHost(destination: "cli-login-\(UUID().uuidString)@example.test")
            let socket = URL(fileURLWithPath: host.controlSocketPath)
            try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer {
                controller.stopMultiplexedHost(host: host)
                controller.cancelAuthWait(host: host.connectionHash)
                try? FileManager.default.removeItem(at: socket)
            }
            let outcome = try await controller.attachHostMultiplexed(
                host: host, windowTarget: .explicitWindow(windowId), activate: false)
            guard case .authRequired = outcome else {
                Issue.record("expected an interactive login, got \(outcome)")
                return
            }
            #expect(controller.loginOffers.openedWorkspace(host: host.connectionHash) == nil)
            #expect(controller.sessionMirrors.values.allSatisfy { $0.host.connectionHash != host.connectionHash })
            try await waitUntil { FileManager.default.fileExists(atPath: checked.path) }

            if action == "authenticate" {
                // A CLI login opens the master after the waiter's first negative probe.
                // The socket creation is the same filesystem edge produced by real ssh.
                try Data().write(to: authenticated)
                try Data().write(to: socket)
                try await waitUntil { FileManager.default.fileExists(atPath: resumed.path) }
            } else if action == "dismiss" {
                let connection = try #require(controller.multiplexedViewsByHost[host.connectionHash]?.connection)
                #expect(connection.awaitingInteractiveAuth)
                let workspaceId = UUID()
                guard case .present(let generation) = controller.loginOffers.claim(
                    host: host.connectionHash, isOpen: { _ in false }) else {
                    Issue.record("expected a fresh login offer")
                    return
                }
                controller.loginOffers.recordOpened(
                    host: host.connectionHash, workspace: workspaceId, generation: generation)
                controller.noteLoginWorkspaceClosed(workspaceId: workspaceId)
                #expect(!connection.awaitingInteractiveAuth, "dismissing the login must resume the pre-mirror stream")
                #expect(controller.loginOffers.isDeclined(host: host.connectionHash))
            } else {
                controller.stopMultiplexedHost(host: host)
            }
            try await waitUntil { !controller.hostsWaitingForAuth.contains(host.connectionHash) }
            #expect(controller.authWaitTasks[host.connectionHash] == nil)
            #expect(controller.loginOffers.openedWorkspace(host: host.connectionHash) == nil)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "the authentication lifecycle did not reach its expected state")
    }

}
