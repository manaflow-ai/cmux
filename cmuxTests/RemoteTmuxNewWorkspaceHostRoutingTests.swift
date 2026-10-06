import AppKit
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// New Workspace routing for remote-tmux mirrors: the pure host-derivation
/// truth table, the controller seam (`newSessionRequest(in:)` and `createAndMirrorSession`), and
/// the `performNewWorkspaceAction` hook that suppresses local creation when
/// the active workspace is a mirror.
///
/// SSH never leaves the process: every test pins
/// `CMUX_REMOTE_TMUX_SSH_FOR_TESTING` to a stub for its WHOLE body — including
/// the deferred `detach`, whose last-mirror teardown spawns `ssh -O exit` — and
/// waits for the routed request before any teardown can evict the cached stub
/// transport. Tests that suspend hold `AppContextSerialGate` so another suite's
/// env/AppDelegate use cannot interleave at an await.
@MainActor
@Suite(.serialized)
struct RemoteTmuxNewWorkspaceHostRoutingTests {
    private let hostA = RemoteTmuxHost(destination: "user@host-routing-alpha")
    private let hostB = RemoteTmuxHost(destination: "user@host-routing-beta")

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

    /// A stub that creates `sessionName` successfully and then answers
    /// `kill-session` with `killExit`, recording every invocation to `argvLog`.
    private func makeCreateThenKillStub(sessionName: String, killExit: Int, argvLog: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-create-kill-stub-\(UUID().uuidString).sh").path
        try """
        #!/bin/sh
        echo "$@" >> "\(argvLog)"
        case "$*" in *kill-session*) exit \(killExit) ;; esac
        echo \(sessionName)

        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private struct AttachRefused: LocalizedError {
        var errorDescription: String? { "control stream refused" }
    }

    /// Runs a routed New Workspace whose create succeeds and whose attach throws,
    /// and returns what was reported plus the stub's recorded invocations.
    private func runCreateThenFailedAttach(
        sessionName: String,
        killExit: Int
    ) async throws -> (failures: [RemoteTmuxController.NewSessionFailure], argv: String, tabs: Int) {
        _ = NSApplication.shared
        let appDelegate = try #require(AppDelegate.shared)
        let argvLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-create-kill-argv-\(UUID().uuidString).log").path
        let stub = try makeCreateThenKillStub(sessionName: sessionName, killExit: killExit, argvLog: argvLog)
        let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH(stub)
        defer {
            restoreSSH()
            try? FileManager.default.removeItem(atPath: stub)
            try? FileManager.default.removeItem(atPath: argvLog)
        }
        var failures: [RemoteTmuxController.NewSessionFailure] = []
        var environment = RemoteTmuxNewSessionEnvironment.live
        environment.attach = { _, _, _, _, _ in throw AttachRefused() }
        environment.reportFailure = { _, failure, _ in failures.append(failure) }
        let controller = RemoteTmuxController(newSessionEnvironment: environment)
        let manager = TabManager()
        _ = try RemoteTmuxRoutingFixture.mirrorSelectedSession(controller: controller, host: hostA, sessionName: "dev", into: manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            controller.detach(host: hostA, sessionName: "dev")
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        }
        let tabsBefore = manager.tabs.count

        let request = try #require(controller.newSessionRequest(in: manager))
        await controller.createAndMirrorSession(request, in: manager)

        let argv = (try? String(contentsOfFile: argvLog, encoding: .utf8)) ?? ""
        return (failures, argv, manager.tabs.count - tabsBefore)
    }

    /// The session exists on the host once `new-session` succeeds. When the
    /// attach then fails, that is not a creation failure, and the session cmux
    /// just made is removed instead of being left with nothing showing it.
    @Test func aFailedAttachRemovesTheSessionItCreatedAndReportsAnAttachFailure() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let run = try await runCreateThenFailedAttach(sessionName: "orphan", killExit: 0)
            #expect(run.failures == [
                .attach(sessionName: "orphan", removed: true, detail: "control stream refused"),
            ])
            #expect(run.argv.contains("'new-session' '-d' '-P' '-F' '#{session_name}'"))
            #expect(run.argv.contains("'kill-session' '-t' '=orphan'"))
            #expect(run.tabs == 0)
        }
    }

    /// When the cleanup itself fails, the report says the session is still there
    /// and names it, so the user can find it.
    @Test func aFailedAttachWhoseCleanupFailsReportsTheSessionAsLeftBehind() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let run = try await runCreateThenFailedAttach(sessionName: "stuck", killExit: 1)
            #expect(run.failures == [
                .attach(sessionName: "stuck", removed: false, detail: "control stream refused"),
            ])
            #expect(run.argv.contains("'kill-session' '-t' '=stuck'"))
            #expect(run.tabs == 0)
        }
    }

    /// The three outcomes read differently: only a creation failure says nothing
    /// was created, and only a left-behind session is named.
    @Test func theAlertSaysWhichStepFailed() {
        let create = RemoteTmuxController.newSessionFailureAlertText(
            host: hostA, failure: .create(detail: "banner\nduplicate session: dev\n")
        )
        let removed = RemoteTmuxController.newSessionFailureAlertText(
            host: hostA, failure: .attach(sessionName: "orphan", removed: true, detail: "control stream refused")
        )
        let left = RemoteTmuxController.newSessionFailureAlertText(
            host: hostA, failure: .attach(sessionName: "stuck", removed: false, detail: "")
        )
        #expect(create.title != removed.title)
        #expect(removed.title == left.title)
        #expect(create.title.contains(hostA.destination))
        #expect(removed.title.contains(hostA.destination))
        #expect(create.message.hasSuffix("\n\nduplicate session: dev"))
        #expect(!create.message.contains("banner"))
        #expect(removed.message.hasSuffix("\n\ncontrol stream refused"))
        #expect(!removed.message.contains("orphan"))
        #expect(left.message.contains("stuck"))
        #expect(removed.message != left.message)
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

    // MARK: - Controller seam

    @Test func handlerClaimsRequestOnlyWhenActiveWorkspaceIsMirror() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            let localWorkspace = try #require(manager.selectedWorkspace)
            let mirrorWorkspace = try RemoteTmuxRoutingFixture.mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )
            defer {
                controller.detach(host: hostA, sessionName: "dev")
            }

            #expect(manager.selectedTab?.id == mirrorWorkspace.id)
            let request = try #require(controller.newSessionRequest(in: manager))
            #expect(request.host == hostA)
            #expect(request.activeTabId == mirrorWorkspace.id)
            // Run the request against the cached stub transport before the
            // deferred detach can evict it.
            await controller.createAndMirrorSession(request, in: manager)

            manager.selectWorkspace(localWorkspace)
            #expect(controller.newSessionRequest(in: manager) == nil)
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
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH(stub)
            defer {
                restoreSSH()
                try? FileManager.default.removeItem(atPath: stub)
                try? FileManager.default.removeItem(atPath: argvLog)
            }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            _ = try RemoteTmuxRoutingFixture.mirrorSelectedSession(
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

            let request = try #require(controller.newSessionRequest(in: manager))
            await controller.createAndMirrorSession(request, in: manager)

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
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH(stub)
            defer {
                restoreSSH()
                try? FileManager.default.removeItem(atPath: stub)
            }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            let localWorkspace = try #require(manager.selectedWorkspace)
            _ = try RemoteTmuxRoutingFixture.mirrorSelectedSession(
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

            let request = try #require(controller.newSessionRequest(in: manager))
            async let routed: Void = controller.createAndMirrorSession(request, in: manager)
            // The user moves on before the round trip completes.
            manager.selectWorkspace(localWorkspace)
            await routed

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
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH(stub)
            defer {
                restoreSSH()
                try? FileManager.default.removeItem(atPath: stub)
            }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            _ = try RemoteTmuxRoutingFixture.mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )
            controller.cacheConnection(RemoteTmuxControlConnection(host: hostA, sessionName: "orphaned"))
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                for sessionName in ["orphaned", "dev"] {
                    controller.detach(host: hostA, sessionName: sessionName)
                }
            }

            let request = try #require(controller.newSessionRequest(in: manager))
            async let routed: Void = controller.createAndMirrorSession(request, in: manager)
            // The window goes away before the round trip completes.
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            await routed

            #expect(!manager.tabs.contains { $0.title == "orphaned" })
            #expect(controller.sessionMirror(host: hostA, sessionName: "orphaned") == nil)
        }
    }

    /// The setting turns the routing off: New Workspace on a mirrored workspace is then a
    /// local workspace again, and New Local Workspace has nothing to offer.
    @Test func turningTheSettingOffLeavesNewWorkspaceLocal() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            var routes = true
            var environment = RemoteTmuxNewSessionEnvironment.live
            environment.routesToMirrorHost = { routes }
            let controller = RemoteTmuxController(newSessionEnvironment: environment)
            let manager = TabManager()
            let mirrorWorkspace = try RemoteTmuxRoutingFixture.mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )
            defer { controller.detach(host: hostA, sessionName: "dev") }
            #expect(manager.selectedTab?.id == mirrorWorkspace.id)
            #expect(controller.wouldNewWorkspaceSpawnRemote(in: manager))

            routes = false
            #expect(controller.newSessionRequest(in: manager) == nil)
            #expect(!controller.wouldNewWorkspaceSpawnRemote(in: manager))
            #expect(!controller.handleNewWorkspaceRequested(in: manager))
        }
    }

    /// The setting ships on, and the app reads it through the catalog key.
    @Test func theSettingDefaultsToOn() {
        let key = SettingCatalog().betaFeatures.remoteTmuxNewWorkspaceOnHost
        #expect(key.defaultValue)
        #expect(key.userDefaultsKey == "remoteTmux.beta.newWorkspaceOnHost.enabled")
    }

    // MARK: - performNewWorkspaceAction hook

    @Test func newWorkspaceOnActiveMirrorSuppressesLocalCreation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let controller = appDelegate.remoteTmuxController
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            let manager = TabManager()
            let localWorkspace = try #require(manager.selectedWorkspace)
            // The action starts the request and returns. The report is the edge that says
            // the request finished.
            let (reports, reportContinuation) = AsyncStream<
                (host: RemoteTmuxHost, failure: RemoteTmuxController.NewSessionFailure)
            >.makeStream()
            let previousEnvironment = controller.newSessionEnvironment
            controller.newSessionEnvironment.reportFailure = { host, failure, _ in
                reportContinuation.yield((host: host, failure: failure))
            }
            let mirrorWorkspace = try RemoteTmuxRoutingFixture.mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )

            let (windowId, window) = RemoteTmuxRoutingFixture.registerWindowedContext(appDelegate: appDelegate, manager: manager)
            defer {
                controller.newSessionEnvironment = previousEnvironment
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
            var reportIterator = reports.makeAsyncIterator()
            let report = await reportIterator.next()
            #expect(manager.tabs.map(\.id) == tabsBefore)
            #expect(report?.host == hostA)
            // Nothing was created, so this is the creation failure, not an attach one.
            if case .create = report?.failure {} else {
                Issue.record("expected a creation failure, got \(String(describing: report?.failure))")
            }

            // Active workspace is local: the same action creates a local workspace.
            manager.selectWorkspace(localWorkspace)
            #expect(appDelegate.performNewWorkspaceAction(tabManager: manager, debugSource: "test.localTab"))
            #expect(manager.tabs.count == tabsBefore.count + 1)
        }
    }
}
