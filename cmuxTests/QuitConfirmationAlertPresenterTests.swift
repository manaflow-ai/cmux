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
    func pendingTerminateReplyWaitsOnlyForTerminateOwnedConfirmation() {
        #expect(
            AppDelegate.pendingTerminateReply(
                isAwaitingTerminateKills: true,
                hasActiveQuitConfirmation: false,
                activeQuitConfirmationOwnsTerminateRequest: false
            ) == .terminateLater
        )
        #expect(
            AppDelegate.pendingTerminateReply(
                isAwaitingTerminateKills: false,
                hasActiveQuitConfirmation: true,
                activeQuitConfirmationOwnsTerminateRequest: true
            ) == .terminateLater
        )
        #expect(
            AppDelegate.pendingTerminateReply(
                isAwaitingTerminateKills: false,
                hasActiveQuitConfirmation: true,
                activeQuitConfirmationOwnsTerminateRequest: false
            ) == .terminateCancel
        )
        #expect(
            AppDelegate.pendingTerminateReply(
                isAwaitingTerminateKills: false,
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

        alert.buttons[0].performClick(nil)

        #expect(completedResponse == .alertFirstButtonReturn)
        #expect(completedSuppressionState == .off)
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
