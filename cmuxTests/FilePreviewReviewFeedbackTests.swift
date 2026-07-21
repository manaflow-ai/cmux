import AppKit
import Bonsplit
import Carbon.HIToolbox
import Quartz
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FilePreviewReviewFeedbackTests: XCTestCase {
    func testAppBundleExportsFilePreviewDragType() {
        let declarations = (Bundle(for: AppDelegate.self).object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]) ?? []
        let exported = Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })

        XCTAssertTrue(
            exported.contains("com.cmux.filepreview.transfer"),
            "Expected app bundle to export file-preview transfer type, got \(exported)"
        )
    }

    func testSavingTextViewUsesChordedSaveShortcut() async throws {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                first: ShortcutStroke(key: "k", command: true, shift: false, option: false, control: false, keyCode: UInt16(kVK_ANSI_K)),
                second: ShortcutStroke(key: "s", command: true, shift: false, option: false, control: false, keyCode: UInt16(kVK_ANSI_S))
            ),
            for: .saveFilePreview
        )

        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        let textView = SavingTextView()
        textView.string = "saved by chord"
        textView.panel = panel
        panel.attachTextView(textView)
        panel.updateTextContent(textView.string)

        let prefixEvent = try XCTUnwrap(keyEvent(key: "k", keyCode: UInt16(kVK_ANSI_K)))
        let suffixEvent = try XCTUnwrap(keyEvent(key: "s", keyCode: UInt16(kVK_ANSI_S)))

        XCTAssertTrue(textView.performKeyEquivalent(with: prefixEvent))
        XCTAssertFalse(panel.isSaving)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        XCTAssertTrue(textView.performKeyEquivalent(with: suffixEvent))
        await waitForPanelSave(panel)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved by chord")
    }

    func testNoteAutosaveDebouncesRapidEdits() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = FilePreviewAutosaveProbe()
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            presentation: .note(title: "Notes"),
            textSaver: { content, url, _, _ in
                await probe.save(content: content, url: url)
            },
            autosaveDelayNanoseconds: 50_000_000
        )
        defer { panel.close() }
        await panel.loadTextContent().value

        panel.updateTextContent("a")
        panel.updateTextContent("ab")
        panel.updateTextContent("abc")
        try await Task.sleep(nanoseconds: 15_000_000)
        let earlyWriteCount = await probe.writeCount()
        XCTAssertEqual(earlyWriteCount, 0)

        await waitForAutosaveWrite(probe, count: 1)
        let savedContents = await probe.contents()
        XCTAssertEqual(savedContents, ["abc"])
        XCTAssertFalse(panel.isDirty)
    }

    func testNoteAutosaveFailureStaysEditableAndCanRetry() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = FilePreviewAutosaveProbe(result: .failed(fileExists: true))
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            presentation: .note(title: "Notes"),
            textSaver: { content, url, _, _ in
                await probe.save(content: content, url: url)
            },
            autosaveDelayNanoseconds: 1
        )
        defer { panel.close() }
        await panel.loadTextContent().value

        panel.updateTextContent("unsaved edit")
        await waitForAutosaveWrite(probe, count: 1)
        await Task.yield()
        XCTAssertTrue(panel.hasAutosaveError)
        XCTAssertTrue(panel.isDirty)
        XCTAssertFalse(panel.isFileUnavailable)

        await probe.setResult(.saved)
        panel.retryAutosave()
        await waitForAutosaveWrite(probe, count: 2)
        await waitForPanelSave(panel)
        XCTAssertFalse(panel.hasAutosaveError)
        XCTAssertFalse(panel.isDirty)
    }

    func testClosingNoteFlushesPendingDebouncedAutosave() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = FilePreviewAutosaveProbe()
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            presentation: .note(title: "Notes"),
            textSaver: { content, url, _, _ in
                await probe.save(content: content, url: url)
            },
            autosaveDelayNanoseconds: 60_000_000_000
        )
        await panel.loadTextContent().value

        panel.updateTextContent("flush me")
        panel.close()
        await waitForAutosaveWrite(probe, count: 1)

        let savedContents = await probe.contents()
        XCTAssertEqual(savedContents, ["flush me"])
    }

    func testExtensionlessUTF16TextWithBOMResolvesAsTextAfterSniffing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "hello".write(to: url, atomically: true, encoding: .utf16)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    func testExtensionlessANSITextResolvesAsTextAfterSniffing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "\u{001B}[31mred\u{001B}[0m\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    func testTypeScriptFileResolvesAsTextInsteadOfTransportStreamMedia() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        try """
        export const answer: number = 42;
        console.log(answer);
        """.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .text)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    func testUTF8BOMTypeScriptFileResolvesAsText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("export const answer: number = 42;\n".utf8))
        try data.write(to: url, options: .atomic)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .text)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    func testTypeScriptFileWithNULBytesDoesNotResolveAsText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data("export const answer = 42;".utf8)
        data.append(contentsOf: [0x00, 0x00])
        try data.write(to: url, options: .atomic)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .text)
        XCTAssertNotEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    func testTypeScriptTextWinsOverTransportStreamSyncBytePattern() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        let source = "G"
            + String(repeating: "a", count: 187)
            + "G"
            + String(repeating: "b", count: 187)
            + "\nexport const answer: number = 42;\n"
        try source.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .text)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    func testBinaryTransportStreamFileKeepsMediaPreview() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data(repeating: 0, count: 188 * 2)
        data[0] = 0x47
        data[1] = 0x40
        data[2] = 0x00
        data[3] = 0x10
        data[188] = 0x47
        data[189] = 0x41
        data[190] = 0x00
        data[191] = 0x10
        try data.write(to: url, options: .atomic)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .text)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .media)
    }

    func testM2TSTransportStreamFileKeepsMediaPreview() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data(repeating: 0, count: 192 * 2)
        data[4] = 0x47
        data[5] = 0x40
        data[6] = 0x00
        data[7] = 0x10
        data[196] = 0x47
        data[197] = 0x41
        data[198] = 0x00
        data[199] = 0x10
        try data.write(to: url, options: .atomic)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .text)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .media)
    }

    func testQuickLookSessionCloseDoesNotDeactivateMountedRepresentableView() throws {
        let url = try temporaryBinaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        XCTAssertEqual(panel.previewMode, .quickLook)

        let view = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        guard let previewView = view as? QLPreviewView else {
            return XCTFail("Expected Quick Look to vend a QLPreviewView")
        }
        XCTAssertNotNil(previewView.previewItem)

        panel.nativeViewSessions.quickLook.close()

        panel.nativeViewSessions.quickLook.update(
            view,
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        XCTAssertNil(previewView.previewItem)
    }

    func testQuickLookSessionDismantlingRetiredViewDoesNotResetActivePreviewItem() throws {
        let url = try temporaryBinaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        let retiredView = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        guard retiredView is QLPreviewView else {
            return XCTFail("Expected Quick Look to vend a QLPreviewView")
        }

        panel.nativeViewSessions.quickLook.close()

        let activeView = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        guard let activePreviewView = activeView as? QLPreviewView else {
            return XCTFail("Expected Quick Look to vend a QLPreviewView")
        }
        let activeItem = try XCTUnwrap(activePreviewView.previewItem as AnyObject?)

        panel.nativeViewSessions.quickLook.dismantle(retiredView)
        panel.nativeViewSessions.quickLook.update(
            activeView,
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )

        let updatedItem = try XCTUnwrap(activePreviewView.previewItem as AnyObject?)
        XCTAssertTrue(updatedItem === activeItem)
    }

    func testNativeViewSessionDismantlesRetiredViewAfterClose() {
        let view = NSView()
        var closeCount = 0
        var dismantleCount = 0
        let session = PanelOwnedNativeViewSession<NSView>(
            makeView: { view },
            closeView: {
                XCTAssertTrue($0 === view)
                closeCount += 1
            },
            dismantleView: {
                XCTAssertTrue($0 === view)
                dismantleCount += 1
            }
        )

        XCTAssertTrue(session.view(configure: { _ in }) === view)
        session.close()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(dismantleCount, 0)

        XCTAssertFalse(session.dismantle(view))
        XCTAssertEqual(dismantleCount, 1)

        XCTAssertFalse(session.dismantle(view))
        XCTAssertEqual(dismantleCount, 1)
    }

    func testTextLoaderRejectsOversizedTextFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: FilePreviewTextLoader.maximumLoadedTextBytes + 1)
        try handle.close()

        guard case .unavailable = FilePreviewTextLoader.loadSynchronously(url: url) else {
            XCTFail("Expected oversized text file to be unavailable")
            return
        }
    }

    func testTextSaverPreservesSymbolicLinkDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-preview-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("destination.txt")
        let link = root.appendingPathComponent("link.txt")
        try "before".write(to: destination, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)

        guard case .saved = FilePreviewTextSaver.saveSynchronously(
            content: "after",
            to: link,
            encoding: .utf8
        ) else {
            XCTFail("Expected save through symbolic link to succeed")
            return
        }

        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "after")
    }

    func testFocusCoordinatorKeepsPendingFocusUntilEndpointHasWindow() {
        let textView = FilePreviewReviewFocusTestView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let coordinator = FilePreviewFocusCoordinator(preferredIntent: .textEditor)
        coordinator.register(root: textView, primaryResponder: textView, intent: .textEditor)

        XCTAssertFalse(coordinator.focus(.textEditor))

        let window = NSWindow(contentRect: textView.bounds, styleMask: [], backing: .buffered, defer: false)
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = textView
        coordinator.fulfillPendingFocusIfNeeded()

        XCTAssertTrue(window.firstResponder === textView)
    }

    func testFileOpenHonorsExplicitPaneDestinationInsteadOfReusingExistingPreview() throws {
        let originalURL = try temporaryTextFile(contents: "original", encoding: .utf8)
        let placeholderURL = try temporaryTextFile(contents: "placeholder", encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: placeholderURL)
            TerminalController.shared.setActiveTabManager(nil)
        }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        defer { workspace.teardownAllPanels() }
        let firstPane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let existingPanel = try XCTUnwrap(workspace.newFilePreviewSurface(
            inPane: firstPane,
            filePath: originalURL.path,
            focus: false
        ))
        let placeholderPanel = try XCTUnwrap(workspace.splitPaneWithFilePreview(
            targetPane: firstPane,
            orientation: .horizontal,
            insertFirst: false,
            filePath: placeholderURL.path
        ))
        let targetPane = try XCTUnwrap(workspace.paneId(forPanelId: placeholderPanel.id))
        let startingTargetTabs = workspace.bonsplitController.tabs(inPane: targetPane).count
        TerminalController.shared.setActiveTabManager(manager)

        let result = TerminalController.shared.v2FileOpen(params: [
            "paths": [originalURL.path],
            "workspace_id": workspace.id.uuidString,
            "pane_id": targetPane.id.uuidString,
            "focus": false
        ])

        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let openedPanelIdString = payload["surface_id"] as? String,
              let openedPanelId = UUID(uuidString: openedPanelIdString) else {
            XCTFail("Expected file.open to succeed, got \(result)")
            return
        }

        XCTAssertNotEqual(openedPanelId, existingPanel.id)
        XCTAssertEqual(payload["pane_id"] as? String, targetPane.id.uuidString)
        XCTAssertEqual(workspace.paneId(forPanelId: openedPanelId)?.id, targetPane.id)
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: targetPane).count, startingTargetTabs + 1)
    }

    private func temporaryTextFile(contents: String, encoding: String.Encoding) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try contents.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func temporaryBinaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bin")
        try Data([0, 1, 2, 3, 0, 4]).write(to: url, options: .atomic)
        return url
    }

    private func keyEvent(key: String, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    // Regression test for manaflow-ai/cmux#4576: drag-selecting deep into a large file pegged the
    // main thread because TextKit 2's `NSTextSelectionNavigation` hit-tests are O(N) in line
    // fragments. Selection hit-testing near the bottom of a large file must stay responsive.
    func testLargeFileSelectionHitTestStaysResponsive() {
        let lineCount = 60_000
        let text = (0..<lineCount)
            .map { "  \"row_\($0)\": { \"id\": \($0), \"value\": \"item-\($0)-payload\" }," }
            .joined(separator: "\n")

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = text
        // Realize layout so hit-testing measures steady-state cost (as it would after the file is
        // displayed and the user has scrolled), not first-layout cost. Deliberately do NOT touch
        // `layoutManager`/`textLayoutManager` here: that would force a TextKit mode in the test view
        // and the test could no longer detect a production regression back to TextKit 2.
        textView.sizeToFit()

        // Geometry precondition: the hit-tests below must actually land deep in the document. If
        // headless layout left the view collapsed, `bottomY` would sit at the top where even
        // TextKit 2 is cheap, turning this into a silent false negative. Fail loudly instead.
        let documentHeight = textView.bounds.height
        XCTAssertGreaterThan(
            documentHeight,
            100_000,
            "Test precondition failed: a \(lineCount)-line document laid out to only "
                + "\(documentHeight)pt, so hit-tests would not reach the bottom. The timing "
                + "assertion below would be meaningless."
        )

        let bottomY = max(documentHeight - 5, 1)
        let start = ProcessInfo.processInfo.systemUptime
        for offset in 0..<20 {
            _ = textView.characterIndexForInsertion(at: CGPoint(x: 200, y: bottomY - CGFloat(offset)))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        // TextKit 2 takes several seconds here; TextKit 1 + non-contiguous layout takes a few ms.
        // The 1.0s ceiling sits far from both, so it is a clean, non-flaky regression signal.
        XCTAssertLessThan(
            elapsed,
            1.0,
            "Selection hit-testing near the bottom of a \(lineCount)-line file took \(elapsed)s. "
                + "File Preview likely regressed to TextKit 2 O(N) selection navigation (see "
                + "manaflow-ai/cmux#4576)."
        )
    }

    private func waitForPanelSave(
        _ panel: FilePreviewPanel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while panel.isSaving, Date() < deadline {
            await Task.yield()
        }
        if panel.isSaving {
            XCTFail("Timed out waiting for panel save", file: file, line: line)
        }
    }

    private func waitForAutosaveWrite(
        _ probe: FilePreviewAutosaveProbe,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while await probe.writeCount() < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if await probe.writeCount() < count {
            XCTFail("Timed out waiting for autosave write", file: file, line: line)
        }
    }
}

private actor FilePreviewAutosaveProbe {
    private var result: FilePreviewTextSaver.Result
    private var savedContents: [String] = []

    init(result: FilePreviewTextSaver.Result = .saved) {
        self.result = result
    }

    func save(content: String, url: URL) -> FilePreviewTextSaver.Result {
        _ = url
        savedContents.append(content)
        return result
    }

    func setResult(_ result: FilePreviewTextSaver.Result) {
        self.result = result
    }

    func writeCount() -> Int {
        savedContents.count
    }

    func contents() -> [String] {
        savedContents
    }
}

private final class FilePreviewReviewFocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}
