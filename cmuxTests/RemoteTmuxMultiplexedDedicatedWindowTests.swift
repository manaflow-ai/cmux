import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux ssh-tmux <host> --new-window` asks for the host's mirrors in a window of their own. With
/// one shared connection per host, an attach for a host that had no mirror window yet failed
/// before it opened any connection: nothing on that path created the window, so the request had
/// no destination and was reported as "app not ready".
@MainActor
@Suite(.serialized, .exclusiveAppContext) struct RemoteTmuxMultiplexedDedicatedWindowTests {
    private let sshOverrideKey = "CMUX_REMOTE_TMUX_SSH_FOR_TESTING"

    @Test(.timeLimit(.minutes(2)))
    func dedicatedWindowAttachReachesTheHostAndLeavesNoWindowBehindWhenItFails() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-dedicated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launchesURL = root.appendingPathComponent("launches")

        // A host that refuses every connection. Reaching it at all is what this test is about.
        let sshURL = root.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        echo launch >> '\(launchesURL.path)'
        echo 'ssh: connect to host dedicated.test port 22: Connection refused' >&2
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
        let host = RemoteTmuxHost(destination: "dedicated-\(UUID().uuidString)@example.test")
        let windowsBefore = appDelegate.mainWindowContexts.count

        var thrown: Error?
        do {
            _ = try await controller.attachHostMultiplexed(
                host: host, windowTarget: .dedicatedNewWindow, activate: false)
        } catch {
            thrown = error
        }
        _ = controller.stopMultiplexedHost(host: host)

        let failure = try #require(thrown as? RemoteTmuxError, "a host that refuses connections cannot mirror")
        #expect(
            failure != .unreachable("app not ready"),
            "the attach gave up before it tried the host"
        )
        let launches = (try? String(contentsOf: launchesURL, encoding: .utf8)) ?? ""
        #expect(!launches.isEmpty, "no connection to the host was ever started")
        #expect(
            appDelegate.mainWindowContexts.count == windowsBefore,
            "a failed attach left its empty window on screen"
        )
    }
}
