import AppKit
import CmuxControlSocket
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the remote-tmux mirror close contract
/// (https://github.com/manaflow-ai/cmux/pull/7264 review): closing a mirrored
/// remote-tmux workspace must DETACH from the remote session, never `kill-session`
/// it. The ssh-tmux author flagged that with mirrors living as plain workspaces in
/// the current window, the natural "close this tab to get it off my screen" gesture
/// would silently kill the user's live tmux session on the server. Killing a remote
/// session is only ever an explicit disconnect action, never a side effect of
/// closing a tab, a window, or quitting the app.
///
/// The seam that used to translate a tab close into "kill on commit" is
/// `TabManager.markRemoteTmuxKillOnWindowCloseIfNeeded`, which set the window
/// kill-on-close marker in `RemoteTmuxWindowRegistry`. After the fix that seam must
/// never mark a mirror for kill, so every close path (non-last tab, last-tab window
/// close, and the app-quit deferral gate) detaches and the remote session survives.
/// The marker is set-then-consumed synchronously inside the real close gesture, so
/// this test exercises the marking decision directly to observe it deterministically.
@MainActor
@Suite(.serialized) struct RemoteTmuxMirrorCloseDetachTests {
    private let sshOverrideKey = "CMUX_REMOTE_TMUX_SSH_FOR_TESTING"
    private let sshLogKey = "CMUX_PR7264_SSH_LOG"

    /// The mark seam must NOT flag a mirror workspace's window for kill-on-close:
    /// the close detaches, the remote tmux session survives for resume. Before the
    /// fix this marked the window for kill; after, it never does.
    @Test func markSeamDoesNotMarkMirrorForKill() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.workspace.isRemoteTmuxMirror = true
        harness.manager.markRemoteTmuxKillOnWindowCloseIfNeeded(for: [harness.workspace])

