import CmuxCommandPalette
import CmuxSettings
import Testing
@testable import CmuxSettingsUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Keyboard shortcut context")
struct KeyboardShortcutContextSwiftTests {
    @Test("markdown and view zoom contexts do not collide")
    func markdownAndViewZoomContextsDoNotCollide() {
        let markdown = KeyboardShortcutSettings.Action.markdownZoomIn.shortcutContext
        let viewZoom = KeyboardShortcutSettings.Action.browserZoomIn.shortcutContext

        #expect(viewZoom == .browserOrFilePreviewTextEditor)
        #expect(viewZoom.isAvailable(
            focusedBrowserPanel: false,
            focusedMarkdownPanel: false,
            focusedFilePreviewTextEditor: true,
            rightSidebarFocused: false
        ))

        var textPreviewPaletteContext = CommandPaletteContextSnapshot()
        textPreviewPaletteContext.setBool(CommandPaletteContextKeys.panelIsFilePreviewTextEditor, true)
        #expect(viewZoom.isAvailable(commandPaletteContext: textPreviewPaletteContext))
        #expect(!markdown.overlaps(viewZoom))
    }

    @Test("browser or file preview text editor context availability and overlap")
    func browserOrFilePreviewTextEditorContextAvailabilityAndOverlap() {
        let context = KeyboardShortcutSettings.Action.browserZoomIn.shortcutContext

        #expect(context == .browserOrFilePreviewTextEditor)
        #expect(context.isAvailable(
            focusedBrowserPanel: true,
            focusedMarkdownPanel: false,
            focusedFilePreviewTextEditor: false,
            rightSidebarFocused: false
        ))
        #expect(context.isAvailable(
            focusedBrowserPanel: false,
            focusedMarkdownPanel: false,
            focusedFilePreviewTextEditor: true,
            rightSidebarFocused: false
        ))
        #expect(context.isAvailable(
            focusedBrowserPanel: true,
            focusedMarkdownPanel: false,
            focusedFilePreviewTextEditor: true,
            rightSidebarFocused: false
        ))
        #expect(!context.isAvailable(
            focusedBrowserPanel: false,
            focusedMarkdownPanel: false,
            focusedFilePreviewTextEditor: false,
            rightSidebarFocused: false
        ))

        #expect(context.overlaps(KeyboardShortcutSettings.Action.browserReload.shortcutContext))
        #expect(!context.overlaps(KeyboardShortcutSettings.Action.switchRightSidebarToFiles.shortcutContext))
        #expect(context.overlaps(KeyboardShortcutSettings.Action.renameTab.shortcutContext))
    }

    @Test("view zoom context still forwards menu equivalent shortcuts to focused terminal")
    func viewZoomContextStillForwardsMenuEquivalentShortcutsToFocusedTerminal() {
        #expect(KeyboardShortcutSettings.Action.browserReload.shortcutContext.forwardsMenuEquivalentToFocusedTerminal)
        #expect(KeyboardShortcutSettings.Action.browserZoomIn.shortcutContext.forwardsMenuEquivalentToFocusedTerminal)
        #expect(KeyboardShortcutSettings.Action.browserZoomOut.shortcutContext.forwardsMenuEquivalentToFocusedTerminal)
        #expect(KeyboardShortcutSettings.Action.browserZoomReset.shortcutContext.forwardsMenuEquivalentToFocusedTerminal)
        #expect(!KeyboardShortcutSettings.Action.markdownZoomIn.shortcutContext.forwardsMenuEquivalentToFocusedTerminal)
        #expect(!KeyboardShortcutSettings.Action.renameTab.shortcutContext.forwardsMenuEquivalentToFocusedTerminal)
    }

    @MainActor
    @Test("view zoom route prefers text preview before browser fallback")
    func viewZoomRoutePrefersTextPreviewBeforeBrowserFallback() {
        let manager = ZoomRouteRecordingTabManager(browserResult: true, textPreviewResult: true)

        #expect(manager.zoomInFocusedBrowserOrTextFilePreview())
        #expect(manager.calls == ["text"])
    }

    @MainActor
    @Test("view zoom route does not fall back when text preview reports no-op")
    func viewZoomRouteDoesNotFallBackWhenTextPreviewReportsNoOp() {
        let manager = ZoomRouteRecordingTabManager(browserResult: true, textPreviewResult: false)

        #expect(!manager.zoomInFocusedBrowserOrTextFilePreview())
        #expect(manager.calls == ["text"])
    }

    @MainActor
    @Test("view zoom route falls back to browser when no text preview target exists")
    func viewZoomRouteFallsBackToBrowserWhenNoTextPreviewTargetExists() {
        let manager = ZoomRouteRecordingTabManager(browserResult: true, textPreviewResult: nil)

        #expect(manager.zoomInFocusedBrowserOrTextFilePreview())
        #expect(manager.calls == ["browser"])
    }

    @MainActor
    @Test("view zoom route propagates unhandled browser result when text preview target is absent")
    func viewZoomRoutePropagatesUnhandledBrowserResultWhenTextPreviewTargetIsAbsent() {
        let manager = ZoomRouteRecordingTabManager(browserResult: false, textPreviewResult: nil)

        #expect(!manager.zoomInFocusedBrowserOrTextFilePreview())
        #expect(!manager.zoomOutFocusedBrowserOrTextFilePreview())
        #expect(!manager.resetZoomFocusedBrowserOrTextFilePreview())
        #expect(manager.calls == [
            "browser",
            "browser",
            "browser",
        ])
    }

    @MainActor
    @Test("view zoom route uses text preview target for every zoom action")
    func viewZoomRouteUsesTextPreviewTargetForEveryZoomAction() {
        let manager = ZoomRouteRecordingTabManager(browserResult: true, textPreviewResult: false)

        #expect(!manager.zoomOutFocusedBrowserOrTextFilePreview())
        #expect(!manager.resetZoomFocusedBrowserOrTextFilePreview())
        #expect(manager.calls == ["text", "text"])
    }
}

private final class ZoomRouteRecordingTabManager: TabManager {
    private let browserResult: Bool?
    private let textPreviewResult: Bool?
    var calls: [String] = []

    init(browserResult: Bool?, textPreviewResult: Bool?) {
        self.browserResult = browserResult
        self.textPreviewResult = textPreviewResult
        super.init(autoWelcomeIfNeeded: false)
    }

    override func performFocusedBrowserZoom(_ action: (BrowserPanel) -> Bool) -> Bool? {
        guard let browserResult else { return nil }
        calls.append("browser")
        return browserResult
    }

    override func performFocusedTextFilePreviewZoom(_ action: (FilePreviewPanel) -> Bool) -> Bool? {
        guard let textPreviewResult else { return nil }
        calls.append("text")
        return textPreviewResult
    }
}
