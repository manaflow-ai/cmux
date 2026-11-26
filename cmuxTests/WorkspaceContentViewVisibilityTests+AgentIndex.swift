import Testing
import AppKit
import Combine
import CmuxNotifications
import CmuxUpdater
import CoreGraphics
import Observation
import SwiftUI
@testable import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension WorkspaceContentViewVisibilityTests {
    /// `SharedLiveAgentIndex` reloads at most every 5 s while agent hooks write
    /// the hook store, and each full reload posts `.sharedLiveAgentIndexDidChange`
    /// without `userInfo`. Every workspace used to answer with
    /// `objectWillChange`, which re-ran `WorkspaceContentView` and every pane's
    /// `updateNSView` and portal reconciliation while the user was idle: the
    /// burst that precedes the 0.65.x idle hangs (issue 22703).
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func testSharedAgentIndexReloadDoesNotReevaluatePaneContent() async throws {
        _ = NSApplication.shared

        let suiteName = "WorkspaceContentViewAgentIndexReloadTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Loading-card workspaces in a controlled project root, as in the tests
        // above, so no shell, git or project-root discovery publishes during
        // the measured window. Await each root rather than counting idle turns.
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let tabManager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        defer { tabManager.finalizeAllWorkspacesForWindowClose() }
        for index in 0..<3 {
            tabManager.addWorkspace(
                workingDirectory: projectRoot.path,
                initialSurface: .cloudVMLoading,
                select: index == 0,
                autoWelcomeIfNeeded: false
            )
        }
        for workspace in tabManager.tabs {
            for await root in workspace.$extensionSidebarProjectRootPath.values {
                if root == projectRoot.path { break }
            }
            try #require(workspace.extensionSidebarProjectRootPath == projectRoot.path)
        }
        let counts = MinimalModeBodyProbeCounts()
        let root = ContentView(updateViewModel: UpdateStateModel(), windowId: UUID())
            .environmentObject(tabManager)
            .environmentObject(TerminalNotificationStore.shared)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState(defaults: defaults))
            .environmentObject(CmuxConfigStore())
            .environment(
                \.minimalModeInvalidationProbe,
                MinimalModeInvalidationProbe(
                    shouldTraceBodyChanges: { counts.isMeasuringInvalidations },
                    contentViewBody: { counts.contentViewBody += 1 },
                    workspaceContentBody: { counts.workspaceContentBody += 1 },
                    verticalTabsSidebarBody: { counts.verticalTabsSidebarBody += 1 }
                )
            )
            .defaultAppStorage(defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = MainWindowHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }

        await Self.drainMainRunLoop(for: window)
        #expect(counts.contentViewBody > 0)
        #expect(counts.workspaceContentBody > 0)
        let settled = await Self.waitForQuietChromeBodies(counts: counts, window: window)
        try #require(settled, "The window must stop re-evaluating chrome bodies while idle")

        counts.reset()
        counts.isMeasuringInvalidations = true
        defer { counts.isMeasuringInvalidations = false }
        var workspacePublishes = 0
        // Observe the real classic Workspace publisher: the regression is an
        // unconditional send without a property mutation. Observation tracking
        // on a mock cannot detect it, including for workspaces not on screen.
        let publishes = tabManager.tabs.map { workspace in
            workspace.objectWillChange.sink { _ in workspacePublishes += 1 }
        }
        defer { publishes.forEach { $0.cancel() } }
        // Post the notification emitted by SharedLiveAgentIndex.startReload. Each
        // workspace's observer handles it before post returns; the drain lets
        // any SwiftUI update it scheduled run before the counts are read.
        try #require(tabManager.tabs.allSatisfy { $0.sharedLiveAgentIndexObserver != nil })
        NotificationCenter.default.post(
            name: .sharedLiveAgentIndexDidChange,
            object: SharedLiveAgentIndex.shared
        )
        await Self.drainMainRunLoop(for: window)
        counts.isMeasuringInvalidations = false

        #expect(
            workspacePublishes == 0,
            "An agent-index reload must not publish any workspace (\(workspacePublishes) publishes)."
        )
        #expect(
            counts.workspaceContentBody == 0,
            "An agent-index reload must not rebuild pane content (\(counts.workspaceContentBody) evaluations)."
        )
        #expect(
            counts.contentViewBody == 0,
            "An agent-index reload must not re-evaluate ContentView (\(counts.contentViewBody) evaluations)."
        )
    }
}
