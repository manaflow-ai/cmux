import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite @MainActor struct DiffViewerFinalReviewRegressionTests {
    @Test func loadingOwnershipRejectsSupersededOperation() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: DiffViewerLoadingPage.url,
            renderInitialNavigation: false
        )
        defer { panel.close() }
        let firstOperationID = panel.beginDiffViewerLoadingOperation()
        let secondOperationID = panel.beginDiffViewerLoadingOperation()

        #expect(!panel.isShowingDiffViewerLoadingState(
            expectedURL: DiffViewerLoadingPage.url.absoluteString,
            operationID: firstOperationID
        ))
        #expect(panel.isShowingDiffViewerLoadingState(
            expectedURL: DiffViewerLoadingPage.url.absoluteString,
            operationID: secondOperationID
        ))
    }

    @Test func commandPaletteFingerprintChangesWithKeyboardShortcutRevision() {
        let first = ContentView.commandPaletteCommandsFingerprint(
            snapshotFingerprint: 11,
            configRevision: 22,
            keyboardShortcutRevision: 33
        )
        let second = ContentView.commandPaletteCommandsFingerprint(
            snapshotFingerprint: 11,
            configRevision: 22,
            keyboardShortcutRevision: 34
        )

        #expect(first != second)
    }
}
