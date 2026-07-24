import AppKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// New Workspace routing for remote-tmux mirrors: the pure host-derivation
/// truth table, the controller seam (`handleNewWorkspaceRequested(in:)`), and
/// the `performNewWorkspaceAction` hook that suppresses local creation when
/// the active workspace is a mirror.
///
/// SSH never leaves the process: every test pins
/// `CMUX_REMOTE_TMUX_SSH_FOR_TESTING` to a stub for its WHOLE body — including
/// the deferred `detach`, whose last-mirror teardown spawns `ssh -O exit` — and
/// awaits `newSessionRoutingTask` before any teardown can evict the cached stub
/// transport. Tests that suspend hold `AppContextSerialGate` so another suite's
/// env/AppDelegate use cannot interleave at an await.
@MainActor
@Suite(.serialized)
struct RemoteTmuxNewWorkspaceHostRoutingTests {
    private static let sshOverrideKey = "CMUX_REMOTE_TMUX_SSH_FOR_TESTING"
    private let hostA = RemoteTmuxHost(destination: "user@host-routing-alpha")
    private let hostB = RemoteTmuxHost(destination: "user@host-routing-beta")

    /// Sets the ssh stub for the caller's whole scope; the returned closure
    /// restores the previous value and is meant for the FIRST `defer`, so it
    /// runs after every later-registered teardown (detach included).
    private func pinStubSSH(_ stub: String) -> () -> Void {
        let prior = ProcessInfo.processInfo.environment[Self.sshOverrideKey]
        setenv(Self.sshOverrideKey, stub, 1)
        return {
            if let prior {
                setenv(Self.sshOverrideKey, prior, 1)
            } else {
                unsetenv(Self.sshOverrideKey)
            }
        }
    }

    /// Writes an executable stub that records its arguments (the ssh framing +
    /// tmux command) to `argvLog` and reports a created session named
    /// `sessionName`.
    private func makeNewSessionSuccessStub(sessionName: String, argvLog: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-new-session-stub-\(UUID().uuidString).sh").path
        try "#!/bin/sh\necho \"$@\" >> \"\(argvLog)\"\necho \(sessionName)\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func mirrorSelectedSession(
        controller: RemoteTmuxController,
        host: RemoteTmuxHost,
        sessionName: String,
        into manager: TabManager
    ) throws -> Workspace {
        _ = controller.transport(for: host)
        controller.cacheConnection(RemoteTmuxControlConnection(host: host, sessionName: sessionName))
        #expect(try controller.mirrorSession(host: host, sessionName: sessionName, into: manager))
        let workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        manager.selectWorkspace(workspace)
        return workspace
    }

    /// Registers `manager` as a main-window context with a resolvable window
    /// (the shape `performNewWorkspaceAction`'s preferred-context path needs).
    private func registerWindowedContext(
        appDelegate: AppDelegate,
        manager: TabManager
    ) -> (windowId: UUID, window: NSWindow) {
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        manager.window = window
        return (windowId, window)
    }

    // MARK: - newSessionHost truth table

