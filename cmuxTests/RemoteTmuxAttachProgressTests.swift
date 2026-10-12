import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An attach over the shared connection waits for a login for as long as the transport is still
/// working, and reports what happened when it stops: the transport's own reason when it exits,
/// or the phase it went quiet in. It used to get 30 seconds in total, which a login that needed
/// a tap or queued behind another connection could not meet.
@MainActor
@Suite(.serialized) struct RemoteTmuxAttachProgressTests {
    private let sshOverrideKey = "CMUX_REMOTE_TMUX_SSH_FOR_TESTING"
    private typealias Progress = RemoteTmuxAttachProgress

    @Test func eachPhaseIsHeldToItsOwnQuietLimit() {
        let limits = Progress.QuietLimits(loggingIn: .seconds(300), inTmux: .seconds(30))
        // A login that has been quiet for longer than tmux is ever allowed is still waited for.
        #expect(Progress(phase: .loggingIn, quietFor: .seconds(45)).verdict(limits: limits)
            == .wait(recheckIn: .seconds(255)))
        #expect(Progress(phase: .loggingIn, quietFor: .seconds(300)).verdict(limits: limits) == .stalled)
        #expect(Progress(phase: .inTmux, quietFor: .seconds(29)).verdict(limits: limits)
            == .wait(recheckIn: .seconds(1)))
        #expect(Progress(phase: .inTmux, quietFor: .seconds(30)).verdict(limits: limits) == .stalled)
    }

    @Test func theFailureSaysWhichThingHappened() {
        let host = "dev.example.test"
        func message(_ error: RemoteTmuxError) -> String { error.message }

        let quietLogin = RemoteTmuxController.mirrorFailure(
            destination: host, awaitingCredentials: false,
            stall: Progress(phase: .loggingIn, quietFor: .seconds(300)))
        #expect(message(quietLogin).contains("still starting after 300 seconds"))

        let quietTmux = RemoteTmuxController.mirrorFailure(
            destination: host, awaitingCredentials: false,
            stall: Progress(phase: .inTmux, quietFor: .seconds(30)))
        #expect(message(quietTmux).contains("answered and then sent nothing for 30 seconds"))

        let ended = RemoteTmuxController.mirrorFailure(
            destination: host, awaitingCredentials: false,
            transportDetail: "ssh: connect to host dev.example.test port 22: Connection refused")
        #expect(message(ended).contains("ended before tmux answered"))
        #expect(message(ended).contains("Connection refused"))

        // A host waiting for credentials is a login to offer, whatever else is known.
        let login = RemoteTmuxController.mirrorFailure(
            destination: host, awaitingCredentials: true,
            stall: Progress(phase: .loggingIn, quietFor: .seconds(300)))
        guard case .authenticationRequired = login else {
            Issue.record("a host waiting for credentials must be reported as a login, got \(login)")
            return
        }
    }

    /// The transport takes longer to fail than tmux would ever be allowed to stay quiet. The
    /// attach must still be waiting when it fails, and must report the transport's reason.
    @Test(.timeLimit(.minutes(2)))
    func aSlowLoginIsWaitedForAndItsOwnFailureIsReported() async throws {
        try await withFakeSSH("""
        #!/bin/sh
        sleep 3
        echo 'ssh: connect to host slow-login.test port 22: Connection refused' >&2
        exit 255
        """, limits: .init(loggingIn: .seconds(300), inTmux: .seconds(1))) { controller, host, windowId in
            do {
                let outcome = try await controller.attachHostMultiplexed(
                    host: host, windowTarget: .explicitWindow(windowId), activate: false)
                Issue.record("a transport that exits without reaching tmux cannot mirror anything, got \(outcome)")
            } catch let error as RemoteTmuxError {
                #expect(
                    error.message.contains("Connection refused"),
                    "the attach did not wait for the transport's own failure: \(error.message)")
            }
        }
    }

    /// The transport never says anything and never exits. The attach ends when the login phase's
    /// limit is reached, says that is what happened, and does not leave the stream behind.
    @Test(.timeLimit(.minutes(2)))
    func aLoginThatStaysQuietPastItsLimitIsReportedAsStalled() async throws {
        try await withFakeSSH("""
        #!/bin/sh
        exec sleep 600
        """, limits: .init(loggingIn: .seconds(1), inTmux: .seconds(30))) { controller, host, windowId in
            do {
                let outcome = try await controller.attachHostMultiplexed(
                    host: host, windowTarget: .explicitWindow(windowId), activate: false)
                Issue.record("a transport that never answers cannot mirror anything, got \(outcome)")
            } catch let error as RemoteTmuxError {
                #expect(
                    error.message.contains("still starting after"),
                    "a quiet login was not reported as one: \(error.message)")
            }
            #expect(
                controller.multiplexedViewsByHost[host.connectionHash] == nil,
                "the stalled stream was left running")
        }
    }

    private func withFakeSSH(
        _ script: String,
        limits: RemoteTmuxAttachProgress.QuietLimits,
        _ body: @MainActor (RemoteTmuxController, RemoteTmuxHost, UUID) async throws -> Void
    ) async throws {
        // The fake ssh is a process-wide override, so hold the app-context gate for the whole body:
        // another suite that suspends here must not start a connection through it.
        try await AppContextSerialGate.withExclusiveAppContext {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-attach-progress-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let sshURL = root.appendingPathComponent("ssh")
            try script.write(to: sshURL, atomically: true, encoding: .utf8)
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
            let previousLimits = controller.attachQuietLimits
            controller.attachQuietLimits = limits
            defer { controller.attachQuietLimits = previousLimits }
            let host = RemoteTmuxHost(destination: "attach-progress-\(UUID().uuidString)@example.test")
            defer { _ = controller.stopMultiplexedHost(host: host) }

            try await body(controller, host, windowId)
        }
    }
}
