import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SurfaceHibernationPolicyTests: XCTestCase {
    private let now: TimeInterval = 100_000

    // MARK: - Global LRU cap

    func testGlobalCapCountsPlainShellSurfacesAndEvictsLeastRecentlyUsed() {
        let plainOld = panelKey()
        let plainMid = panelKey()
        let plainNew = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(plainOld, lastActivityAt: now - 3_600),
                plainShell(plainMid, lastActivityAt: now - 1_800),
                plainShell(plainNew, lastActivityAt: now - 10),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 2),
            now: now
        )

        XCTAssertEqual(selected, Set([plainOld]))
    }

    func testGlobalCapCensusIncludesExemptSurfacesMaterializedByBypassPaths() {
        // Surfaces force-created for hidden panels (background prime, queued
        // socket input) still count toward the live census even when they are
        // individually exempt from eviction, so the cap reclaims an eligible
        // surface instead of silently overflowing.
        let busy = panelKey()
        let deferredStartup = panelKey()
        let plainOld = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(busy, lastActivityAt: now - 7_200, isBusy: true),
                input(deferredStartup, mechanism: nil, lastActivityAt: now - 7_200),
                plainShell(plainOld, lastActivityAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 2),
            now: now
        )

        XCTAssertEqual(selected, Set([plainOld]))
    }

    func testGlobalCapEvictionInterleavesAgentAndPlainSurfacesByLRU() {
        let agentOldest = panelKey()
        let plainMiddle = panelKey()
        let plainNewest = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                agentPanel(agentOldest, lifecycle: .idle, lastActivityAt: now - 7_200),
                plainShell(plainMiddle, lastActivityAt: now - 3_600),
                plainShell(plainNewest, lastActivityAt: now - 400),
            ],
            agentSettings: agentSettings(enabled: true, maxLiveTerminals: 99),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 1),
            now: now
        )

        XCTAssertEqual(selected, Set([agentOldest, plainMiddle]))
    }

    func testGlobalCapSelectsNothingAtOrUnderLimit() {
        let first = panelKey()
        let second = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(first, lastActivityAt: now - 7_200),
                plainShell(second, lastActivityAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 2),
            now: now
        )

        XCTAssertTrue(selected.isEmpty)
    }

    func testGlobalCapHonorsIdleGateForRecentlyActiveSurfaces() {
        // Two surfaces over a cap of one, but the only LRU candidate beyond the
        // cap has been active within the idle window: nothing is evicted.
        let recentOld = panelKey()
        let recentNew = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(recentOld, lastActivityAt: now - 200),
                plainShell(recentNew, lastActivityAt: now - 100),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(idleSeconds: 300, maxLiveSurfaces: 1),
            now: now
        )

        XCTAssertTrue(selected.isEmpty)
    }

    func testLRUTieBreaksByPanelIdForDeterminism() {
        let workspaceId = UUID()
        let first = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let second = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let expected = first.panelId.uuidString < second.panelId.uuidString ? first : second

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(first, lastActivityAt: now - 3_600),
                plainShell(second, lastActivityAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 1),
            now: now
        )

        XCTAssertEqual(selected, Set([expected]))
    }

    // MARK: - Unmounted-workspace idle rule

    func testUnmountedWorkspaceSurfacesHibernateAfterIdleWindowWithoutCapPressure() {
        let unmounted = panelKey()
        let mounted = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(unmounted, lastActivityAt: now - 3_600, workspaceUnmountedAt: now - 3_600),
                plainShell(mounted, lastActivityAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(unmountedIdleSeconds: 1_800, maxLiveSurfaces: 12),
            now: now
        )

        XCTAssertEqual(selected, Set([unmounted]))
    }

    func testUnmountedRuleRequiresBothQuietAndUnmountedWindows() {
        let quiet = panelKey()
        let recentInput = panelKey()
        let recentlyUnmounted = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(quiet, lastActivityAt: now - 3_600, workspaceUnmountedAt: now - 3_600),
                plainShell(recentInput, lastActivityAt: now - 300, workspaceUnmountedAt: now - 3_600),
                plainShell(recentlyUnmounted, lastActivityAt: now - 3_600, workspaceUnmountedAt: now - 300),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(unmountedIdleSeconds: 1_800, maxLiveSurfaces: 12),
            now: now
        )

        XCTAssertEqual(selected, Set([quiet]))
    }

    func testUnmountedRuleHibernatesIdleAgentPanelsWhenAgentHibernationEnabled() {
        let idleAgent = panelKey()
        let runningAgent = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                agentPanel(idleAgent, lifecycle: .idle, lastActivityAt: now - 3_600, workspaceUnmountedAt: now - 3_600),
                agentPanel(runningAgent, lifecycle: .running, lastActivityAt: now - 3_600, workspaceUnmountedAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: true, maxLiveTerminals: 99),
            surfaceSettings: surfaceSettings(unmountedIdleSeconds: 1_800, maxLiveSurfaces: 12),
            now: now
        )

        XCTAssertEqual(selected, Set([idleAgent]))
    }

    func testMountedWorkspaceQuietSurfaceIsNotSelectedWithoutCapPressure() {
        let mounted = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(mounted, lastActivityAt: now - 86_400),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 12),
            now: now
        )

        XCTAssertTrue(selected.isEmpty)
    }

    // MARK: - Exemptions

    func testBusySurfaceIsExemptFromShellRestartHibernation() {
        let busyOld = panelKey()
        let idleOld = panelKey()

        let capSelected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(busyOld, lastActivityAt: now - 7_200, isBusy: true),
                plainShell(idleOld, lastActivityAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 1),
            now: now
        )
        XCTAssertEqual(capSelected, Set([idleOld]))

        let unmountedSelected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(busyOld, lastActivityAt: now - 7_200, isBusy: true, workspaceUnmountedAt: now - 7_200),
                plainShell(idleOld, lastActivityAt: now - 3_600, workspaceUnmountedAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(unmountedIdleSeconds: 1_800, maxLiveSurfaces: 12),
            now: now
        )
        XCTAssertEqual(unmountedSelected, Set([idleOld]))
    }

    func testAgentPanelsAreNeverShellRestartedWhenAgentHibernationDisabled() {
        let agentOld = panelKey()
        let plainOld = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                agentPanel(agentOld, lifecycle: .idle, lastActivityAt: now - 7_200, workspaceUnmountedAt: now - 7_200),
                plainShell(plainOld, lastActivityAt: now - 3_600, workspaceUnmountedAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(unmountedIdleSeconds: 1_800, maxLiveSurfaces: 1),
            now: now
        )

        XCTAssertEqual(selected, Set([plainOld]))
    }

    func testProtectedVisibleSurfaceIsNeverEvicted() {
        let protectedOld = panelKey()
        let backgroundOld = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(protectedOld, lastActivityAt: now - 7_200, isProtected: true, workspaceUnmountedAt: now - 7_200),
                plainShell(backgroundOld, lastActivityAt: now - 3_600, workspaceUnmountedAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(unmountedIdleSeconds: 1_800, maxLiveSurfaces: 1),
            now: now
        )

        XCTAssertEqual(selected, Set([backgroundOld]))
    }

    func testUnconfirmedTerminalInputExemptsSurface() {
        let unconfirmedOld = panelKey()
        let cleanOld = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(unconfirmedOld, lastActivityAt: now - 7_200, hasUnconfirmedTerminalInput: true),
                plainShell(cleanOld, lastActivityAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 1),
            now: now
        )

        XCTAssertEqual(selected, Set([cleanOld]))
    }

    func testSurfaceWithoutHibernationMechanismIsExempt() {
        let deferredStartupOld = panelKey()
        let plainOld = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                input(deferredStartupOld, mechanism: nil, lastActivityAt: now - 7_200, workspaceUnmountedAt: now - 7_200),
                plainShell(plainOld, lastActivityAt: now - 3_600, workspaceUnmountedAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(unmountedIdleSeconds: 1_800, maxLiveSurfaces: 1),
            now: now
        )

        XCTAssertEqual(selected, Set([plainOld]))
    }

    func testNonLiveSurfacesAreNeitherCountedNorSelected() {
        let hibernated = panelKey()
        let live = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                input(hibernated, mechanism: .shellRestart, isLive: false, lastActivityAt: now - 7_200),
                plainShell(live, lastActivityAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 1),
            now: now
        )

        XCTAssertTrue(selected.isEmpty)
    }

    // MARK: - Disabled states and agent-rule parity

    func testDisabledSurfaceHibernationSelectsNoPlainShells() {
        let plainOld = panelKey()
        let plainNew = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(plainOld, lastActivityAt: now - 7_200, workspaceUnmountedAt: now - 7_200),
                plainShell(plainNew, lastActivityAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(enabled: false, maxLiveSurfaces: 1),
            now: now
        )

        XCTAssertTrue(selected.isEmpty)
    }

    func testAgentCapBehaviorIsPreservedWhenSurfaceHibernationDisabled() {
        let workspaceId = UUID()
        let idleOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let idleNew = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let runningOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let needsInputOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let unconfirmedOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let protectedOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                agentPanel(idleOld, lifecycle: .idle, lastActivityAt: now - 300),
                agentPanel(idleNew, lifecycle: .idle, lastActivityAt: now - 10),
                agentPanel(runningOld, lifecycle: .running, lastActivityAt: now - 300),
                agentPanel(needsInputOld, lifecycle: .needsInput, lastActivityAt: now - 300),
                agentPanel(unconfirmedOld, lifecycle: .idle, hasUnconfirmedTerminalInput: true, lastActivityAt: now - 300),
                agentPanel(protectedOld, lifecycle: .idle, isProtected: true, lastActivityAt: now - 300),
            ],
            agentSettings: agentSettings(enabled: true, idleSeconds: 60, maxLiveTerminals: 1),
            surfaceSettings: surfaceSettings(enabled: false),
            now: now
        )

        XCTAssertEqual(selected, Set([idleOld]))
    }

    // MARK: - Settings

    func testSurfaceHibernationSettingsDefaults() throws {
        let suiteName = "cmux-surface-hibernation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(SurfaceHibernationSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(SurfaceHibernationSettings.idleSeconds(defaults: defaults), 300)
        XCTAssertEqual(SurfaceHibernationSettings.unmountedIdleSeconds(defaults: defaults), 1_800)
        XCTAssertEqual(SurfaceHibernationSettings.maxLiveSurfaces(defaults: defaults), 12)
        XCTAssertEqual(SurfaceHibernationSettings.confirmationSeconds(defaults: defaults), 60)
    }

    func testSurfaceHibernationSettingsSanitizeAndNotifyOnce() throws {
        let suiteName = "cmux-surface-hibernation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationCenter = NotificationCenter()
        var notificationCount = 0
        let observer = notificationCenter.addObserver(
            forName: SurfaceHibernationSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        SurfaceHibernationSettings.setValues(
            enabled: false,
            idleSeconds: 1,
            unmountedIdleSeconds: 1,
            maxLiveSurfaces: 0,
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        let values = SurfaceHibernationSettings.values(defaults: defaults)
        XCTAssertFalse(values.enabled)
        XCTAssertEqual(values.idleSeconds, 30)
        XCTAssertEqual(values.unmountedIdleSeconds, 60)
        XCTAssertEqual(values.maxLiveSurfaces, 1)
        XCTAssertEqual(notificationCount, 1)

        XCTAssertEqual(SurfaceHibernationSettings.sanitizedMaxLiveSurfaces(9_999), 256)

        XCTAssertTrue(SurfaceHibernationSettings.reset(defaults: defaults, notificationCenter: notificationCenter))
        XCTAssertEqual(SurfaceHibernationSettings.values(defaults: defaults).maxLiveSurfaces, 12)
        XCTAssertEqual(notificationCount, 2)

        SurfaceHibernationSettings.setValues(
            enabled: SurfaceHibernationSettings.defaultEnabled,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(notificationCount, 2)
    }

    // MARK: - Hibernate-then-restore round trip

    @MainActor
    func testSurfaceHibernationRoundTripStagesScrollbackAndWorkingDirectory() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: "hibernated-shell-content",
            workingDirectory: "/tmp/cmux-surface-hibernation",
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertTrue(panel.isSurfaceHibernated)
        XCTAssertEqual(panel.surfaceHibernationState?.scrollback, "hibernated-shell-content")
        XCTAssertEqual(panel.surfaceHibernationState?.workingDirectory, "/tmp/cmux-surface-hibernation")

        XCTAssertTrue(workspace.restoreSurfaceHibernation(panelId: panelId, focus: false))
        XCTAssertFalse(panel.isSurfaceHibernated)

        let environment = panel.surface.debugAdditionalEnvironmentForTesting()
        let replayPath = try XCTUnwrap(environment[SessionScrollbackReplayStore.environmentKey])
        let replayContents = try String(contentsOfFile: replayPath, encoding: .utf8)
        XCTAssertTrue(replayContents.contains("hibernated-shell-content"))
        XCTAssertEqual(
            panel.surface.debugNextRuntimeWorkingDirectoryForTesting(),
            "/tmp/cmux-surface-hibernation"
        )
    }

    @MainActor
    func testWorkspaceEnterSurfaceHibernationCapturesPanelDirectory() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        workspace.panelDirectories[panelId] = "/tmp/cmux-surface-hibernation-dir"

        XCTAssertTrue(
            workspace.enterSurfaceHibernation(panelId: panelId, lastActivityAt: Date(timeIntervalSince1970: 50))
        )
        XCTAssertTrue(panel.isSurfaceHibernated)
        XCTAssertEqual(
            panel.surfaceHibernationState?.workingDirectory,
            "/tmp/cmux-surface-hibernation-dir"
        )
        XCTAssertFalse(
            workspace.enterSurfaceHibernation(panelId: panelId, lastActivityAt: Date(timeIntervalSince1970: 60)),
            "A hibernated panel must not be hibernated twice"
        )
    }

    @MainActor
    func testExplicitInputToSurfaceHibernatedPanelRestoresAndQueues() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: nil,
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isSurfaceHibernated)

        let result = panel.sendInputResult("pwd\r")

        XCTAssertEqual(result, .queued)
        XCTAssertFalse(panel.isSurfaceHibernated)
    }

    @MainActor
    func testFocusingSurfaceHibernatedPanelRestoresIt() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: nil,
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isSurfaceHibernated)

        workspace.focusPanel(panelId)

        XCTAssertFalse(panel.isSurfaceHibernated)
    }

    @MainActor
    func testHiddenMountedWorkspaceDoesNotAutoRestoreSurfaceHibernatedPanel() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: nil,
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isSurfaceHibernated)

        workspace.setAgentHibernationAutoResumePresentationVisible(false)
        _ = workspace.debugReconcileTerminalPortalVisibilityForTesting()
        XCTAssertTrue(panel.isSurfaceHibernated)

        workspace.setAgentHibernationAutoResumePresentationVisible(true)

        XCTAssertFalse(panel.isSurfaceHibernated)
    }

    @MainActor
    func testAgentHibernatedPanelCannotEnterSurfaceHibernation() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-surface-cross-guard",
            workingDirectory: "/tmp/cmux-surface-hibernation",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: "/tmp/cmux-surface-hibernation",
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)

        XCTAssertFalse(
            workspace.enterSurfaceHibernation(panelId: panelId, lastActivityAt: Date(timeIntervalSince1970: 10))
        )
        XCTAssertFalse(panel.isSurfaceHibernated)
    }

    @MainActor
    func testSessionSnapshotCarriesHibernatedScrollback() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: "hibernated-snapshot-content",
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: true)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })

        XCTAssertEqual(panelSnapshot.terminal?.scrollback, "hibernated-snapshot-content")
    }

    @MainActor
    func testScrollbackFreeSnapshotStillPersistsHibernatedScrollback() throws {
        // The freed surface's content exists only in the hibernation state, so
        // even autosaves that skip scrollback capture must not overwrite the
        // session snapshot with nil.
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: "hibernated-autosave-content",
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })

        XCTAssertEqual(panelSnapshot.terminal?.scrollback, "hibernated-autosave-content")
    }

    @MainActor
    func testAutosaveFingerprintTracksSurfaceHibernationTransitions() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)

        let liveFingerprint = manager.sessionAutosaveFingerprint()
        panel.enterSurfaceHibernation(
            scrollback: nil,
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
        let hibernatedFingerprint = manager.sessionAutosaveFingerprint()

        XCTAssertNotEqual(liveFingerprint, hibernatedFingerprint)
        XCTAssertTrue(workspace.restoreSurfaceHibernation(panelId: panelId, focus: false))
        XCTAssertNotEqual(hibernatedFingerprint, manager.sessionAutosaveFingerprint())
    }

    @MainActor
    func testWorkspaceUnmountTimestampTracksPortalRendering() {
        let workspace = Workspace()
        XCTAssertNotNil(
            workspace.portalRenderingDisabledAt,
            "A workspace that has never rendered must age toward unmounted-idle hibernation"
        )

        workspace.setPortalRenderingEnabled(true, reason: "test")
        XCTAssertNil(workspace.portalRenderingDisabledAt)

        workspace.setPortalRenderingEnabled(false, reason: "test")
        let disabledAt = workspace.portalRenderingDisabledAt
        XCTAssertNotNil(disabledAt)

        workspace.setPortalRenderingEnabled(false, reason: "test")
        XCTAssertEqual(
            workspace.portalRenderingDisabledAt,
            disabledAt,
            "Repeated unmount reconciles must not restart the unmounted clock"
        )
    }

    // MARK: - Helpers

    private func panelKey() -> AgentHibernationPanelKey {
        AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
    }

    private func plainShell(
        _ key: AgentHibernationPanelKey,
        lastActivityAt: TimeInterval,
        isProtected: Bool = false,
        isBusy: Bool = false,
        hasUnconfirmedTerminalInput: Bool = false,
        workspaceUnmountedAt: TimeInterval? = nil
    ) -> SurfaceHibernationPlannerInput {
        SurfaceHibernationPlannerInput(
            key: key,
            mechanism: .shellRestart,
            isLive: true,
            isProtected: isProtected,
            isBusy: isBusy,
            lifecycle: .unknown,
            hasUnconfirmedTerminalInput: hasUnconfirmedTerminalInput,
            lastActivityAt: lastActivityAt,
            workspaceUnmountedAt: workspaceUnmountedAt
        )
    }

    private func agentPanel(
        _ key: AgentHibernationPanelKey,
        lifecycle: AgentHibernationLifecycleState,
        isProtected: Bool = false,
        hasUnconfirmedTerminalInput: Bool = false,
        lastActivityAt: TimeInterval,
        workspaceUnmountedAt: TimeInterval? = nil
    ) -> SurfaceHibernationPlannerInput {
        SurfaceHibernationPlannerInput(
            key: key,
            mechanism: .agentResume,
            isLive: true,
            isProtected: isProtected,
            // A running agent TUI keeps the surface away from the shell prompt,
            // so real agent panels always report busy. Busy only exempts the
            // shellRestart mechanism; the agent mechanism is gated on the
            // hook-reported lifecycle instead, which these tests exercise.
            isBusy: true,
            lifecycle: lifecycle,
            hasUnconfirmedTerminalInput: hasUnconfirmedTerminalInput,
            lastActivityAt: lastActivityAt,
            workspaceUnmountedAt: workspaceUnmountedAt
        )
    }

    private func input(
        _ key: AgentHibernationPanelKey,
        mechanism: SurfaceHibernationMechanism?,
        isLive: Bool = true,
        lastActivityAt: TimeInterval,
        workspaceUnmountedAt: TimeInterval? = nil
    ) -> SurfaceHibernationPlannerInput {
        SurfaceHibernationPlannerInput(
            key: key,
            mechanism: mechanism,
            isLive: isLive,
            isProtected: false,
            lastActivityAt: lastActivityAt,
            workspaceUnmountedAt: workspaceUnmountedAt
        )
    }

    private func agentSettings(
        enabled: Bool,
        idleSeconds: TimeInterval = 60,
        maxLiveTerminals: Int = 12,
        confirmationSeconds: TimeInterval = 5
    ) -> AgentHibernationSettings.Values {
        AgentHibernationSettings.Values(
            enabled: enabled,
            idleSeconds: idleSeconds,
            maxLiveTerminals: maxLiveTerminals,
            confirmationSeconds: confirmationSeconds
        )
    }

    private func surfaceSettings(
        enabled: Bool = true,
        idleSeconds: TimeInterval = 300,
        unmountedIdleSeconds: TimeInterval = 1_800,
        maxLiveSurfaces: Int = 12,
        confirmationSeconds: TimeInterval = 60
    ) -> SurfaceHibernationSettings.Values {
        SurfaceHibernationSettings.Values(
            enabled: enabled,
            idleSeconds: idleSeconds,
            unmountedIdleSeconds: unmountedIdleSeconds,
            maxLiveSurfaces: maxLiveSurfaces,
            confirmationSeconds: confirmationSeconds
        )
    }
}