    @Test func noActiveTabCreatesLocalWorkspace() {
        #expect(RemoteTmuxController.newSessionHost(
            activeTabId: nil,
            entries: [(host: hostA, workspaceId: UUID())]
        ) == nil)
    }

    @Test func localActiveTabCreatesLocalWorkspace() {
        // The active tab has no mirror entry — e.g. a plain local workspace
        // sitting next to mirrors in the same window.
        #expect(RemoteTmuxController.newSessionHost(
            activeTabId: UUID(),
            entries: [(host: hostA, workspaceId: UUID())]
        ) == nil)
    }

    @Test func activeMirrorTabRoutesToItsHost() {
        let activeId = UUID()
        #expect(RemoteTmuxController.newSessionHost(
            activeTabId: activeId,
            entries: [(host: hostA, workspaceId: activeId)]
        ) == hostA)
    }

    @Test func multiHostWindowRoutesByActiveTabNotNeighbor() {
        // Mirrors from two hosts share the window (the default placement);
        // the active tab's own host wins regardless of entry order.
        let activeId = UUID()
        let entries = [
            (host: hostA, workspaceId: Optional(UUID())),
            (host: hostB, workspaceId: Optional(activeId)),
        ]
        #expect(RemoteTmuxController.newSessionHost(activeTabId: activeId, entries: entries) == hostB)
        #expect(RemoteTmuxController.newSessionHost(activeTabId: activeId, entries: entries.reversed()) == hostB)
    }

    @Test func deallocatedMirrorWorkspaceNeverMatches() {
        // A mirror whose weak workspace is gone (mid-teardown) reports a nil
        // workspaceId; it must not capture any active tab.
        #expect(RemoteTmuxController.newSessionHost(
            activeTabId: UUID(),
            entries: [(host: hostA, workspaceId: nil)]
        ) == nil)
    }

    // MARK: - Failure reporting

    /// The multiplexed path has its own create seam (in band over the shared view
    /// stream), so it needs its own proof that a failure surfaces. A view with no
    /// live control connection returns nil from `createWorkspaceReturningName`
    /// without any ssh, which is exactly the "create came back with no name" case.
    @Test func multiplexedCreateFailureIsReported() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreSSH = pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            var reportedFailures: [(host: RemoteTmuxHost, detail: String)] = []
            controller.reportNewSessionFailure = { host, detail, _ in
                reportedFailures.append((host: host, detail: detail))
            }
            _ = try mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )
            defer { controller.detach(host: hostA, sessionName: "dev") }
            // A view whose connection was never established: createWorkspaceReturningName
            // short-circuits to nil, so the multiplexed branch takes its failure path.
            controller.multiplexedViewsByHost[hostA.connectionHash] = RemoteTmuxViewConnection(
                host: hostA, ownerId: "test-mux-failure"
            )

            #expect(controller.handleNewWorkspaceRequested(in: manager))
            await controller.newSessionRoutingTask?.value

            #expect(reportedFailures.count == 1)
            #expect(reportedFailures.first?.host == hostA)
            // Nothing was mirrored: the failed create left no workspace behind.
            #expect(!manager.tabs.contains { $0.title != "dev" && $0.isRemoteTmuxMirror })
        }
    }

    // MARK: - Controller seam

    @Test func handlerClaimsRequestOnlyWhenActiveWorkspaceIsMirror() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreSSH = pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            let localWorkspace = try #require(manager.selectedWorkspace)
            let mirrorWorkspace = try mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )
            defer {
                controller.detach(host: hostA, sessionName: "dev")
            }

            #expect(manager.selectedTab?.id == mirrorWorkspace.id)
            #expect(controller.handleNewWorkspaceRequested(in: manager))
            // Drain the routed request against the cached stub transport before
            // the deferred detach can evict it.
            await controller.newSessionRoutingTask?.value

            manager.selectWorkspace(localWorkspace)
            #expect(!controller.handleNewWorkspaceRequested(in: manager))
        }
    }

    /// The full success path: the remote reports the created session's name,
    /// the handler asked for exactly `new-session -d -P -F #{session_name}`,
    /// and the result is mirrored into the requesting manager and selected.
    @Test func routedNewWorkspaceMirrorsAndSelectsTheCreatedSession() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let argvLog = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-new-session-argv-\(UUID().uuidString).log").path
            let stub = try makeNewSessionSuccessStub(sessionName: "brand-new", argvLog: argvLog)
            let restoreSSH = pinStubSSH(stub)
            defer {
                restoreSSH()
                try? FileManager.default.removeItem(atPath: stub)
                try? FileManager.default.removeItem(atPath: argvLog)
            }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            _ = try mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )
            // The mirror the handler creates attaches to the reported name;
            // cache its connection so no control stream is spawned.
            controller.cacheConnection(RemoteTmuxControlConnection(host: hostA, sessionName: "brand-new"))
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                for sessionName in ["brand-new", "dev"] {
                    controller.detach(host: hostA, sessionName: sessionName)
                }
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            }

            #expect(controller.handleNewWorkspaceRequested(in: manager))
            await controller.newSessionRoutingTask?.value

            let recordedArgv = (try? String(contentsOfFile: argvLog, encoding: .utf8)) ?? ""
            // RemoteTmuxHost.tmuxRemoteCommand single-quotes every word of the remote
            // command, so the flags arrive individually quoted, not as one bare run.
            #expect(recordedArgv.contains("'new-session' '-d' '-P' '-F' '#{session_name}'"))
            let created = try #require(manager.tabs.first { $0.title == "brand-new" })
            #expect(created.isRemoteTmuxMirror)
            #expect(manager.selectedTab?.id == created.id)
        }
    }

    /// Moving to another tab during the ssh round trip still mirrors the new
    /// session, but must not steal the user's selection.
    @Test func movingOnDuringRoundTripMirrorsWithoutStealingSelection() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let stub = try makeNewSessionSuccessStub(sessionName: "unstolen", argvLog: "/dev/null")
            let restoreSSH = pinStubSSH(stub)
            defer {
                restoreSSH()
                try? FileManager.default.removeItem(atPath: stub)
            }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            let localWorkspace = try #require(manager.selectedWorkspace)
            _ = try mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )
            controller.cacheConnection(RemoteTmuxControlConnection(host: hostA, sessionName: "unstolen"))
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                for sessionName in ["unstolen", "dev"] {
                    controller.detach(host: hostA, sessionName: sessionName)
                }
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            }

            #expect(controller.handleNewWorkspaceRequested(in: manager))
            // The user moves on before the round trip completes.
            manager.selectWorkspace(localWorkspace)
            await controller.newSessionRoutingTask?.value

            let created = try #require(manager.tabs.first { $0.title == "unstolen" })
            #expect(created.isRemoteTmuxMirror)
            #expect(manager.selectedTab?.id == localWorkspace.id)
        }
    }

    /// A manager whose window closed (unregistered) during the round trip must
    /// not receive the mirror — the detached session is picked up on the next
    /// attach instead of resurrecting a dead manager.
    @Test func unregisteredManagerDoesNotReceiveTheMirror() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let stub = try makeNewSessionSuccessStub(sessionName: "orphaned", argvLog: "/dev/null")
            let restoreSSH = pinStubSSH(stub)
            defer {
                restoreSSH()
                try? FileManager.default.removeItem(atPath: stub)
            }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            _ = try mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )
            controller.cacheConnection(RemoteTmuxControlConnection(host: hostA, sessionName: "orphaned"))
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                for sessionName in ["orphaned", "dev"] {
                    controller.detach(host: hostA, sessionName: sessionName)
                }
            }

            #expect(controller.handleNewWorkspaceRequested(in: manager))
            // The window goes away before the round trip completes.
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            await controller.newSessionRoutingTask?.value

            #expect(!manager.tabs.contains { $0.title == "orphaned" })
            #expect(controller.sessionMirror(host: hostA, sessionName: "orphaned") == nil)
        }
    }

    // MARK: - performNewWorkspaceAction hook

    @Test func newWorkspaceOnActiveMirrorSuppressesLocalCreation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let controller = appDelegate.remoteTmuxController
            let restoreSSH = pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            let manager = TabManager()
            let localWorkspace = try #require(manager.selectedWorkspace)
            var reportedFailures: [(host: RemoteTmuxHost, detail: String)] = []
            let previousReport = controller.reportNewSessionFailure
            controller.reportNewSessionFailure = { host, detail, _ in
                reportedFailures.append((host: host, detail: detail))
            }
            let mirrorWorkspace = try mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )

            let (windowId, window) = registerWindowedContext(appDelegate: appDelegate, manager: manager)
            defer {
                controller.reportNewSessionFailure = previousReport
                window.close()
                manager.window = nil
                if controller.sessionMirror(host: hostA, sessionName: "dev") != nil {
                    controller.detach(host: hostA, sessionName: "dev")
                }
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            }

            // Active workspace is the mirror: the action is claimed for the
            // remote host and no local workspace appears. The stub ssh fails,
            // so the suppressed creation must surface as a reported failure,
            // not silence.
            #expect(manager.selectedTab?.id == mirrorWorkspace.id)
            let tabsBefore = manager.tabs.map(\.id)
            #expect(appDelegate.performNewWorkspaceAction(tabManager: manager, debugSource: "test.remoteMirror"))
            await controller.newSessionRoutingTask?.value
            #expect(manager.tabs.map(\.id) == tabsBefore)
            #expect(reportedFailures.count == 1)
            #expect(reportedFailures.first?.host == hostA)

            // Active workspace is local: the same action creates a local workspace.
            manager.selectWorkspace(localWorkspace)
            #expect(appDelegate.performNewWorkspaceAction(tabManager: manager, debugSource: "test.localTab"))
            #expect(manager.tabs.count == tabsBefore.count + 1)
        }
    }
}
