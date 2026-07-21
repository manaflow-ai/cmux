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

    @Test
    func appLifecycleFlushIncludesFloatingDockNotes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-floating-lifecycle-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let noteURL = root.appendingPathComponent("note.md")
        try "original".write(to: noteURL, atomically: true, encoding: .utf8)
        let dock = WorkspaceFloatingDock(
            id: UUID(),
            workspaceId: UUID(),
            title: "Lifecycle note",
            frame: CGRect(x: 0, y: 0, width: 520, height: 380),
            isPresented: false,
            noteFilePath: noteURL.path,
            initialContent: .note,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        workspace.floatingDocks.append(dock)
        defer { workspace.teardownAllPanels() }
        let panel = try #require(dock.notePanel)
        await panel.loadTextContent().value
        panel.updateTextContent("flush before termination")

        let appDelegate = AppDelegate()
        appDelegate.tabManager = manager
        #expect(appDelegate.autosavingNotePanelsForLifecycle().contains { $0 === panel })
        let didFlush = await appDelegate.flushPendingAutosavingNotes()
        #expect(didFlush)
        #expect(try String(contentsOf: noteURL, encoding: .utf8) == "flush before termination")
    }

    @Test
    func appLifecycleFlushRevisitsEarlierNoteEditedDuringLaterSave() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-lifecycle-quiescence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.md")
        let secondURL = root.appendingPathComponent("second.md")
        try "first original".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second original".write(to: secondURL, atomically: true, encoding: .utf8)

        let firstSaver = LifecycleNoteSaveProbe()
        let secondSaver = LifecycleNoteSaveGate()
        let firstPanel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: firstURL.path,
            presentation: .note(title: "First"),
            textSaver: { content, url, encoding, _ in
                await firstSaver.save(content: content, url: url, encoding: encoding)
            },
            autosaveDelayNanoseconds: 60_000_000_000
        )
        let secondPanel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: secondURL.path,
            presentation: .note(title: "Second"),
            textSaver: { content, url, encoding, _ in
                await secondSaver.save(content: content, url: url, encoding: encoding)
            },
            autosaveDelayNanoseconds: 60_000_000_000
        )
        defer {
            firstPanel.close()
            secondPanel.close()
        }
        await firstPanel.loadTextContent().value
        await secondPanel.loadTextContent().value

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        workspace.panels[firstPanel.id] = firstPanel
        workspace.panels[secondPanel.id] = secondPanel
        let appDelegate = AppDelegate()
        appDelegate.tabManager = manager

        firstPanel.updateTextContent("first flush")
        secondPanel.updateTextContent("second flush")
        let flushTask = Task { @MainActor in
            await appDelegate.flushPendingAutosavingNotes()
        }
        await secondSaver.waitUntilSaveStarts()
        firstPanel.updateTextContent("first edited while second saves")
        await secondSaver.finishSave()

        #expect(await flushTask.value)
        #expect(await firstSaver.saveCount() == 2)
        #expect(
            try String(contentsOf: firstURL, encoding: .utf8)
                == "first edited while second saves"
        )
    }
}

private actor LifecycleNoteSaveProbe {
    private var saves = 0

    func save(
        content: String,
        url: URL,
        encoding: String.Encoding
    ) -> FilePreviewTextSaver.Result {
        saves += 1
        return FilePreviewTextSaver.saveSynchronously(
            content: content,
            to: url,
            encoding: encoding
        )
    }

    func saveCount() -> Int { saves }
}

private actor LifecycleNoteSaveGate {
    private var saveStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func save(
        content: String,
        url: URL,
        encoding: String.Encoding
    ) async -> FilePreviewTextSaver.Result {
        saveStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
        return FilePreviewTextSaver.saveSynchronously(
            content: content,
            to: url,
            encoding: encoding
        )
    }

    func waitUntilSaveStarts() async {
        if saveStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishSave() {
        finishContinuation?.resume()
        finishContinuation = nil
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
