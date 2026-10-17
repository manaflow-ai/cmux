import AppKit
import CMUXAgentLaunch
import CmuxCommandPalette
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class RecordingSessionMoveLauncher: SessionMoveCLILaunching {
    struct Launch {
        let arguments: [String]
        let workingDirectory: URL?
    }

    private(set) var launches: [Launch] = []
    private var completions: [@MainActor (Int32, String) -> Void] = []

    func launchSessionMove(
        arguments: [String],
        workingDirectory: URL?,
        onOutput: @escaping @MainActor (String) -> Void,
        onCompletion: @escaping @MainActor (Int32, String) -> Void
    ) -> Bool {
        launches.append(Launch(arguments: arguments, workingDirectory: workingDirectory))
        completions.append(onCompletion)
        return true
    }

    func finishAll(succeeded: Bool, output: String = "") {
        finishAll(status: succeeded ? 0 : 1, output: output)
    }

    func finishAll(status: Int32, output: String = "") {
        let pending = completions
        completions.removeAll()
        for completion in pending {
            completion(status, output)
        }
    }
}

@MainActor
private final class RecordingSessionMoveStopper: SessionMoveAgentStopping {
    var refusal: AgentHibernationManualRefusal?
    private(set) var stopCount = 0
    private(set) var resumedPanelIds: [UUID] = []
    private(set) var endedPanelIds: [UUID] = []

    func stopAgent(workspaceId: UUID, panelId: UUID) async -> AgentHibernationManualRefusal? {
        stopCount += 1
        return refusal
    }

    func resumeAgent(workspaceId: UUID, panelId: UUID) {
        resumedPanelIds.append(panelId)
    }

    func endMovedAgent(workspaceId: UUID, panelId: UUID) {
        endedPanelIds.append(panelId)
    }
}

/// Move to Cloud stops Claude at a turn boundary, then runs
/// `cmux session move <id> --to cloud[:<machine>]` from the session's cwd.
@MainActor
@Suite(.serialized)
struct SessionMoveToCloudActionTests {
    @Test
    func aMoveStopsClaudeThenRunsTheCLIFromTheSessionDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let task = try #require(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: "m-123"))
        try await waitUntil { fixture.launcher.launches.count == 1 }

        let launch = try #require(fixture.launcher.launches.first)
        #expect(fixture.stopper.stopCount == 1)
        #expect(launch.arguments == ["session", "move", fixture.sessionId, "--to", "cloud:m-123", "--no-focus"])
        #expect(launch.workingDirectory?.standardizedFileURL.path == fixture.directory.standardizedFileURL.path)
        #expect(fixture.workspace.statusEntries[SessionMoveToCloudAction.statusKey] != nil)

