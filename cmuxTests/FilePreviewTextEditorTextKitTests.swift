import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the note / file-preview editor TextKit hang (issue #5255,
/// same root-cause family as #4576).
///
/// The freeze is an AppKit modal mouse-tracking loop: `NSTextView.mouseDown` ->
/// `_bellerophonTrackMouseWithMouseDownEvent` -> `NSTextSelectionNavigation`
/// `.textSelectionsInteractingAtPoint` (TextKit 2) -> recursive O(N)
/// `synchronizeTextLayoutManagers`, which pegs the main thread at 100% CPU and freezes
/// the whole app. That TextKit 2 selection path is taken whenever the view has a live
/// `textLayoutManager`.
///
/// The previous mitigation only *read* `.layoutManager`, which merely puts the view in
/// TextKit 2 *compatibility* mode — `textLayoutManager` stays non-nil and the slow
/// selection path remains active (proven by live `sample` captures of the hung process).
/// The structural invariant that actually prevents the hang is that the editor must be a
/// **pure TextKit 1** view, i.e. `textLayoutManager == nil`.
///
/// Note: the existing timing test (`testLargeFileSelectionHitTestStaysResponsive`)
/// exercises `characterIndexForInsertion`, which uses the fast `NSLayoutManager` path
/// even in compatibility mode, so it cannot detect a regression back to the TextKit 2
/// selection path. This invariant test can, with no UI or timing dependency.
@MainActor
@Suite("File preview editor TextKit backing")
struct FilePreviewTextEditorTextKitTests {
    @Test("makeFilePreviewTextView is a pure TextKit 1 view (no TextKit 2 selection path)")
    func editorIsPureTextKit1() {
        let textView = SavingTextView.makeFilePreviewTextView()

        // Primary invariant. A TextKit 2 view — or one only dropped to TextKit 2
        // compatibility mode by reading `.layoutManager` — exposes a non-nil
        // `textLayoutManager`, and its selection runs through NSTextSelectionNavigation:
        // the O(N)-per-hit-test main-thread hang. A pure TextKit 1 view has nil here.
        #expect(textView.textLayoutManager == nil)

        // The TextKit 1 stack must be live, with lazy (non-contiguous) glyph layout so
        // multi-hundred-thousand-line documents still open instantly.
        #expect(textView.layoutManager != nil)
        #expect(textView.layoutManager?.allowsNonContiguousLayout == true)
    }

    @Test("search navigation selects the requested loaded line and column")
    func searchNavigationSelectsRequestedLoadedLineAndColumn() async throws {
        let content = """
        first
        second
        abcd needle
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-preview-navigation-\(UUID().uuidString)")
            .appendingPathExtension("swift")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            textLoader: { _ in .loaded(content: content, encoding: .utf8) }
        )
        defer { panel.close() }

        panel.navigateToTextPosition(lineNumber: 3, columnNumber: 6)
        await panel.loadTextContent().value

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = panel.textContent
        panel.attachTextView(textView)

        #expect(textView.selectedRange().location == (content as NSString).range(of: "needle").location)
    }

    @Test("search navigation treats columns as UTF-8 byte offsets")
    func searchNavigationUsesUTF8ByteColumnOffset() async throws {
        let content = "first\n🔍 needle\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-preview-utf8-navigation-\(UUID().uuidString)")
            .appendingPathExtension("swift")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            textLoader: { _ in .loaded(content: content, encoding: .utf8) }
        )
        defer { panel.close() }

        panel.navigateToTextPosition(lineNumber: 2, columnNumber: 6)
        await panel.loadTextContent().value

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = panel.textContent
        panel.attachTextView(textView)

        #expect(textView.selectedRange().location == (content as NSString).range(of: "needle").location)
    }

    @Test("unavailable dirty load clears pending search navigation")
    func unavailableDirtyLoadClearsPendingSearchNavigation() async throws {
        let loader = PreviewTextLoaderStub(result: .loaded(content: "clean\n", encoding: .utf8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-preview-unavailable-navigation-\(UUID().uuidString)")
            .appendingPathExtension("swift")
        try "clean\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            textLoader: loader.load
        )
        defer { panel.close() }

        await panel.loadTextContent().value
        panel.updateTextContent("dirty needle\n")
        #expect(panel.isDirty)

        panel.navigateToTextPosition(lineNumber: 1, columnNumber: 7)
        loader.result = FilePreviewTextLoader.Result.unavailable
        await panel.loadTextContent(replacingDirtyContent: false).value

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = panel.textContent
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        panel.attachTextView(textView)

        #expect(textView.selectedRange().location == 0)
    }

    @Test("loaded dirty buffer clears pending search navigation when content differs")
    func loadedDirtyBufferClearsPendingSearchNavigationWhenContentDiffers() async throws {
        let onDiskContent = "first\nneedle\n"
        let loader = PreviewTextLoaderStub(result: .loaded(content: onDiskContent, encoding: .utf8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-preview-dirty-loaded-navigation-\(UUID().uuidString)")
            .appendingPathExtension("swift")
        try onDiskContent.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            textLoader: loader.load
        )
        defer { panel.close() }

        await panel.loadTextContent().value
        panel.updateTextContent("dirty\nfirst\nneedle\n")
        #expect(panel.isDirty)

        panel.navigateToTextPosition(lineNumber: 2, columnNumber: 1)
        await panel.loadTextContent(replacingDirtyContent: false).value

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = panel.textContent
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        panel.attachTextView(textView)

        #expect(textView.selectedRange().location == 0)
    }
}

private final class PreviewTextLoaderStub: @unchecked Sendable {
    var result: FilePreviewTextLoader.Result

    init(result: FilePreviewTextLoader.Result) {
        self.result = result
    }

    func load(_ url: URL) async -> FilePreviewTextLoader.Result {
        result
    }
}
