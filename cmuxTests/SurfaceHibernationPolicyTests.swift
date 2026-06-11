import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Workspace/TabManager round-trip tests below mutate shared app singletons
// (AgentHibernationController, portal registries), so the suite runs
// serialized rather than guarding that state with locks.
@Suite(.serialized)
struct SurfaceHibernationPolicyTests {
    private let now: TimeInterval = 100_000

    // MARK: - Global LRU cap

    @Test
    func globalCapCountsPlainShellSurfacesAndEvictsLeastRecentlyUsed() {
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

        #expect(selected == Set([plainOld]))
    }

    @Test
    func globalCapCensusIncludesExemptSurfacesMaterializedByBypassPaths() {
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

        #expect(selected == Set([plainOld]))
    }

    @Test
    func globalCapEvictionInterleavesAgentAndPlainSurfacesByLRU() {
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

        #expect(selected == Set([agentOldest, plainMiddle]))
    }

    @Test
    func globalCapSelectsNothingAtOrUnderLimit() {
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

        #expect(selected.isEmpty)
    }

    @Test
    func globalCapHonorsIdleGateForRecentlyActiveSurfaces() {
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

        #expect(selected.isEmpty)
    }

    @Test
    func lruTieBreaksByPanelIdForDeterminism() {
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

        #expect(selected == Set([expected]))
    }

    // MARK: - Unmounted-workspace idle rule

    @Test
    func unmountedWorkspaceSurfacesHibernateAfterIdleWindowWithoutCapPressure() {
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

        #expect(selected == Set([unmounted]))
    }

    @Test
    func unmountedRuleRequiresBothQuietAndUnmountedWindows() {
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

        #expect(selected == Set([quiet]))
    }

    @Test
    func unmountedRuleHibernatesIdleAgentPanelsWhenAgentHibernationEnabled() {
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

        #expect(selected == Set([idleAgent]))
    }

