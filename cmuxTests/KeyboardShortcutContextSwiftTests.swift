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
}