        fixture.launcher.finishAll(succeeded: true)
        await task.value
        #expect(fixture.workspace.statusEntries[SessionMoveToCloudAction.statusKey] == nil)
        #expect(fixture.stopper.resumedPanelIds.isEmpty)
        #expect(fixture.notifications.isEmpty)
        // The session now runs on the machine: the pane keeps its hold and is
        // ended here for good.
        #expect(SessionMoveToCloudAction.holdsAgentResume(panelId: fixture.panelId))
        #expect(fixture.stopper.endedPanelIds == [fixture.panelId])
    }

    @Test
    func theDefaultMachineMovesToCloud() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let task = try #require(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: nil))
        try await waitUntil { fixture.launcher.launches.count == 1 }
        #expect(fixture.launcher.launches.first?.arguments == ["session", "move", fixture.sessionId, "--to", "cloud", "--no-focus"])
        fixture.launcher.finishAll(succeeded: true)
        await task.value
    }

    @Test
    func aBusyAgentIsNotMovedAndTheReasonShowsInTheSidebar() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.stopper.refusal = .agentBusy

        let task = try #require(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: nil))
        await task.value

        #expect(fixture.stopper.stopCount == 1)
        #expect(fixture.launcher.launches.isEmpty)
        #expect(fixture.workspace.statusEntries[SessionMoveToCloudAction.statusKey] != nil)
    }

    @Test
    func aSecondMoveOfTheSameSessionWhileOneRunsDoesNotLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let first = try #require(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: nil))
        try await waitUntil { fixture.launcher.launches.count == 1 }
        let second = fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: "m-2")
        await second?.value
        #expect(fixture.launcher.launches.count == 1)
        #expect(fixture.stopper.stopCount == 1)

        fixture.launcher.finishAll(succeeded: false)
        await first.value
        // The failed move no longer blocks the session.
        let third = try #require(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: nil))
        try await waitUntil { fixture.launcher.launches.count == 2 }
        fixture.launcher.finishAll(succeeded: true)
        await third.value
    }

    @Test
    func aFailedMoveResumesClaudeInPlaceAndPostsTheReason() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let task = try #require(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: nil))
        try await waitUntil { fixture.launcher.launches.count == 1 }
        fixture.launcher.finishAll(succeeded: false, output: "Error: session move: cannot reach the machine: timed out\n")
        await task.value

        #expect(fixture.stopper.resumedPanelIds == [fixture.panelId])
        #expect(fixture.workspace.statusEntries[SessionMoveToCloudAction.statusKey] == nil)
        #expect(fixture.notifications.count == 1)
        #expect(fixture.notifications.first?.contains("cannot reach the machine") == true)
        #expect(!SessionMoveToCloudAction.holdsAgentResume(panelId: fixture.panelId))
        #expect(fixture.stopper.endedPanelIds.isEmpty)
        #expect(fixture.action.canMove(workspace: fixture.workspace, panelId: fixture.panelId) != nil)
    }

    @Test
    func aPaneHeldForAMoveDoesNotWakeClaude() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let panel = try #require(fixture.workspace.terminalPanel(for: fixture.panelId))
        try #require(fixture.workspace.enterAgentHibernation(
            panelId: fixture.panelId,
            agent: Fixture.claudeAgent(sessionId: fixture.sessionId, directory: fixture.directory.path),
            lastActivityAt: Date(timeIntervalSince1970: 0)
        ))

        let task = try #require(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: nil))
        try await waitUntil { fixture.launcher.launches.count == 1 }

        #expect(SessionMoveToCloudAction.holdsAgentResume(panelId: fixture.panelId))
        #expect(panel.prepareAgentHibernationResume() == .unavailable)
        #expect(!fixture.workspace.resumeAgentHibernation(panelId: fixture.panelId, focus: false))
        #expect(panel.isAgentHibernated)

        fixture.launcher.finishAll(succeeded: true)
        await task.value
    }

    @Test
    func aFinishedMoveCannotBeMovedAgainOrReleaseItsHold() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let task = try #require(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: nil))
        try await waitUntil { fixture.launcher.launches.count == 1 }
        fixture.launcher.finishAll(succeeded: true)
        await task.value

        #expect(fixture.action.canMove(workspace: fixture.workspace, panelId: fixture.panelId) == nil)
        #expect(fixture.action.movablePanelId(in: fixture.workspace) == nil)
        #expect(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: "m-2") == nil)
        #expect(fixture.launcher.launches.count == 1)
        #expect(fixture.stopper.stopCount == 1)
        #expect(SessionMoveToCloudAction.holdsAgentResume(panelId: fixture.panelId))
    }

    @Test
    func aFailedMoveOfAnAlreadyHibernatedClaudeLeavesItAsleep() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.stopper.refusal = .alreadyHibernated

        let task = try #require(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: nil))
        try await waitUntil { fixture.launcher.launches.count == 1 }
        fixture.launcher.finishAll(status: 1, output: "Error: session move: cannot reach the machine: timed out\n")
        await task.value

        #expect(fixture.stopper.resumedPanelIds.isEmpty)
        #expect(fixture.stopper.endedPanelIds.isEmpty)
        #expect(!SessionMoveToCloudAction.holdsAgentResume(panelId: fixture.panelId))
        #expect(fixture.notifications.count == 1)
    }

    @Test
    func aMoveWhoseTerminalDidNotOpenKeepsClaudeOffThisMac() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let task = try #require(fixture.action.move(workspace: fixture.workspace, panelId: fixture.panelId, machine: nil))
        try await waitUntil { fixture.launcher.launches.count == 1 }
        // Exit status 3: the session reached the machine, a later step failed.
        fixture.launcher.finishAll(status: 3, output: "Error: session move: could not open the Cloud terminal: timed out\n")
        await task.value

        #expect(fixture.stopper.resumedPanelIds.isEmpty)
        #expect(fixture.stopper.endedPanelIds == [fixture.panelId])
        #expect(SessionMoveToCloudAction.holdsAgentResume(panelId: fixture.panelId))
        #expect(fixture.action.canMove(workspace: fixture.workspace, panelId: fixture.panelId) == nil)
        #expect(fixture.notifications.isEmpty)
        #expect(fixture.movedWithoutTerminalNotifications.count == 1)
        #expect(fixture.movedWithoutTerminalNotifications.first?.contains("could not open the Cloud terminal") == true)
        #expect(fixture.workspace.statusEntries[SessionMoveToCloudAction.statusKey] == nil)
    }

    @Test
    func endingAMovedClaudeLeavesNothingForARelaunchToResume() throws {
        let workspace = Workspace(restorableAgentIndexProvider: { .empty })
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let sessionId = UUID().uuidString.lowercased()
        try #require(workspace.enterAgentHibernation(
            panelId: panelId,
            agent: Fixture.claudeAgent(sessionId: sessionId, directory: "/tmp/cmux-move-to-cloud"),
            lastActivityAt: Date(timeIntervalSince1970: 0)
        ))
        let hibernated = workspace.sessionSnapshot(includeScrollback: false, restorableAgentIndex: .empty)
        try #require(hibernated.panels.first { $0.id == panelId }?.terminal?.agent?.sessionId == sessionId)

        workspace.endAgentHibernationAfterSessionMove(panelId: panelId)

        #expect(!panel.isAgentHibernated)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit)
        #expect(!workspace.resumeAgentHibernation(panelId: panelId, focus: false))
        let snapshot = workspace.sessionSnapshot(includeScrollback: false, restorableAgentIndex: .empty)
        let terminal = try #require(snapshot.panels.first { $0.id == panelId }?.terminal)
        #expect(terminal.agent == nil)
        #expect(terminal.hibernation == nil)

        let relaunched = Workspace(restorableAgentIndexProvider: { .empty })
        defer { relaunched.teardownAllPanels() }
        relaunched.restoreSessionSnapshot(snapshot)
        let relaunchedPanelId = try #require(relaunched.focusedPanelId)
        let relaunchedPanel = try #require(relaunched.terminalPanel(for: relaunchedPanelId))
        #expect(!relaunchedPanel.isAgentHibernated)
        #expect(relaunched.restoredAgentSnapshotsByPanelId[relaunchedPanelId] == nil)
    }

    @Test
    func onlyALocalClaudeTerminalCanMove() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(fixture.action.canMove(workspace: fixture.workspace, panelId: fixture.panelId)?.sessionId == fixture.sessionId)
        #expect(fixture.action.movablePanelId(in: fixture.workspace) == fixture.panelId)

        let codex = Fixture.action(
            snapshot: SessionRestorableAgentSnapshot(kind: .codex, sessionId: fixture.sessionId, workingDirectory: nil, launchCommand: nil),
            launcher: fixture.launcher,
            stopper: fixture.stopper
        )
        #expect(codex.canMove(workspace: fixture.workspace, panelId: fixture.panelId) == nil)

        let cloudOff = Fixture.action(
            snapshot: fixture.snapshot,
            launcher: fixture.launcher,
            stopper: fixture.stopper,
            isCloudEnabled: false
        )
        #expect(cloudOff.canMove(workspace: fixture.workspace, panelId: fixture.panelId) == nil)

        _ = fixture.workspace.configureRemoteConnection(Fixture.remoteConfiguration(), autoConnect: false)
        #expect(fixture.action.canMove(workspace: fixture.workspace, panelId: fixture.panelId) == nil)
    }

    @Test
    func theMoveStopSkipsOnlyTheOnScreenRefusal() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let visible = Self.record(workspace: workspace, panel: panel, isProtected: true)
        #expect(AgentHibernationController.manualHibernationRefusal(for: visible, teardownInFlight: false) == .visible)
        // A unit-test terminal never starts its surface, so a stop that passes
        // every safety check answers with the last one (a live terminal).
        #expect(AgentHibernationController.manualHibernationRefusal(for: visible, teardownInFlight: false, trigger: .sessionMove) == .notRunning)

        let busy = Self.record(workspace: workspace, panel: panel, isProtected: true, lifecycle: .running)
        #expect(AgentHibernationController.manualHibernationRefusal(for: busy, teardownInFlight: false, trigger: .sessionMove) == .agentBusy)
        let typed = Self.record(workspace: workspace, panel: panel, isProtected: true, hasUnconfirmedTerminalInput: true)
        #expect(AgentHibernationController.manualHibernationRefusal(for: typed, teardownInFlight: false, trigger: .sessionMove) == .unconfirmedInput)
        let recent = Self.record(workspace: workspace, panel: panel, isProtected: true, lastActivityAt: 1_000)
        #expect(AgentHibernationController.manualHibernationRefusal(for: recent, teardownInFlight: false, trigger: .sessionMove, now: 1_002) == .recentlyActive)
        let unsafe = Self.record(workspace: workspace, panel: panel, isProtected: true, containsUnrelatedProcess: true, liveness: .running)
        #expect(AgentHibernationController.manualHibernationRefusal(for: unsafe, teardownInFlight: false, trigger: .sessionMove) == .processScopeUnsafe)
    }

    @Test
    func theWorkspaceRowMenuOffersMoveToCloudForALocalClaudeOnly() throws {
        let tabManager = TabManager()
        let workspace = try #require(tabManager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(kind: .claude, sessionId: UUID().uuidString.lowercased(), workingDirectory: nil, launchCommand: nil)
        let previous = SessionMoveToCloudAction.shared
        SessionMoveToCloudAction.shared = SessionMoveToCloudAction(
            launcher: RecordingSessionMoveLauncher(),
            stopper: RecordingSessionMoveStopper(),
            resolveSnapshot: { _, id in id == panelId ? snapshot : nil },
            isCloudEnabled: { true },
            notifyFailure: { _, _ in }
        )
        defer { SessionMoveToCloudAction.shared = previous }

        let moveTitle = String(localized: "contextMenu.moveToCloud", defaultValue: "Move to Cloud")
        #expect(Self.rowMenu(tabManager: tabManager, workspace: workspace).items.contains { $0.title == moveTitle })

        _ = workspace.configureRemoteConnection(Fixture.remoteConfiguration(), autoConnect: false)
        #expect(!Self.rowMenu(tabManager: tabManager, workspace: workspace).items.contains { $0.title == moveTitle })
    }

    @Test
    func thePaletteOffersMoveToCloudForAMovableClaudeTerminal() throws {
        let contributions = ContentView.commandPaletteMoveToCloudContributions(subtitle: { _ in "" })
        let contribution = try #require(contributions.first { $0.commandId == "palette.moveAgentConversationToCloud" })

        var context = CommandPaletteContextSnapshot()
        context.setBool(CommandPaletteContextKeys.panelIsTerminal, true)
        #expect(!contribution.when(context))
        context.setBool(ContentView.panelHasMovableClaudeAgentContextKey, true)
        #expect(contribution.when(context))
    }

    // MARK: Helpers

    @MainActor
    private struct Fixture {
        let workspace: Workspace
        let panelId: UUID
        let sessionId: String
        let directory: URL
        let snapshot: SessionRestorableAgentSnapshot
        let launcher: RecordingSessionMoveLauncher
        let stopper: RecordingSessionMoveStopper
        let notificationBox: NotificationBox
        let action: SessionMoveToCloudAction

        var notifications: [String] { notificationBox.bodies }
        var movedWithoutTerminalNotifications: [String] { notificationBox.movedWithoutTerminalBodies }

        @MainActor
        final class NotificationBox {
            var bodies: [String] = []
            var movedWithoutTerminalBodies: [String] = []
        }

        init() throws {
            workspace = Workspace()
            sessionId = UUID().uuidString.lowercased()
            launcher = RecordingSessionMoveLauncher()
            stopper = RecordingSessionMoveStopper()
            notificationBox = NotificationBox()
            panelId = try #require(workspace.focusedPanelId)
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-move-cloud-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            snapshot = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: sessionId,
                workingDirectory: directory.path,
                launchCommand: nil
            )
            let box = notificationBox
            action = Self.action(
                snapshot: snapshot,
                launcher: launcher,
                stopper: stopper,
                notify: { body in box.bodies.append(body) },
                notifyMovedWithoutTerminal: { body in box.movedWithoutTerminalBodies.append(body) }
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }

        static func action(
            snapshot: SessionRestorableAgentSnapshot,
            launcher: RecordingSessionMoveLauncher,
            stopper: RecordingSessionMoveStopper,
            isCloudEnabled: Bool = true,
            notify: @escaping @MainActor (String) -> Void = { _ in },
            notifyMovedWithoutTerminal: @escaping @MainActor (String) -> Void = { _ in }
        ) -> SessionMoveToCloudAction {
            SessionMoveToCloudAction(
                launcher: launcher,
                stopper: stopper,
                resolveSnapshot: { _, _ in snapshot },
                isCloudEnabled: { isCloudEnabled },
                notifyFailure: { _, body in notify(body) },
                notifyMovedWithoutTerminal: { _, body in notifyMovedWithoutTerminal(body) }
            )
        }

        /// A Claude this pane could resume, as hibernation records it.
        static func claudeAgent(sessionId: String, directory: String) -> SessionRestorableAgentSnapshot {
            SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: sessionId,
                workingDirectory: directory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claude",
                    executablePath: "/usr/local/bin/claude",
                    arguments: ["/usr/local/bin/claude", "--model", "claude-opus-4-8"],
                    workingDirectory: directory,
                    environment: nil,
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )
        }

        static func remoteConfiguration() -> WorkspaceRemoteConfiguration {
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64_008,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini",
                foregroundAuthToken: nil,
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "move-to-cloud-test"
            )
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            await Task.yield()
        }
        try #require(condition())
    }

    private static func rowMenu(tabManager: TabManager, workspace: Workspace) -> NSMenu {
        SidebarWorkspaceRowCommands(
            tab: workspace,
            tabManager: tabManager,
            notificationStore: nil,
            index: 0,
            contextMenuWorkspaceIds: [workspace.id],
            remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false,
            allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil,
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            colorScheme: .dark,
            refreshSnapshot: {},
            readSelectedTabIds: { [] },
            writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil },
            writeLastSelectionIndex: { _ in },
            setSelectionToTabs: {},
            snapshotProvider: { nil }
        ).makeContextMenu(onOpen: {}, onClose: {}, beginInlineRename: {})
    }

    private static func record(
        workspace: Workspace,
        panel: TerminalPanel,
        isProtected: Bool,
        lifecycle: AgentHibernationLifecycleState = .idle,
        hasUnconfirmedTerminalInput: Bool = false,
        containsUnrelatedProcess: Bool = false,
        liveness: RestorableAgentProcessLiveness = .exited,
        lastActivityAt: TimeInterval = 0
    ) -> AgentHibernationRecord {
        AgentHibernationRecord(
            key: AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panel.id),
            workspace: workspace,
            terminalPanel: panel,
            agent: SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: "move-\(UUID().uuidString)",
                workingDirectory: "/tmp/cmux-move-to-cloud",
                launchCommand: nil
            ),
            lifecycle: lifecycle,
            hasUnconfirmedTerminalInput: hasUnconfirmedTerminalInput,
            lastActivityAt: lastActivityAt,
            isProtected: isProtected,
            hasLiveProcess: false,
            containsUnrelatedProcess: containsUnrelatedProcess,
            panelProcessIDs: [],
            processIDs: [],
            processIdentities: [:],
            processLiveness: liveness
        )
    }
}
