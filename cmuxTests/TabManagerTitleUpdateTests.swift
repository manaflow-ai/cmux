import Foundation
import Testing
import CmuxSettings
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TabManagerTitleUpdateTests {
    @Test
    func coalescerReschedulesWhenDelayChangesMidBurst() async {
        let scheduler = ManualCoalescerScheduler()
        let coalescer = NotificationBurstCoalescer(
            delay: 0.02,
            schedule: scheduler.schedule(delay:action:)
        )
        var flushCount = 0

        coalescer.signal {
            flushCount += 1
        }
        #expect(scheduler.delays == [0.02])

        coalescer.signal(delay: 0.25) {
            flushCount += 1
        }
        #expect(scheduler.delays == [0.02, 0.25])

        scheduler.fire(at: 0)
        #expect(flushCount == 0)

        scheduler.fire(at: 1)
        #expect(flushCount == 1)
    }

    @Test
    func titleCoalescingDelayUsesCurrentSettingsAtNotificationTime() async throws {
        let suiteName = "TabManagerTitleCoalescingSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        var notifiedWorkspaceIds: [UUID] = []
        let titleDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .workspaceTitleDidChange,
            object: manager,
            queue: nil
        ) { notification in
            if let workspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID {
                notifiedWorkspaceIds.append(workspaceId)
            }
        }
        defer { NotificationCenter.default.removeObserver(titleDidChangeObserver) }

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(300, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: titleNotificationObject(workspace, focusedPanelId),
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Runtime Delay - grok"
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.3])
        #expect(workspace.panelTitles[focusedPanelId] != "Runtime Delay - grok")
        #expect(workspace.title != "Runtime Delay - grok")
        #expect(notifiedWorkspaceIds.isEmpty)

        scheduler.fire(at: 0)
        #expect(workspace.panelTitles[focusedPanelId] == "Runtime Delay - grok")
        #expect(workspace.title == "Runtime Delay - grok")
        #expect(notifiedWorkspaceIds == [workspace.id])
    }

    @Test
    func titleNotificationIgnoredWhenWorkspaceIsNotOwnedByManager() async throws {
        let suiteName = "TabManagerTitleOwnership.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(100, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let originalPanelTitle = workspace.panelTitles[focusedPanelId]

        #expect(workspace.owningTabManager === manager)
        workspace.owningTabManager = nil
        defer { workspace.owningTabManager = manager }

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: titleNotificationObject(workspace, focusedPanelId),
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Ignored Non Owner - grok"
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays.isEmpty)
        #expect(workspace.panelTitles[focusedPanelId] == originalPanelTitle)
        #expect(workspace.panelTitles[focusedPanelId] != "Ignored Non Owner - grok")
        #expect(workspace.title != "Ignored Non Owner - grok")
    }

    @Test
    func titleNotificationIgnoredAfterDirectWorkspaceModelRemoval() async throws {
        let suiteName = "TabManagerTitleDirectModelRemoval.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(100, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let originalPanelTitle = workspace.panelTitles[focusedPanelId]

        manager.workspaces.tabs = []

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: titleNotificationObject(workspace, focusedPanelId),
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Removed Workspace - grok"
            ]
        )

        await drainMainQueue()
        #expect(manager.tabs.isEmpty)
        #expect(scheduler.delays.isEmpty)
        #expect(workspace.panelTitles[focusedPanelId] == originalPanelTitle)
        #expect(workspace.panelTitles[focusedPanelId] != "Removed Workspace - grok")
    }

    @Test
    func pendingTitleUpdateIgnoredAfterPanelRemoval() async throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let suiteName = "TabManagerTitleRemovedPanel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(500, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let removedPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let remainingPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: true))
        let remainingTitle = try #require(workspace.panelTitles[remainingPanel.id])

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: titleNotificationObject(workspace, removedPanelId),
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: removedPanelId,
                GhosttyNotificationKey.title: "Closed Panel - grok"
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.5])
        workspace.markCloseHistoryEligible(panelId: removedPanelId)
        #expect(workspace.closePanel(removedPanelId, force: true))
        #expect(workspace.panels[removedPanelId] == nil)
        #expect(workspace.panels[remainingPanel.id] != nil)
        #expect(workspace.panelTitles[removedPanelId] == nil)
        let historyItem = try #require(ClosedItemHistoryStore.shared.menuSnapshot().items.first)
        let removed = try #require(ClosedItemHistoryStore.shared.removeRecord(id: historyItem.id)?.record)
        guard case .panel(let entry) = removed.entry else {
            Issue.record("Expected closed panel history entry")
            return
        }
        #expect(entry.snapshot.title == "Closed Panel - grok")
        let workspaceTitleAfterClose = workspace.title

        scheduler.fire(at: 0)

        #expect(workspace.panelTitles[removedPanelId] == nil)
        #expect(workspace.panelTitles[remainingPanel.id] == remainingTitle)
        #expect(workspace.title == workspaceTitleAfterClose)
        #expect(workspace.title != "Closed Panel - grok")
    }

    @Test
    func pendingTitleUpdateFlushesBeforeWorkspaceTransfer() async throws {
        let suiteName = "TabManagerTitleTransfer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(500, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let source = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let destination = TabManager(settings: settings)
        let workspace = try #require(source.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let transferredTitle = "Moved Workspace - grok"

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: titleNotificationObject(workspace, focusedPanelId),
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: transferredTitle
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.5])
        #expect(workspace.panelTitles[focusedPanelId] != transferredTitle)
        #expect(workspace.title != transferredTitle)

        let detached = try #require(source.detachWorkspace(tabId: workspace.id))
        #expect(detached === workspace)
        #expect(workspace.panelTitles[focusedPanelId] == transferredTitle)
        #expect(workspace.title == transferredTitle)

        destination.attachWorkspace(detached, select: true)
        #expect(workspace.owningTabManager === destination)

        scheduler.fire(at: 0)
        #expect(workspace.panelTitles[focusedPanelId] == transferredTitle)
        #expect(workspace.title == transferredTitle)
    }

    @Test
    func pendingTitleUpdateFlushesBeforeSessionSnapshot() async throws {
        let suiteName = "TabManagerTitleSessionSnapshot.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(500, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let snapshotTitle = "Snapshot Title - grok"

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: titleNotificationObject(workspace, focusedPanelId),
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: snapshotTitle
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.5])
        #expect(workspace.panelTitles[focusedPanelId] != snapshotTitle)
        #expect(workspace.title != snapshotTitle)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let workspaceSnapshot = try #require(snapshot.workspaces.first)
        let panelSnapshot = try #require(workspaceSnapshot.panels.first { $0.id == focusedPanelId })

        #expect(workspace.panelTitles[focusedPanelId] == snapshotTitle)
        #expect(workspace.title == snapshotTitle)
        #expect(workspaceSnapshot.processTitle == snapshotTitle)
        #expect(panelSnapshot.title == snapshotTitle)
    }

    @Test
    func pendingTitleUpdateFlushesBeforeClosedWorkspaceHistorySnapshot() async throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let suiteName = "TabManagerTitleClosedHistory.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(500, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        _ = try #require(manager.selectedWorkspace)
        let workspace = manager.addWorkspace(select: true)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let closedTitle = "Closed Workspace Title - grok"

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: titleNotificationObject(workspace, focusedPanelId),
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: closedTitle
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.5])
        #expect(workspace.panelTitles[focusedPanelId] != closedTitle)
        #expect(workspace.title != closedTitle)

        manager.closeWorkspace(workspace)

        let historyItem = try #require(ClosedItemHistoryStore.shared.menuSnapshot().items.first)
        let removed = try #require(ClosedItemHistoryStore.shared.removeRecord(id: historyItem.id)?.record)
        guard case .workspace(let entry) = removed.entry else {
            Issue.record("Expected closed workspace history entry")
            return
        }
        let panelSnapshot = try #require(entry.snapshot.panels.first { $0.id == focusedPanelId })

        #expect(entry.snapshot.processTitle == closedTitle)
        #expect(panelSnapshot.title == closedTitle)
    }

    @Test
    func rawTitleRefreshGateKeepsDefaultBehaviorUntilCoalescingIsEnabled() throws {
        let suiteName = "TabManagerTitleRawRefreshGate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let manager = TabManager(settings: settings)
        let workspace = try #require(manager.selectedWorkspace)

        settings.set(1_000, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        #expect(manager.shouldScheduleRawTitleRefresh(forWorkspaceId: workspace.id))
        #expect(!manager.shouldScheduleRawTitleRefresh(forWorkspaceId: UUID()))

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(!manager.shouldScheduleRawTitleRefresh(forWorkspaceId: workspace.id))

        settings.set(false, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(manager.shouldScheduleRawTitleRefresh(forWorkspaceId: workspace.id))
    }

    @Test
    func titleCoalescingDelayIsDefaultOffAndClampedWhenEnabled() throws {
        let suiteName = "TabManagerTitleCoalescingClamp.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()

        settings.set(1_000, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        #expect(
            abs(
                PanelTitleUpdateCoalescingSettings.delay(settings: settings) -
                    PanelTitleUpdateCoalescingSettings.defaultDelay
            ) < 0.000_1
        )

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(1, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        #expect(abs(PanelTitleUpdateCoalescingSettings.delay(settings: settings) - 0.033) < 0.000_1)

        settings.set(10_000, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        #expect(abs(PanelTitleUpdateCoalescingSettings.delay(settings: settings) - 5.0) < 0.000_1)
    }

    /// Regression for #6291: CLI tools (pnpm, npm, cargo, …) animate a spinner by
    /// rewriting the terminal title on every frame with a leading braille glyph
    /// (`⠋⠙⠹…`). Each raw frame is a distinct string, so without normalization
    /// every frame mutates the workspace title and posts `.workspaceTitleDidChange`,
    /// thrashing the sidebar's main-thread layout until clicks are starved. The
    /// frames should collapse to one stable, spinner-free panel title that mutates
    /// the workspace exactly once.
    @Test
    func spinnerTerminalTitleFramesCollapseToStablePanelTitle() async throws {
        let suiteName = "TabManagerSpinnerTitleCollapse.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)

        var workspaceTitleChangeCount = 0
        let titleDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .workspaceTitleDidChange,
            object: manager,
            queue: nil
        ) { _ in
            workspaceTitleChangeCount += 1
        }
        defer { NotificationCenter.default.removeObserver(titleDidChangeObserver) }

        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        for (index, frame) in spinnerFrames.enumerated() {
            NotificationCenter.default.post(
                name: .ghosttyDidSetTitle,
                object: titleNotificationObject(workspace, focusedPanelId),
                userInfo: [
                    GhosttyNotificationKey.tabId: workspace.id,
                    GhosttyNotificationKey.surfaceId: focusedPanelId,
                    GhosttyNotificationKey.title: "\(frame) pnpm install",
                ]
            )
            await drainMainQueue()
            scheduler.fire(at: index)
            await drainMainQueue()
        }

        #expect(workspace.panelTitles[focusedPanelId] == "pnpm install")
        #expect(workspace.title == "pnpm install")
        #expect(workspaceTitleChangeCount == 1)
    }

    @Test
    func stableTerminalNotificationTitleStripsSpinnerGlyphs() {
        // Leading braille spinner frames of the same logical title collapse to one
        // string — the standalone spinner token is dropped.
        let frames = ["⠋ pnpm install", "⠙ pnpm install", "⠹ pnpm install", "⠸ pnpm install"]
        let normalized = Set(frames.map { TerminalSurface.stableTerminalNotificationTitle($0) })
        #expect(normalized == ["pnpm install"])

        // A standalone spinner token is dropped wherever it appears (leading,
        // embedded, trailing).
        #expect(TerminalSurface.stableTerminalNotificationTitle("Building ⠧ project") == "Building project")
        #expect(TerminalSurface.stableTerminalNotificationTitle("Building  ⠧  project") == "Building  project")
        #expect(TerminalSurface.stableTerminalNotificationTitle("deploying ⣾") == "deploying")
        #expect(
            TerminalSurface.stableTerminalNotificationTitle("⠋ python -c 'print(\"a  b\")'")
                == "python -c 'print(\"a  b\")'"
        )

        // Only *standalone* spinner tokens are removed: a Braille scalar inside a
        // larger word (e.g. a path component) is preserved verbatim, so a real
        // title is never corrupted — even when a leading spinner is also stripped.
        #expect(TerminalSurface.stableTerminalNotificationTitle("~/work/⠋-project") == "~/work/⠋-project")
        #expect(TerminalSurface.stableTerminalNotificationTitle("⠋ ~/work/⠧-proj") == "~/work/⠧-proj")

        // Titles with no spinner glyph take the fast path and are returned
        // byte-for-byte unchanged, double spaces and em dashes included.
        #expect(TerminalSurface.stableTerminalNotificationTitle("~/code/cmux — zsh") == "~/code/cmux — zsh")
        #expect(TerminalSurface.stableTerminalNotificationTitle("a/b-c  d") == "a/b-c  d")
        #expect(TerminalSurface.stableTerminalNotificationTitle("").isEmpty)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func titleNotificationObject(_ workspace: Workspace, _ panelId: UUID) -> Any? {
        workspace.terminalPanel(for: panelId)?.surface
    }

    private final class ManualCoalescerScheduler {
        private struct PendingFlush {
            var isCancelled = false
            let action: @MainActor () -> Void
        }

        private var pendingFlushes: [PendingFlush] = []
        private(set) var delays: [TimeInterval] = []

        @MainActor
        func schedule(
            delay: TimeInterval,
            action: @escaping @MainActor () -> Void
        ) -> NotificationBurstCoalescer.Cancellation {
            let index = pendingFlushes.count
            delays.append(delay)
            pendingFlushes.append(PendingFlush(action: action))
            return { [weak self] in
                self?.pendingFlushes[index].isCancelled = true
            }
        }

        @MainActor
        func fire(at index: Int) {
            guard pendingFlushes.indices.contains(index), !pendingFlushes[index].isCancelled else { return }
            pendingFlushes[index].action()
        }
    }
}
