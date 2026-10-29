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
    private func makeCreateThenKillStub(
        sessionName: String,
        killExit: Int,
        argvLog: String,
        emitCreatedName: Bool = true,
        createExit: Int = 0
    ) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-create-kill-stub-\(UUID().uuidString).sh").path
        let output = emitCreatedName ? "echo \(sessionName)" : ""
        try """
        #!/bin/sh
        echo "$@" >> "\(argvLog)"
        case "$*" in *kill-session*) exit \(killExit) ;; esac
        \(output)
        exit \(createExit)

        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// A create command that has time to create a remote session before the
    /// local task is cancelled. The kill path exits immediately so the test
    /// can verify the cancellation cleanup without waiting for the delay.
    private func makeSlowCreateStub(argvLog: String, cleanupMarker: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-slow-create-stub-\(UUID().uuidString).sh").path
        try """
        #!/bin/sh
        echo "$@" >> "\(argvLog)"
        case "$*" in
          *kill-session*) sleep 0.1; echo cleanup-complete >> "\(cleanupMarker)"; exit 0 ;;
        esac
        echo created-by-cancellation-test
        sleep 5

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
        killExit: Int,
        emitCreatedName: Bool = true,
        createExit: Int = 0
    ) async throws -> (
        failures: [RemoteTmuxController.NewSessionFailure],
        argv: String,
        tabs: Int,
        attachCalls: Int
    ) {
        _ = NSApplication.shared
        let appDelegate = try #require(AppDelegate.shared)
        let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
        defer { restoreRouting() }
        let argvLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-create-kill-argv-\(UUID().uuidString).log").path
        let stub = try makeCreateThenKillStub(
            sessionName: sessionName,
            killExit: killExit,
            argvLog: argvLog,
            emitCreatedName: emitCreatedName,
            createExit: createExit
        )
        let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH(stub)
        defer {
            restoreSSH()
            try? FileManager.default.removeItem(atPath: stub)
            try? FileManager.default.removeItem(atPath: argvLog)
        }
        var failures: [RemoteTmuxController.NewSessionFailure] = []
        var attachCalls = 0
        var environment = RemoteTmuxNewSessionEnvironment.live
        environment.attach = { _, _, _, _, _ in
            attachCalls += 1
            throw AttachRefused()
        }
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
        return (failures, argv, manager.tabs.count - tabsBefore, attachCalls)
    }

    /// Runs the same create path with an attach that reports a non-throwing miss.
    /// `mirrorSession` uses `false` when another attach got there first, but a
    /// newly created session still needs an explicit cleanup/report if no mirror
    /// actually exists by the time this request finishes.
    private func runCreateThenSilentAttach(
        sessionName: String
    ) async throws -> (failures: [RemoteTmuxController.NewSessionFailure], argv: String, tabs: Int) {
        _ = NSApplication.shared
        let appDelegate = try #require(AppDelegate.shared)
        let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
        defer { restoreRouting() }
        let argvLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-create-silent-attach-argv-\(UUID().uuidString).log").path
        let stub = try makeCreateThenKillStub(sessionName: sessionName, killExit: 0, argvLog: argvLog)
        let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH(stub)
        defer {
            restoreSSH()
            try? FileManager.default.removeItem(atPath: stub)
            try? FileManager.default.removeItem(atPath: argvLog)
        }
        var failures: [RemoteTmuxController.NewSessionFailure] = []
        var environment = RemoteTmuxNewSessionEnvironment.live
        environment.attach = { _, _, _, _, _ in false }
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
                .attach(sessionName: "orphan", removed: true),
            ])
            #expect(run.argv.contains("'new-session' '-d' '-s' 'cmux-new-"))
            #expect(run.argv.contains("'-x' '120' '-y' '40'"))
            #expect(run.argv.contains("'-P' '-F' '#{session_name}'"))
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
                .attach(sessionName: "stuck", removed: false),
            ])
            #expect(run.argv.contains("'kill-session' '-t' '=stuck'"))
            #expect(run.tabs == 0)
        }
    }

    @Test func aNonzeroCreateWithUnexpectedOutputReportsACreationFailure() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let run = try await runCreateThenFailedAttach(
                sessionName: "remote-login-banner",
                killExit: 0,
                createExit: 1
            )
            #expect(run.failures == [
                .create,
            ])
            #expect(run.attachCalls == 0)
            #expect(run.argv.contains("'kill-session' '-t' '=cmux-new-"))
            #expect(run.tabs == 0)
        }
    }

    @Test func aNonzeroCreateWithUnexpectedOutputReportsWhenCleanupFails() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let run = try await runCreateThenFailedAttach(
                sessionName: "remote-login-banner",
                killExit: 1,
                createExit: 1
            )
            #expect(run.failures.count == 1)
            if case let .attach(sessionName, removed) = run.failures[0] {
                #expect(sessionName.hasPrefix("cmux-new-"))
                #expect(!removed)
            } else {
                Issue.record("expected an attach cleanup failure, got \(run.failures)")
            }
            #expect(run.attachCalls == 0)
            #expect(run.argv.contains("'kill-session' '-t' '=cmux-new-"))
            #expect(run.tabs == 0)
        }
    }

    /// A successful tmux command can lose its `-P` response when the transport closes. The
    /// explicit request name still lets cmux remove the possible remote session before reporting
    /// the creation failure.
    @Test func anEmptyCreateResponseCleansTheKnownRequestedName() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let run = try await runCreateThenFailedAttach(
                sessionName: "unused-output",
                killExit: 0,
                emitCreatedName: false
            )
            #expect(run.failures.count == 1)
            if case let .attach(sessionName, removed) = run.failures[0] {
                #expect(sessionName.hasPrefix("cmux-new-"))
                #expect(removed)
            } else {
                Issue.record("expected an attach cleanup failure, got \(run.failures)")
            }
            #expect(run.argv.contains("'new-session' '-d' '-s' 'cmux-new-"))
            #expect(run.argv.contains("'kill-session' '-t' '=cmux-new-"))
            #expect(run.tabs == 0)
        }
    }

    @Test func aSilentAttachMissRemovesTheSessionItCreatedAndReportsAnAttachFailure() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let run = try await runCreateThenSilentAttach(sessionName: "silent-miss")
            #expect(run.failures == [
                .attach(sessionName: "silent-miss", removed: true),
            ])
            #expect(run.argv.contains("'kill-session' '-t' '=silent-miss'"))
            #expect(run.tabs == 0)
        }
    }

    /// Cancelling an in-flight create can terminate ssh after tmux has already
    /// created the session. The request uses a known unique name so the cleanup
    /// still kills that session even though runTmux throws CancellationError.
    @Test func cancellingCreateRemovesTheSessionThatMayAlreadyExist() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
            defer { restoreRouting() }
            let argvLog = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-cancelled-create-argv-\(UUID().uuidString).log").path
            let cleanupMarker = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-cancelled-create-cleanup-\(UUID().uuidString).marker").path
            let stub = try makeSlowCreateStub(argvLog: argvLog, cleanupMarker: cleanupMarker)
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH(stub)
            defer {
                restoreSSH()
                try? FileManager.default.removeItem(atPath: stub)
                try? FileManager.default.removeItem(atPath: argvLog)
                try? FileManager.default.removeItem(atPath: cleanupMarker)
            }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            _ = try RemoteTmuxRoutingFixture.mirrorSelectedSession(
                controller: controller, host: hostA, sessionName: "dev", into: manager
            )
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                controller.detach(host: hostA, sessionName: "dev")
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            }

            let request = try #require(controller.newSessionRequest(in: manager))
            let routed = Task { await controller.createAndMirrorSession(request, in: manager) }
            try? await Task.sleep(nanoseconds: 100_000_000)
            routed.cancel()
            await routed.value

            let argv = (try? String(contentsOfFile: argvLog, encoding: .utf8)) ?? ""
            #expect(argv.contains("'kill-session' '-t' '=cmux-new-"))
            #expect((try? String(contentsOfFile: cleanupMarker, encoding: .utf8)) == "cleanup-complete\n")
        }
    }

    /// The three outcomes read differently: only a creation failure says nothing
    /// was created, and only a left-behind session reports its cleanup status.
    /// Remote command output and the host-generated session name are never copied
    /// into the alert.
    @Test func theAlertSaysWhichStepFailed() {
        let create = RemoteTmuxController.newSessionFailureAlertText(
            host: hostA, failure: .create
        )
        let removed = RemoteTmuxController.newSessionFailureAlertText(
            host: hostA, failure: .attach(sessionName: "orphan", removed: true)
        )
        let left = RemoteTmuxController.newSessionFailureAlertText(
            host: hostA, failure: .attach(sessionName: "stuck", removed: false)
        )
        #expect(create.title != removed.title)
        #expect(removed.title == left.title)
        #expect(create.title.contains(hostA.destination))
        #expect(removed.title.contains(hostA.destination))
        #expect(!create.message.contains("duplicate session: dev"))
        #expect(!create.message.contains("banner"))
        #expect(!removed.message.contains("control stream refused"))
        #expect(!removed.message.contains("orphan"))
        #expect(!left.message.contains("stuck"))
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
            let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
            defer { restoreRouting() }
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
    /// the handler asked for a uniquely named detached `new-session`,
    /// preserving the printed session name for attach,
    /// and the result is mirrored into the requesting manager and selected.
    @Test func routedNewWorkspaceMirrorsAndSelectsTheCreatedSession() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
            defer { restoreRouting() }
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
            var completionCount = 0
            await controller.createAndMirrorSession(request, in: manager) {
                completionCount += 1
            }

            let recordedArgv = (try? String(contentsOfFile: argvLog, encoding: .utf8)) ?? ""
            // RemoteTmuxHost.tmuxRemoteCommand single-quotes every word of the remote
            // command, so the flags arrive individually quoted, not as one bare run.
            #expect(recordedArgv.contains("'new-session' '-d' '-s' 'cmux-new-"))
            #expect(recordedArgv.contains("'-x' '120' '-y' '40'"))
            #expect(recordedArgv.contains("'-P' '-F' '#{session_name}'"))
            let created = try #require(manager.tabs.first { $0.title == "brand-new" })
            #expect(created.isRemoteTmuxMirror)
            #expect(manager.selectedTab?.id == created.id)
            #expect(completionCount == 1)
        }
    }

    /// Moving to another tab during the ssh round trip still mirrors the new
    /// session, but must not steal the user's selection.
    @Test func movingOnDuringRoundTripMirrorsWithoutStealingSelection() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
            defer { restoreRouting() }
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
    /// not receive the mirror or leave the newly-created detached session behind.
    @Test func unregisteredManagerDoesNotReceiveTheMirror() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
            defer { restoreRouting() }
            let argvLog = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-unregistered-new-session-argv-\(UUID().uuidString).log").path
            let stub = try makeNewSessionSuccessStub(sessionName: "orphaned", argvLog: argvLog)
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
            let argv = (try? String(contentsOfFile: argvLog, encoding: .utf8)) ?? ""
            #expect(argv.contains("'kill-session' '-t' '=orphaned'"))
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

    /// The setting is opt-in, and the app reads it through the catalog key.
    @Test func theSettingDefaultsToOff() {
        let key = SettingCatalog().betaFeatures.remoteTmuxNewWorkspaceOnHost
        #expect(!key.defaultValue)
        #expect(key.userDefaultsKey == "remoteTmux.beta.newWorkspaceOnHost.enabled")
    }

    @Test func aNarrowAttachStillAdmitsAConcurrentRoutedSession() {
        #expect(RemoteTmuxController.multiplexedCreateShouldBeAdmitted(
            sessionName: "cmux-new-routed",
            requestedSessionName: "requested",
            pendingRoutedSessionNames: ["cmux-new-routed"]
        ))
        #expect(!RemoteTmuxController.multiplexedCreateShouldBeAdmitted(
            sessionName: "other-session",
            requestedSessionName: "requested",
            pendingRoutedSessionNames: ["cmux-new-routed"]
        ))
    }

    /// A shared view may reconcile through the manager that owns an existing mirror while
    /// New Workspace was requested from another window. The new mirror and its selection
    /// belong to the requesting manager, not whichever manager the view callback used.
    @Test func multiplexedRoutedAdmissionUsesTheRequestingManager() throws {
        let controller = RemoteTmuxController()
        let view = RemoteTmuxViewConnection(host: hostA, ownerId: "routing-test")
        let shared = RemoteTmuxControlConnection(host: hostA, sessionName: view.view.sessionName)
        view.connection = shared
        controller.multiplexedViewsByHost[hostA.connectionHash] = view

        let existingManager = TabManager()
        let requestingManager = TabManager()
        let existing = RemoteTmuxLinkedWorkspaceModel.Workspace(
            sessionName: "existing",
            windowIds: ["@1"],
            activeWindowId: "@1",
            sessionId: 1
        )
        controller.applyMultiplexedWorkspaces(
            host: hostA,
            manager: existingManager,
            workspaces: [existing],
            shared: shared
        )
        let newName = "cmux-new-requesting-manager"
        let newKey = RemoteTmuxController.connectionKey(host: hostA, sessionName: newName)
        var completionResult: Bool?
        controller.pendingMultiplexNewSessionManagers[newKey] = RemoteTmuxWeakTabManager(requestingManager)
        controller.pendingMultiplexNewSessionCompletions[newKey] = { completionResult = $0 }
        controller.multiplexIntentsByHost[hostA.connectionHash] = .init(
            pendingSelect: .init(
                sessionName: newName,
                originatingTabId: requestingManager.selectedTab!.id
            )
        )

        let routed = RemoteTmuxLinkedWorkspaceModel.Workspace(
            sessionName: newName,
            windowIds: ["@2"],
            activeWindowId: "@2",
            sessionId: 2
        )
        controller.applyMultiplexedWorkspaces(
            host: hostA,
            manager: existingManager,
            workspaces: [existing, routed],
            shared: shared
        )

        let created = try #require(requestingManager.tabs.first { $0.title == newName })
        #expect(created.isRemoteTmuxMirror)
        #expect(requestingManager.selectedTab?.id == created.id)
        #expect(existingManager.tabs.first { $0.title == newName } == nil)
        #expect(controller.sessionMirror(host: hostA, sessionName: newName)?.mirroredWorkspaceId == created.id)
        #expect(completionResult == true)
    }

    /// If the requesting window closes before admission, the cleanup kill may not be
    /// reflected in the next view snapshot. That stale session must stay blocked rather
    /// than falling back into the manager that owns the shared view.
    @Test func failedMultiplexedAdmissionStaysBlockedUntilTheSessionDisappears() throws {
        let controller = RemoteTmuxController()
        let view = RemoteTmuxViewConnection(host: hostA, ownerId: "blocked-routing-test")
        let shared = RemoteTmuxControlConnection(host: hostA, sessionName: view.view.sessionName)
        view.connection = shared
        controller.multiplexedViewsByHost[hostA.connectionHash] = view

        let existingManager = TabManager()
        let existing = RemoteTmuxLinkedWorkspaceModel.Workspace(
            sessionName: "existing",
            windowIds: ["@1"],
            activeWindowId: "@1",
            sessionId: 1
        )
        controller.applyMultiplexedWorkspaces(
            host: hostA,
            manager: existingManager,
            workspaces: [existing],
            shared: shared
        )

        var requester: TabManager? = TabManager()
        let origin = try #require(requester?.selectedTab?.id)
        let newName = "cmux-new-closed-requester"
        let newKey = RemoteTmuxController.connectionKey(host: hostA, sessionName: newName)
        var completionResult: Bool?
        controller.pendingMultiplexNewSessionManagers[newKey] = RemoteTmuxWeakTabManager(
            try #require(requester)
        )
        controller.pendingMultiplexNewSessionCompletions[newKey] = { completionResult = $0 }
        controller.multiplexIntentsByHost[hostA.connectionHash] = .init(
            pendingSelect: .init(sessionName: newName, originatingTabId: origin)
        )
        requester = nil

        let routed = RemoteTmuxLinkedWorkspaceModel.Workspace(
            sessionName: newName,
            windowIds: ["@2"],
            activeWindowId: "@2",
            sessionId: 2
        )
        for _ in 0..<2 {
            controller.applyMultiplexedWorkspaces(
                host: hostA,
                manager: existingManager,
                workspaces: [existing, routed],
                shared: shared
            )
        }

        #expect(completionResult == false)
        #expect(existingManager.tabs.first { $0.title == newName } == nil)
        #expect(controller.sessionMirror(host: hostA, sessionName: newName) == nil)
        #expect(controller.blockedMultiplexNewSessionKeys.contains(newKey))
        controller.stopMultiplexedHost(host: hostA)
    }

    /// A shared stream can acknowledge `new-session` and then publish a snapshot in which the
    /// generated session is already gone (for example, its shell exits immediately). The routed
    /// request must resolve after a bounded miss window instead of retaining its completion and
    /// request markers forever.
    @Test func vanishedMultiplexedRoutedSessionResolvesAsCreateFailure() throws {
        let controller = RemoteTmuxController()
        let view = RemoteTmuxViewConnection(host: hostA, ownerId: "vanished-routing-test")
        let shared = RemoteTmuxControlConnection(host: hostA, sessionName: view.view.sessionName)
        view.connection = shared
        controller.multiplexedViewsByHost[hostA.connectionHash] = view

        let manager = TabManager()
        let existing = RemoteTmuxLinkedWorkspaceModel.Workspace(
            sessionName: "existing",
            windowIds: ["@1"],
            activeWindowId: "@1",
            sessionId: 1
        )
        controller.applyMultiplexedWorkspaces(
            host: hostA,
            manager: manager,
            workspaces: [existing],
            shared: shared
        )

        let vanishedName = "cmux-new-vanished"
        let vanishedKey = RemoteTmuxController.connectionKey(host: hostA, sessionName: vanishedName)
        var completionResult: Bool?
        controller.pendingMultiplexNewSessionCompletions[vanishedKey] = { completionResult = $0 }

        let snapshotWithoutVanished = [existing]
        controller.applyMultiplexedWorkspaces(
            host: hostA,
            manager: manager,
            workspaces: snapshotWithoutVanished,
            shared: shared
        )
        #expect(completionResult == nil)
        controller.applyMultiplexedWorkspaces(
            host: hostA,
            manager: manager,
            workspaces: snapshotWithoutVanished,
            shared: shared
        )

        #expect(completionResult == false)
        #expect(controller.pendingMultiplexNewSessionCompletions[vanishedKey] == nil)
        controller.stopMultiplexedHost(host: hostA)
    }

    /// A delayed shared-view stop can race a view replacement. Its callers still need
    /// their completion, even when the old view is no longer the host-map entry.
    @Test func replacedMultiplexedViewStillRunsStopCompletion() async {
        let controller = RemoteTmuxController()
        let oldView = RemoteTmuxViewConnection(host: hostA, ownerId: "old-view")
        controller.multiplexedViewsByHost[hostA.connectionHash] = oldView
        let pendingKey = RemoteTmuxController.connectionKey(host: hostA, sessionName: "cmux-new-pending")
        controller.pendingMultiplexNewSessionCompletions[pendingKey] = { _ in }
        var stopCompletionCount = 0

        #expect(controller.stopMultiplexedHost(host: hostA) {
            stopCompletionCount += 1
        })
        controller.multiplexedViewsByHost[hostA.connectionHash] = RemoteTmuxViewConnection(
            host: hostA,
            ownerId: "replacement-view"
        )
        for _ in 0..<8 { await Task.yield() }

        #expect(stopCompletionCount == 1)
        #expect(controller.pendingMultiplexHostStopCompletions[hostA.connectionHash] == nil)
        controller.multiplexedViewsByHost[hostA.connectionHash] = nil
    }

    // MARK: - performNewWorkspaceAction hook

    @Test func newWorkspaceOnActiveMirrorSuppressesLocalCreation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let controller = appDelegate.remoteTmuxController
            let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
            defer { restoreRouting() }
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
