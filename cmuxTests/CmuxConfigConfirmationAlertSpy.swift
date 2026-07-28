import AppKit

@MainActor
final class CmuxConfigConfirmationAlertSpy: NSAlert {
    private let modalResponse: NSApplication.ModalResponse
    private(set) var didBeginSheet = false
    private(set) var didRunModal = false
    private(set) var sheetCompletion: ((NSApplication.ModalResponse) -> Void)?

    init(modalResponse: NSApplication.ModalResponse = .alertFirstButtonReturn) {
        self.modalResponse = modalResponse
        super.init()
    }

    override func beginSheetModal(
        for sheetWindow: NSWindow,
        completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
    ) {
        didBeginSheet = true
        sheetCompletion = handler
    }

    override func runModal() -> NSApplication.ModalResponse {
        didRunModal = true
        return modalResponse
    }
}