        #expect(
            !harness.appDelegate.remoteTmuxController
                .windowsMarkedForKillOnClose()
                .contains(harness.windowId)
        )
    }

    /// The v2 socket close path must detach a live last-workspace mirror without
    /// issuing the destructive `tmux kill-session` used by an explicit remote
    /// disconnect. The fake SSH executable records every argv element and treats
    /// the local ControlMaster exit as success, so this exercises the production
    /// close route without opening a network connection.
    @Test func socketCloseOfLiveLastMirrorDetachesWithoutKillingSession() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("ssh.log")
        let sshURL = root.appendingPathComponent("ssh")
        try writeExecutable(
            at: sshURL,
            contents: """
            #!/bin/sh
            for arg in "$@"; do
              printf 'ARG=%s\\n' "$arg" >> "${CMUX_PR7264_SSH_LOG:?}"
            done
            exit 0
            """
        )
        let previousSSH = environmentValue(for: sshOverrideKey)
        let previousLog = environmentValue(for: sshLogKey)
        setenv(sshOverrideKey, sshURL.path, 1)
        setenv(sshLogKey, logURL.path, 1)
        defer {
            restoreEnvironment(sshOverrideKey, previousValue: previousSSH)
            restoreEnvironment(sshLogKey, previousValue: previousLog)
        }

        let harness = try Harness()
        defer { harness.tearDown() }
        let host = RemoteTmuxHost(destination: "close-\(UUID().uuidString)@example.test")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "dev")
        let controller = harness.appDelegate.remoteTmuxController
        defer {
            if controller.sessionMirror(host: host, sessionName: "dev") != nil {
                controller.detach(host: host, sessionName: "dev")
            }
        }
        controller.cacheConnection(connection)
        #expect(try controller.mirrorSession(host: host, sessionName: "dev", into: harness.manager))
        let mirrorWorkspace = try #require(harness.manager.tabs.first(where: { $0.isRemoteTmuxMirror }))
        harness.manager.closeWorkspace(harness.workspace, recordHistory: false)
        #expect(harness.manager.tabs.map(\.id) == [mirrorWorkspace.id])
        #expect(!connection.exited)

        let resolution = TerminalController.shared.controlCloseWorkspace(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: true,
                windowID: harness.windowId,
                groupID: nil,
                workspaceID: mirrorWorkspace.id,
                surfaceID: nil,
                paneID: nil
            ),
            workspaceID: mirrorWorkspace.id
        )

        #expect(resolution == .resolved(windowID: harness.windowId))
        let log = try await waitForSSHArgument("exit", at: logURL)
        #expect(!log.contains("kill-session"), Comment(rawValue: log))
        #expect(controller.sessionMirror(host: host, sessionName: "dev") == nil)
        #expect(connection.exited)
    }

    /// The ordinary non-last tab-close route shares the same detach contract as
    /// socket/window close: removing the mirror from a mixed local window must
    /// stop its control client without issuing `tmux kill-session`.
    @Test func ordinaryCloseOfLiveMirrorDetachesWithoutKillingSession() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-tab-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("ssh.log")
        let sshURL = root.appendingPathComponent("ssh")
        try writeExecutable(
            at: sshURL,
            contents: """
            #!/bin/sh
            for arg in "$@"; do
              printf 'ARG=%s\\n' "$arg" >> "${CMUX_PR7264_SSH_LOG:?}"
            done
            exit 0
            """
        )
        let previousSSH = environmentValue(for: sshOverrideKey)
        let previousLog = environmentValue(for: sshLogKey)
        setenv(sshOverrideKey, sshURL.path, 1)
        setenv(sshLogKey, logURL.path, 1)
        defer {
            restoreEnvironment(sshOverrideKey, previousValue: previousSSH)
            restoreEnvironment(sshLogKey, previousValue: previousLog)
        }

        let harness = try Harness()
        defer { harness.tearDown() }
        let host = RemoteTmuxHost(destination: "tab-close-\(UUID().uuidString)@example.test")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "dev")
        let controller = harness.controller
        defer {
            if controller.sessionMirror(host: host, sessionName: "dev") != nil {
                controller.detach(host: host, sessionName: "dev")
            }
        }
        controller.cacheConnection(connection)
        #expect(try controller.mirrorSession(host: host, sessionName: "dev", into: harness.manager))
        let mirrorWorkspace = try #require(harness.manager.tabs.first(where: { $0.isRemoteTmuxMirror }))
        #expect(harness.manager.tabs.count == 2)

        harness.manager.closeWorkspace(mirrorWorkspace, recordHistory: false)

        let log = try await waitForSSHArgument("exit", at: logURL)
        #expect(!log.contains("kill-session"), Comment(rawValue: log))
        #expect(harness.manager.tabs.map(\.id) == [harness.workspace.id])
        #expect(controller.sessionMirror(host: host, sessionName: "dev") == nil)
        #expect(connection.exited)
    }

    @Test func windowCreationFailureUsesLocalErrorMessage() {
        let message = RemoteTmuxError.windowCreationFailed.message

        #expect(message == String(
            localized: "remoteTmux.error.windowCreationFailed",
            defaultValue: "cmux could not create a new window"
        ))
        #expect(!message.localizedCaseInsensitiveContains("host unreachable"))
    }

    /// `--new-window` must consolidate every mirror for the host even when the
    /// Move Workspace action previously distributed those mirrors across several
    /// source windows. The fake SSH executable supplies discovery and readiness
    /// responses while cached control connections keep the test network-free.
    @Test func dedicatedWindowConsolidatesMirrorsFromEverySourceWindow() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-placement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sshURL = root.appendingPathComponent("ssh")
        try writeExecutable(
            at: sshURL,
            contents: """
            #!/bin/sh
            case "$*" in
              *display-message*) printf '3.4\\n' ;;
              *list-sessions*) printf '$1:1:0:1:one\\n$2:1:0:1:two\\n' ;;
            esac
            exit 0
            """
        )
        let previousSSH = environmentValue(for: sshOverrideKey)
        setenv(sshOverrideKey, sshURL.path, 1)
        defer { restoreEnvironment(sshOverrideKey, previousValue: previousSSH) }

        let harness = try Harness()
        var extraWindowIDs: [UUID] = []
        defer {
            extraWindowIDs.reversed().forEach(harness.closeWindow)
            harness.tearDown()
        }
        let secondWindowID = harness.appDelegate.createMainWindow()
        extraWindowIDs.append(secondWindowID)
        let secondManager = try #require(harness.appDelegate.tabManagerFor(windowId: secondWindowID))
        let host = RemoteTmuxHost(destination: "placement-\(UUID().uuidString)@example.test")
        defer {
            harness.controller.detach(host: host, sessionName: "one")
            harness.controller.detach(host: host, sessionName: "two")
        }
        harness.cacheConnection(host: host, session: "one")
        harness.cacheConnection(host: host, session: "two")
        #expect(try harness.controller.mirrorSession(host: host, sessionName: "one", into: harness.manager))
        #expect(try harness.controller.mirrorSession(host: host, sessionName: "two", into: harness.manager))
        let secondMirror = try #require(harness.manager.tabs.first(where: { $0.title == "two" }))
        let detached = try #require(harness.manager.detachWorkspace(tabId: secondMirror.id))
        secondManager.attachWorkspace(detached, select: false)
        #expect(harness.manager.tabs.filter(\.isRemoteTmuxMirror).count == 1)
        #expect(secondManager.tabs.filter(\.isRemoteTmuxMirror).count == 1)

        let outcome = try await harness.controller.attachHost(
            host: host,
            windowTarget: .dedicatedNewWindow,
            activate: false
        )
        guard case let .mirrored(targetWindowID, workspaceIDs) = outcome else {
            Issue.record("Expected dedicated-window attach to mirror the host")
            return
        }
        extraWindowIDs.append(targetWindowID)
        let targetManager = try #require(harness.appDelegate.tabManagerFor(windowId: targetWindowID))

        #expect(workspaceIDs.count == 2)
        #expect(targetManager.tabs.filter(\.isRemoteTmuxMirror).count == 2)
        #expect(harness.manager.tabs.allSatisfy { !$0.isRemoteTmuxMirror })
        #expect(secondManager.tabs.allSatisfy { !$0.isRemoteTmuxMirror })
    }

    /// A direct socket caller must opt into focus. The CLI supplies an explicit
    /// `activate` value, but a raw `remote.tmux.window` request with no such field
    /// must leave the caller's current cmux window active.
    @Test func dedicatedWindowSocketDefaultsToFocusNeutral() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sshURL = root.appendingPathComponent("ssh")
        try writeExecutable(
            at: sshURL,
            contents: """
            #!/bin/sh
            case "$*" in
              *display-message*) printf '3.4\\n' ;;
              *list-sessions*) printf '$1:1:0:1:one\\n' ;;
            esac
            exit 0
            """
        )
        let previousSSH = environmentValue(for: sshOverrideKey)
        setenv(sshOverrideKey, sshURL.path, 1)
        defer { restoreEnvironment(sshOverrideKey, previousValue: previousSSH) }
        let remoteTmuxKey = SettingCatalog().betaFeatures.remoteTmux.userDefaultsKey
        let previousRemoteTmux = UserDefaults.standard.object(forKey: remoteTmuxKey)
        UserDefaults.standard.set(true, forKey: remoteTmuxKey)
        defer {
            if let previousRemoteTmux {
                UserDefaults.standard.set(previousRemoteTmux, forKey: remoteTmuxKey)
            } else {
                UserDefaults.standard.removeObject(forKey: remoteTmuxKey)
            }
        }

        let harness = try Harness()
        var targetWindowID: UUID?
        defer {
            if let targetWindowID { harness.closeWindow(targetWindowID) }
            harness.tearDown()
        }
        let host = RemoteTmuxHost(destination: "focus-\(UUID().uuidString)@example.test")
        defer { harness.controller.detach(host: host, sessionName: "one") }
        harness.cacheConnection(host: host, session: "one")
        #expect(harness.appDelegate.focusMainWindow(windowId: harness.windowId))
        #expect(harness.appDelegate.tabManager === harness.manager)

        let responseText = await Task.detached {
            TerminalController.shared.v2RemoteTmuxWindow(
                id: 1,
                params: ["host": host.destination]
            )
        }.value
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try #require(response["result"] as? [String: Any])
        targetWindowID = try #require(
            (result["window_id"] as? String).flatMap(UUID.init(uuidString:))
        )

        #expect(harness.appDelegate.tabManager === harness.manager)
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func environmentValue(for key: String) -> String? {
        getenv(key).map { String(cString: $0) }
    }

    private func restoreEnvironment(_ key: String, previousValue: String?) {
        if let previousValue {
            setenv(key, previousValue, 1)
        } else {
            unsetenv(key)
        }
    }

    private func waitForSSHArgument(_ argument: String, at logURL: URL) async throws -> String {
        for _ in 0..<200 {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if log.split(separator: "\n").contains(Substring("ARG=\(argument)")) {
                return log
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        Issue.record("Timed out waiting for fake SSH argument '\(argument)': \(log)")
        return log
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let manager: TabManager
        let workspace: Workspace
        var controller: RemoteTmuxController { appDelegate.remoteTmuxController }

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
        }

        func tearDown() {
            workspace.isRemoteTmuxMirror = false
            // Clear any marker so it can't leak into another serialized test.
            controller.consumeKillSessionsOnWindowClose(windowId: windowId)
            closeWindow(windowId)
        }

        func cacheConnection(host: RemoteTmuxHost, session: String) {
            controller.cacheConnection(RemoteTmuxControlConnection(host: host, sessionName: session))
        }

        func closeWindow(_ id: UUID) {
            let identifier = "cmux.main.\(id.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}