    @Test
    func globalCapDiscountsSurfacesOtherRulesAlreadySelected() {
        // Agent-cap and unmounted selections are about to stop being live, so
        // the global cap must not reclaim additional plain shells for the
        // same overflow.
        let agentOld = panelKey()
        let agentNew = panelKey()
        let plainOld = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                agentPanel(agentOld, lifecycle: .idle, lastActivityAt: now - 7_200),
                agentPanel(agentNew, lifecycle: .idle, lastActivityAt: now - 3_600),
                plainShell(plainOld, lastActivityAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: true, maxLiveTerminals: 1),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 2),
            now: now
        )

        // The agent cap evicts agentOld, bringing the live count to the
        // global cap of 2; the plain shell must survive.
        #expect(selected == Set([agentOld]))
    }

    @Test
    func unmountedRuleDrainsOldestFirstBoundedPerEvaluation() {
        // Hibernation work runs synchronously on the main actor, so a large
        // cohort crossing the idle window together drains a few per pass.
        let keys = (0..<6).map { _ in panelKey() }
        let inputs = keys.enumerated().map { index, key in
            plainShell(
                key,
                lastActivityAt: now - 7_200 - TimeInterval(index),
                workspaceUnmountedAt: now - 7_200 - TimeInterval(index)
            )
        }

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: inputs,
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(unmountedIdleSeconds: 1_800, maxLiveSurfaces: 12),
            now: now
        )

        #expect(selected.count == SurfaceHibernationPlanner.maxSelectionsPerEvaluation)
        // Oldest first: the last inputs have the oldest activity timestamps.
        let expected = Set(keys.suffix(SurfaceHibernationPlanner.maxSelectionsPerEvaluation))
        #expect(selected == expected)
    }

    @Test
    func mountedWorkspaceQuietSurfaceIsNotSelectedWithoutCapPressure() {
        let mounted = panelKey()

        let selected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(mounted, lastActivityAt: now - 86_400),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(maxLiveSurfaces: 12),
            now: now
        )

        #expect(selected.isEmpty)
    }

    // MARK: - Exemptions

    @Test
    func busySurfaceIsExemptFromShellRestartHibernation() {
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
        #expect(capSelected == Set([idleOld]))

        let unmountedSelected = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: [
                plainShell(busyOld, lastActivityAt: now - 7_200, isBusy: true, workspaceUnmountedAt: now - 7_200),
                plainShell(idleOld, lastActivityAt: now - 3_600, workspaceUnmountedAt: now - 3_600),
            ],
            agentSettings: agentSettings(enabled: false),
            surfaceSettings: surfaceSettings(unmountedIdleSeconds: 1_800, maxLiveSurfaces: 12),
            now: now
        )
        #expect(unmountedSelected == Set([idleOld]))
    }

    @Test
    func agentPanelsAreNeverShellRestartedWhenAgentHibernationDisabled() {
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

        #expect(selected == Set([plainOld]))
    }

    @Test
    func protectedVisibleSurfaceIsNeverEvicted() {
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

        #expect(selected == Set([backgroundOld]))
    }

    @Test
    func unconfirmedTerminalInputExemptsSurface() {
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

        #expect(selected == Set([cleanOld]))
    }

    @Test
    func surfaceWithoutHibernationMechanismIsExempt() {
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

        #expect(selected == Set([plainOld]))
    }

    @Test
    func nonLiveSurfacesAreNeitherCountedNorSelected() {
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

        #expect(selected.isEmpty)
    }

    // MARK: - Disabled states and agent-rule parity

    @Test
    func disabledSurfaceHibernationSelectsNoPlainShells() {
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

        #expect(selected.isEmpty)
    }

    @Test
    func agentCapBehaviorIsPreservedWhenSurfaceHibernationDisabled() {
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

        #expect(selected == Set([idleOld]))
    }

    // MARK: - Settings

    @Test
    func surfaceHibernationSettingsDefaults() throws {
        let suiteName = "cmux-surface-hibernation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SurfaceHibernationSettings.isEnabled(defaults: defaults))
        #expect(SurfaceHibernationSettings.idleSeconds(defaults: defaults) == 300)
        #expect(SurfaceHibernationSettings.unmountedIdleSeconds(defaults: defaults) == 1_800)
        #expect(SurfaceHibernationSettings.maxLiveSurfaces(defaults: defaults) == 12)
        #expect(SurfaceHibernationSettings.confirmationSeconds(defaults: defaults) == 60)
    }

    @Test
    func surfaceHibernationSettingsSanitizeAndNotifyOnce() throws {
        let suiteName = "cmux-surface-hibernation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
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
        #expect(!(values.enabled))
        #expect(values.idleSeconds == 30)
        #expect(values.unmountedIdleSeconds == 60)
        #expect(values.maxLiveSurfaces == 1)
        #expect(notificationCount == 1)

        #expect(SurfaceHibernationSettings.sanitizedMaxLiveSurfaces(9_999) == 256)

        #expect(SurfaceHibernationSettings.reset(defaults: defaults, notificationCenter: notificationCenter))
        #expect(SurfaceHibernationSettings.values(defaults: defaults).maxLiveSurfaces == 12)
        #expect(notificationCount == 2)

        SurfaceHibernationSettings.setValues(
            enabled: SurfaceHibernationSettings.defaultEnabled,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        #expect(notificationCount == 2)
    }

    // MARK: - Hibernate-then-restore round trip

    @MainActor
    @Test
    func surfaceHibernationRoundTripStagesScrollbackAndWorkingDirectory() throws {
        // Restore staging validates the captured directory on disk, so the
        // test must use one that actually exists.
        let capturedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-hibernation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: capturedDirectory) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: "hibernated-shell-content",
            workingDirectory: capturedDirectory.path,
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
        #expect(panel.isSurfaceHibernated)
        #expect(panel.surfaceHibernationState?.scrollback == "hibernated-shell-content")
        #expect(panel.surfaceHibernationState?.workingDirectory == capturedDirectory.path)

        #expect(workspace.restoreSurfaceHibernation(panelId: panelId, focus: false))
        #expect(!(panel.isSurfaceHibernated))

        let environment = panel.surface.debugAdditionalEnvironmentForTesting()
        let replayPath = try #require(environment[SessionScrollbackReplayStore.environmentKey])
        let replayContents = try String(contentsOfFile: replayPath, encoding: .utf8)
        #expect(replayContents.contains("hibernated-shell-content"))
        #expect(panel.surface.debugNextRuntimeWorkingDirectoryForTesting() == capturedDirectory.path)
    }

    @MainActor
    @Test
    func surfaceHibernationRestoreStagesCapturedDirectoryWithoutDiskChecks() throws {
        // Staging must not stat the path (a dead network mount would hang the
        // main thread); Ghostty ignores an unspawnable cwd at spawn time and
        // the override is consumed even when creation fails.
        let missingDirectory = "/tmp/cmux-surface-hibernation-missing-\(UUID().uuidString)"
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: nil,
            workingDirectory: missingDirectory,
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )

        #expect(workspace.restoreSurfaceHibernation(panelId: panelId, focus: false))
        #expect(panel.surface.debugNextRuntimeWorkingDirectoryForTesting() == missingDirectory)
    }

    @MainActor
    @Test
    func workspaceEnterSurfaceHibernationCapturesPanelDirectory() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        workspace.panelDirectories[panelId] = "/tmp/cmux-surface-hibernation-dir"

        #expect(workspace.enterSurfaceHibernation(panelId: panelId, lastActivityAt: Date(timeIntervalSince1970: 50)))
        #expect(panel.isSurfaceHibernated)
        #expect(panel.surfaceHibernationState?.workingDirectory == "/tmp/cmux-surface-hibernation-dir")
        #expect(
            !workspace.enterSurfaceHibernation(panelId: panelId, lastActivityAt: Date(timeIntervalSince1970: 60)),
            "A hibernated panel must not be hibernated twice"
        )
    }

    @MainActor
    @Test
    func explicitInputToSurfaceHibernatedPanelRestoresAndQueues() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: nil,
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        #expect(panel.isSurfaceHibernated)

        let result = panel.sendInputResult("pwd\r")

        #expect(result == .queued)
        #expect(!(panel.isSurfaceHibernated))
    }

    @MainActor
    @Test
    func focusingSurfaceHibernatedPanelRestoresIt() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: nil,
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        #expect(panel.isSurfaceHibernated)

        workspace.focusPanel(panelId)

        #expect(!(panel.isSurfaceHibernated))
    }

    @MainActor
    @Test
    func reconcileRestoresRenderedSurfaceHibernatedPanelEvenWhenInputInactive() throws {
        // Surface hibernation has no placeholder UI, so a rendered panel must
        // restore even when the workspace is visible but not input-active
        // (e.g. in a non-key window) — unlike agent resume, which stays gated
        // on the presentation flag.
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: nil,
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        #expect(panel.isSurfaceHibernated)

        workspace.setAgentHibernationAutoResumePresentationVisible(false)
        _ = workspace.debugReconcileTerminalPortalVisibilityForTesting()

        #expect(!(panel.isSurfaceHibernated))
    }

    @MainActor
    @Test
    func agentHibernatedPanelCannotEnterSurfaceHibernation() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
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
        #expect(panel.isAgentHibernated)

        #expect(!workspace.enterSurfaceHibernation(panelId: panelId, lastActivityAt: Date(timeIntervalSince1970: 10)))
        #expect(!(panel.isSurfaceHibernated))
    }

    @MainActor
    @Test
    func sessionSnapshotCarriesHibernatedScrollback() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: "hibernated-snapshot-content",
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: true)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panelId })

        #expect(panelSnapshot.terminal?.scrollback == "hibernated-snapshot-content")
    }

    @MainActor
    @Test
    func scrollbackFreeSnapshotStillPersistsHibernatedScrollback() throws {
        // The freed surface's content exists only in the hibernation state, so
        // even autosaves that skip scrollback capture must not overwrite the
        // session snapshot with nil.
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)

        panel.enterSurfaceHibernation(
            scrollback: "hibernated-autosave-content",
            workingDirectory: "/tmp/cmux-hibernated-autosave-dir",
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panelId })

        #expect(panelSnapshot.terminal?.scrollback == "hibernated-autosave-content")
        #expect(panelSnapshot.terminal?.workingDirectory == "/tmp/cmux-hibernated-autosave-dir")
    }

    @MainActor
    @Test
    func autosaveFingerprintTracksSurfaceHibernationTransitions() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)

        let liveFingerprint = manager.sessionAutosaveFingerprint()
        panel.enterSurfaceHibernation(
            scrollback: nil,
            workingDirectory: nil,
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
        let hibernatedFingerprint = manager.sessionAutosaveFingerprint()

        #expect(liveFingerprint != hibernatedFingerprint)
        #expect(workspace.restoreSurfaceHibernation(panelId: panelId, focus: false))
        #expect(hibernatedFingerprint != manager.sessionAutosaveFingerprint())
    }

    @Test
    func firstTailSampleUsesUnmountedFloorOnlyWhenProvided() {
        // Cap-rule candidates keep the conservative now-based stability start.
        #expect(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: nil,
                previousStableSince: nil,
                currentFingerprint: "tail-a",
                lastActivityAt: 100,
                now: 500
            ) == 500
        )
        // Unmounted-workspace candidates pass the wall-clock floor so the
        // documented hidden-workspace window is not observed twice.
        #expect(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: nil,
                previousStableSince: nil,
                currentFingerprint: "tail-a",
                lastActivityAt: 100,
                now: 500,
                firstSampleFallback: 150
            ) == 150
        )
        // A genuinely changed fingerprint always restarts the window at now.
        #expect(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: "tail-a",
                previousStableSince: 100,
                currentFingerprint: "tail-b",
                lastActivityAt: 100,
                now: 500,
                firstSampleFallback: 150
            ) == 500
        )
    }

    @MainActor
    @Test
    func workspaceUnmountTimestampTracksPortalRendering() {
        let workspace = Workspace()
        #expect(
            workspace.portalRenderingDisabledAt != nil,
            "A workspace that has never rendered must age toward unmounted-idle hibernation"
        )

        workspace.setPortalRenderingEnabled(true, reason: "test")
        #expect(workspace.portalRenderingDisabledAt == nil)

        workspace.setPortalRenderingEnabled(false, reason: "test")
        let disabledAt = workspace.portalRenderingDisabledAt
        #expect(disabledAt != nil)

        workspace.setPortalRenderingEnabled(false, reason: "test")
        #expect(
            workspace.portalRenderingDisabledAt == disabledAt,
            "Repeated unmount reconciles must not restart the unmounted clock"
        )
    }

    @MainActor
    @Test
    func emptyHibernationCaptureClearsStaleScrollbackFallback() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        // A leftover entry from session-restore seeding that no longer
        // reflects the terminal (it was cleared, or replay never ran).
        workspace.restoredTerminalScrollbackByPanelId[panelId] = "stale old-session text"

        #expect(workspace.enterSurfaceHibernation(panelId: panelId, lastActivityAt: Date(timeIntervalSince1970: 50)))

        #expect(
            workspace.restoredTerminalScrollbackByPanelId[panelId] == nil,
            "An empty capture must clear the fallback, or a restore-window save resurrects unrelated scrollback"
        )
    }

    // MARK: - Pending command-line survivals

    @MainActor
    @Test
    func plainTextInputDoesNotDropBatchedPromptSurvivals() {
        let wasTracking = AgentHibernationTrackingGate.isEnabled()
        AgentHibernationTrackingGate.setEnabled(true)
        defer { AgentHibernationTrackingGate.setEnabled(wasTracking) }
        let controller = AgentHibernationController.shared
        let workspaceId = UUID()
        let panelId = UUID()
        let base = Date()

        // Queued payload "cmd\npartial": one settling newline, trailing text.
        controller.recordTerminalInput(
            workspaceId: workspaceId,
            panelId: panelId,
            recordedAt: base,
            armsPendingCommandLine: true,
            pendingPromptSurvivals: 1
        )
        // "x" arrives before the shell reports cmd's preexec; it appends to
        // the eventual editable line and must not consume the survival.
        controller.recordTerminalInput(
            workspaceId: workspaceId,
            panelId: panelId,
            recordedAt: base.addingTimeInterval(0.01),
            armsPendingCommandLine: true,
            pendingPromptSurvivals: 0
        )
        controller.recordShellActivityTransition(
            workspaceId: workspaceId,
            panelId: panelId,
            state: .commandRunning,
            recordedAt: base.addingTimeInterval(0.02)
        )
        controller.recordShellActivityTransition(
            workspaceId: workspaceId,
            panelId: panelId,
            state: .promptIdle,
            recordedAt: base.addingTimeInterval(0.03)
        )

        let state = controller.debugPendingCommandLineStateForTesting(
            workspaceId: workspaceId,
            panelId: panelId
        )
        #expect(
            state.pendingAt != nil,
            "cmd's own prompt return must consume the survival, not the pending guard for the editable \"partialx\""
        )
    }

    @MainActor
    @Test
    func batchedPromptSurvivalsAccumulateAcrossPayloads() {
        let wasTracking = AgentHibernationTrackingGate.isEnabled()
        AgentHibernationTrackingGate.setEnabled(true)
        defer { AgentHibernationTrackingGate.setEnabled(wasTracking) }
        let controller = AgentHibernationController.shared
        let workspaceId = UUID()
        let panelId = UUID()
        let base = Date()

        // Two queued payloads, each with one settling newline and trailing
        // text: the first batch's leftovers get submitted by the second
        // batch's newline, so both transitions must be survived.
        for offset in [0.0, 0.01] {
            controller.recordTerminalInput(
                workspaceId: workspaceId,
                panelId: panelId,
                recordedAt: base.addingTimeInterval(offset),
                armsPendingCommandLine: true,
                pendingPromptSurvivals: 1
            )
        }
        for (index, offset) in [0.02, 0.03, 0.04, 0.05].enumerated() {
            controller.recordShellActivityTransition(
                workspaceId: workspaceId,
                panelId: panelId,
                state: index.isMultiple(of: 2) ? .commandRunning : .promptIdle,
                recordedAt: base.addingTimeInterval(offset)
            )
        }

        let state = controller.debugPendingCommandLineStateForTesting(
            workspaceId: workspaceId,
            panelId: panelId
        )
        #expect(state.survivals == nil, "Both survivals must be consumed by the two prompt returns")
        #expect(
            state.pendingAt != nil,
            "The second batch's trailing text is still editable after both transitions"
        )
    }

    @MainActor
    @Test
    func seededPendingClearsOnPromptRedrawWithoutCommand() {
        let wasTracking = AgentHibernationTrackingGate.isEnabled()
        AgentHibernationTrackingGate.setEnabled(true)
        defer { AgentHibernationTrackingGate.setEnabled(wasTracking) }
        let controller = AgentHibernationController.shared
        let workspaceId = UUID()
        let panelId = UUID()
        let base = Date()

        controller.debugSeedPendingCommandLineForTesting(
            workspaceId: workspaceId,
            panelId: panelId,
            recordedAt: base
        )
        // Empty Enter (or ^C) at the prompt: precmd fires with no preexec.
        controller.recordShellActivityTransition(
            workspaceId: workspaceId,
            panelId: panelId,
            state: .promptIdle,
            recordedAt: base.addingTimeInterval(1)
        )

        let state = controller.debugPendingCommandLineStateForTesting(
            workspaceId: workspaceId,
            panelId: panelId
        )
        #expect(
            state.pendingAt == nil,
            "A prompt redraw with no command since the seed proves the line emptied; the shell must requalify"
        )
    }

    @MainActor
    @Test
    func inputBackedPendingSurvivesPromptRedrawWithoutCommand() {
        let wasTracking = AgentHibernationTrackingGate.isEnabled()
        AgentHibernationTrackingGate.setEnabled(true)
        defer { AgentHibernationTrackingGate.setEnabled(wasTracking) }
        let controller = AgentHibernationController.shared
        let workspaceId = UUID()
        let panelId = UUID()
        let base = Date()

        controller.debugSeedPendingCommandLineForTesting(
            workspaceId: workspaceId,
            panelId: panelId,
            recordedAt: base
        )
        // Real typed text replaces the seed: typed-ahead input reappears at
        // the next prompt, so a redraw without a command must not clear it.
        controller.recordTerminalInput(
            workspaceId: workspaceId,
            panelId: panelId,
            recordedAt: base.addingTimeInterval(1),
            armsPendingCommandLine: true,
            pendingPromptSurvivals: 0
        )
        controller.recordShellActivityTransition(
            workspaceId: workspaceId,
            panelId: panelId,
            state: .promptIdle,
            recordedAt: base.addingTimeInterval(2)
        )

        let state = controller.debugPendingCommandLineStateForTesting(
            workspaceId: workspaceId,
            panelId: panelId
        )
        #expect(
            state.pendingAt != nil,
            "Observed input must keep the guard until a command consumes the line"
        )
    }

    // MARK: - Replay-hook installation evidence

    @Test
    func replayHookEvidenceRequiresInstalledIntegration() {
        #expect(TerminalSurface.shellIntegrationInstalledReplayHook(
            shellName: "zsh", managedKeysAdded: ["ZDOTDIR"], shellSpecificCommandApplied: false
        ))
        #expect(!TerminalSurface.shellIntegrationInstalledReplayHook(
            shellName: "zsh", managedKeysAdded: [], shellSpecificCommandApplied: false
        ))
        #expect(TerminalSurface.shellIntegrationInstalledReplayHook(
            shellName: "bash", managedKeysAdded: ["PROMPT_COMMAND"], shellSpecificCommandApplied: false
        ))
        #expect(!TerminalSurface.shellIntegrationInstalledReplayHook(
            shellName: "bash", managedKeysAdded: ["CMUX_LOAD_GHOSTTY_BASH_INTEGRATION"],
            shellSpecificCommandApplied: false
        ))
        #expect(TerminalSurface.shellIntegrationInstalledReplayHook(
            shellName: "fish", managedKeysAdded: [], shellSpecificCommandApplied: true
        ))
        #expect(!TerminalSurface.shellIntegrationInstalledReplayHook(
            shellName: "fish", managedKeysAdded: [], shellSpecificCommandApplied: false
        ))
        #expect(!TerminalSurface.shellIntegrationInstalledReplayHook(
            shellName: "nu", managedKeysAdded: ["ZDOTDIR"], shellSpecificCommandApplied: true
        ))
    }

    @Test
    func unreadableBashBootstrapInstallsNoReplayHook() {
        var environment: [String: String] = [:]
        var protectedKeys: Set<String> = []
        let command = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: "/bin/bash",
            integrationDir: "/nonexistent-cmux-integration",
            userGhosttyShellIntegrationMode: "none",
            to: &environment,
            protectedKeys: &protectedKeys,
            readFile: { _ in throw CocoaError(.fileReadNoSuchFile) }
        )
        #expect(command == nil)
        #expect(!TerminalSurface.shellIntegrationInstalledReplayHook(
            shellName: "bash",
            managedKeysAdded: protectedKeys,
            shellSpecificCommandApplied: false
        ))
    }

    @Test
    func unreadableZshBootstrapInstallsNoReplayHook() {
        var environment: [String: String] = [:]
        var protectedKeys: Set<String> = []
        let command = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: "/bin/zsh",
            integrationDir: "/nonexistent-cmux-integration",
            userGhosttyShellIntegrationMode: "none",
            to: &environment,
            protectedKeys: &protectedKeys
        )
        #expect(command == nil)
        #expect(protectedKeys.isEmpty, "A missing .zshenv must skip the ZDOTDIR redirection entirely")
        #expect(!TerminalSurface.shellIntegrationInstalledReplayHook(
            shellName: "zsh",
            managedKeysAdded: protectedKeys,
            shellSpecificCommandApplied: false
        ))
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
