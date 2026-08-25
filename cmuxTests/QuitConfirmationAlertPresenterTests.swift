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

        // NSAlert starts with a lazy placeholder layout that stacks full-width
        // buttons. The standalone presenter must resolve that layout before the
        // alert becomes visible or the panel renders clipped and washed out.
        let buttonFrames = alert.buttons.map(\.frame)
        #expect(buttonFrames.count == 2)
        #expect(abs(buttonFrames[0].midY - buttonFrames[1].midY) < 0.5)

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
}
