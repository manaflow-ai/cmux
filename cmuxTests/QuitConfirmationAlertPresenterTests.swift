import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct QuitConfirmationAlertPresenterTests {
    @Test
    func freshSnapshotDeadlineTerminatesWithCachedIndexesAfterOwnedCleanup() {
        #expect(
            AppDelegate.terminateCleanupDeadlineDisposition(
                phase: .freshSnapshot,
                hasOwnedRuntimeCleanup: true
            ) == .persistCachedSnapshotAndTerminate
        )
        #expect(
            AppDelegate.terminateCleanupDeadlineDisposition(
                phase: .ownedRuntimeCleanup,
                hasOwnedRuntimeCleanup: true
            ) == .cancelTerminationAfterRuntimeCleanupFailure
        )
        #expect(
            AppDelegate.terminateCleanupDeadlineDisposition(
                phase: .ownedRuntimeCleanup,
                hasOwnedRuntimeCleanup: false
            ) == .persistCachedSnapshotAndTerminate
        )
    }

    @Test
    func pendingTerminateReplyWaitsForOwnedCleanupOrTerminateOwnedConfirmation() {
        #expect(
            AppDelegate.pendingTerminateReply(
                isAwaitingTerminateCleanup: true,
                hasActiveQuitConfirmation: false,
                activeQuitConfirmationOwnsTerminateRequest: false
            ) == .terminateLater
        )
        #expect(
            AppDelegate.pendingTerminateReply(
                isAwaitingTerminateCleanup: false,
                hasActiveQuitConfirmation: true,
                activeQuitConfirmationOwnsTerminateRequest: true
            ) == .terminateLater
        )
        #expect(
            AppDelegate.pendingTerminateReply(
                isAwaitingTerminateCleanup: false,
                hasActiveQuitConfirmation: true,
                activeQuitConfirmationOwnsTerminateRequest: false
            ) == .terminateCancel
        )
        #expect(
            AppDelegate.pendingTerminateReply(
                isAwaitingTerminateCleanup: false,
                hasActiveQuitConfirmation: false,
                activeQuitConfirmationOwnsTerminateRequest: false
            ) == nil
        )
    }

    @Test("Quit confirmation includes dirty windowless recoverable route owners")
    func quitConfirmationIncludesDirtyWindowlessRecoverableRouteOwners() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let activeManager = TabManager(autoWelcomeIfNeeded: false)
            let recoverableManager = TabManager()
            let recoverableWorkspace = try #require(recoverableManager.selectedWorkspace)
            let recoverablePanel = try #require(recoverableWorkspace.focusedTerminalPanel)
            let windowId = UUID()

            AppDelegate.shared = appDelegate
            appDelegate.tabManager = activeManager
            TerminalController.shared.setActiveTabManager(activeManager)
            recoverablePanel.surface.setNeedsConfirmCloseOverrideForTesting(true)
            appDelegate.rememberRecoverableMainWindowRoute(
                windowId: windowId,
                tabManager: recoverableManager,
                window: nil,
                sidebarSnapshot: SessionSidebarSnapshot(
                    isVisible: false,
                    selection: .tabs,
                    width: 280
                )
            )
            defer {
                recoverablePanel.surface.setNeedsConfirmCloseOverrideForTesting(nil)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                if !recoverableManager.isFinalizedForWindowClose {
                    recoverableManager.finalizeAllWorkspacesForWindowClose()
                }
                if !activeManager.isFinalizedForWindowClose {
                    activeManager.finalizeAllWorkspacesForWindowClose()
                }
                TerminalController.shared.setActiveTabManager(previousActiveManager)
                AppDelegate.shared = previousAppDelegate
            }

            #expect(appDelegate.recoverableMainWindowRoutes().isEmpty)
            #expect(
                appDelegate.mainWindowSessionPersistenceRoutes().contains {
                    $0.windowId == windowId && $0.tabManager === recoverableManager
                }
            )
            #expect(appDelegate.hasQuitConfirmationDirtyWorkspaces())
        }
    }

    @Test
    func presenterUsesSheetCompletionWithoutRunningNestedModalLoop() {
        let alert = QuitConfirmationAlertSpy()
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        var completedResponse: NSApplication.ModalResponse?
        var completedSuppressionState: NSControl.StateValue?
        let presenter = QuitConfirmationAlertPresenter(
            alert: alert,
            presentingWindowProvider: { hostWindow }
        ) { response, suppressionState in
            completedResponse = response
            completedSuppressionState = suppressionState
        }

        presenter.present()

        #expect(alert.didBeginSheetModal)
        #expect(!alert.didRunModal)
        #expect(completedResponse == nil)

        alert.capturedSheetCompletion?(.alertFirstButtonReturn)

        #expect(completedResponse == .alertFirstButtonReturn)
        #expect(completedSuppressionState == .off)
    }

    @Test
    func presenterUsesStandaloneCompletionWithoutRunningNestedModalLoop() {
        let alert = QuitConfirmationAlertSpy()

        var completedResponse: NSApplication.ModalResponse?
        var completedSuppressionState: NSControl.StateValue?
        let presenter = QuitConfirmationAlertPresenter(
            alert: alert,
            presentingWindowProvider: { nil }
        ) { response, suppressionState in
            completedResponse = response
            completedSuppressionState = suppressionState
        }

        presenter.present()
        defer {
            alert.window.orderOut(nil)
            alert.window.close()
        }

        #expect(!alert.didBeginSheetModal)
        #expect(!alert.didRunModal)
        #expect(completedResponse == nil)

        // NSAlert's button arrangement is platform-dependent (some macOS
        // releases stack the buttons vertically). The contract is that the
        // presenter resolves the lazy layout while the window is still hidden
        // and leaves two usable, non-overlapping controls.
        alert.window.displayIfNeeded()
        alert.window.contentView?.layoutSubtreeIfNeeded()
        // Compare alignment rects, not raw frames: where NSAlert stacks the
        // buttons, each bezel button's frame carries transparent padding
        // outside its visible control (e.g. frame (-6,-6,240,40) around a
        // 228x28 control), so adjacent frames legitimately overlap in that
        // padding while the controls themselves stay separated.
        let buttonFrames = alert.buttons.map { $0.alignmentRect(forFrame: $0.frame) }
        #expect(buttonFrames.count == 2)
        #expect(alert.didLayoutWhileHidden)
        #expect(buttonFrames.allSatisfy { $0.width > 0 && $0.height > 0 })
        #expect(!buttonFrames[0].intersects(buttonFrames[1]))

        alert.buttons[0].performClick(nil)

        #expect(completedResponse == .alertFirstButtonReturn)
        #expect(completedSuppressionState == .off)
    }

    @Test
    func joinedCancellationActionRunsOnlyAfterCancel() {
        let alert = QuitConfirmationAlertSpy()
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        var cancellationCount = 0
        let presenter = QuitConfirmationAlertPresenter(
            alert: alert,
            presentingWindowProvider: { hostWindow }
        ) { _, _ in }

        presenter.present()
        presenter.joinCancellationAction {
            cancellationCount += 1
        }

        #expect(cancellationCount == 0)
        alert.capturedSheetCompletion?(.alertSecondButtonReturn)
        #expect(cancellationCount == 1)
    }

    @Test
    func joinedCancellationActionDoesNotRunAfterQuit() {
        let alert = QuitConfirmationAlertSpy()
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        var cancellationCount = 0
        let presenter = QuitConfirmationAlertPresenter(
            alert: alert,
            presentingWindowProvider: { hostWindow }
        ) { _, _ in }

        presenter.present()
        presenter.joinCancellationAction {
            cancellationCount += 1
        }

        alert.capturedSheetCompletion?(.alertFirstButtonReturn)
        #expect(cancellationCount == 0)
    }
}

private final class QuitConfirmationAlertSpy: NSAlert {
    var didBeginSheetModal = false
    var didRunModal = false
    var capturedSheetCompletion: ((NSApplication.ModalResponse) -> Void)?
    private(set) var didLayoutWhileHidden = false

    override init() {
        super.init()
        addButton(withTitle: "Quit")
        addButton(withTitle: "Cancel")
        showsSuppressionButton = true
    }

    override func beginSheetModal(
        for sheetWindow: NSWindow,
        completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        didBeginSheetModal = true
        capturedSheetCompletion = handler
    }

    override func runModal() -> NSApplication.ModalResponse {
        didRunModal = true
        return .alertSecondButtonReturn
    }

    override func layout() {
        if !window.isVisible {
            didLayoutWhileHidden = true
        }
        super.layout()
    }
}
