import AppKit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File editor word wrap shortcut", .serialized)
struct FileEditorWordWrapShortcutTests {
    @Test("Option-Z reflows the existing editor without editing its document")
    func optionZReflowsEditor() throws {
        try withSettings {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
            let textView = SavingTextView.makeFilePreviewTextView()
            scrollView.documentView = textView
            textView.string = String(repeating: "wide source line ", count: 80) + "\nsecond line"
            textView.applyFilePreviewWordWrap(false, scrollView: scrollView)
            let storage = try #require(textView.textStorage)
            let selection = NSRange(location: 25, length: 18)
            textView.setSelectedRange(selection)
            let content = textView.string
            let event = try keyEvent("z", characters: "Ω", flags: .option, code: 6)

            #expect(textView.performKeyEquivalent(with: event))
            #expect(FilePreviewWordWrapSettings.isEnabled())
            #expect(textView.textContainer?.widthTracksTextView == true)
            #expect(!scrollView.hasHorizontalScroller)
            #expect(textView.textStorage === storage)
            #expect(textView.string == content)
            #expect(textView.selectedRange() == selection)

            #expect(textView.performKeyEquivalent(with: event))
            #expect(!FilePreviewWordWrapSettings.isEnabled())
            #expect(textView.textContainer?.widthTracksTextView == false)
            #expect(scrollView.hasHorizontalScroller)
            #expect(textView.selectedRange() == selection)
            #expect(textView.string == content)
        }
    }

    @Test("Wrap binding supports customization, chords, unbinding and focus clauses")
    func configuredBinding() throws {
        try withSettings {
            let action = try #require(KeyboardShortcutSettings.Action(rawValue: "toggleFileEditorWordWrap"))
            let textView = SavingTextView.makeFilePreviewTextView()
            let optionZ = try keyEvent("z", characters: "Ω", flags: .option, code: 6)
            KeyboardShortcutSettings.setShortcut(.unbound, for: action)
            #expect(!textView.performKeyEquivalent(with: optionZ))
            #expect(!FilePreviewWordWrapSettings.isEnabled())

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "w", command: true, shift: true, option: false, control: false),
                for: action
            )
            #expect(!textView.performKeyEquivalent(with: optionZ))
            #expect(textView.performKeyEquivalent(with: try keyEvent("w", flags: [.command, .shift], code: 13)))
            #expect(FilePreviewWordWrapSettings.isEnabled())

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "k", command: false, shift: false, option: false, control: true, chordKey: "w"),
                for: action
            )
            #expect(textView.performKeyEquivalent(with: try keyEvent("k", flags: .control, code: 40)))
            #expect(FilePreviewWordWrapSettings.isEnabled())
            #expect(textView.performKeyEquivalent(with: try keyEvent("w", flags: [], code: 13)))
            #expect(!FilePreviewWordWrapSettings.isEnabled())

            let context = action.shortcutContext
            #expect(context.isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: false,
                                       focusedFilePreviewTextEditor: true, rightSidebarFocused: false))
            #expect(!context.isAvailable(focusedBrowserPanel: true, focusedMarkdownPanel: false,
                                        focusedFilePreviewTextEditor: false, rightSidebarFocused: false))
            #expect(!context.isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: false,
                                        focusedFilePreviewTextEditor: false, rightSidebarFocused: false))
            #expect(ShortcutAction(rawValue: action.rawValue)?.defaultFocusWhenClause == action.shortcutContext.defaultWhenClause)
        }
    }

    @Test("Option-Z preserves active input method composition")
    func markedTextOwnsOptionZ() throws {
        try withSettings {
            let textView = SavingTextView.makeFilePreviewTextView()
            textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
            _ = textView.performKeyEquivalent(with: try keyEvent("z", characters: "Ω", flags: .option, code: 6))
            #expect(textView.hasMarkedText())
            #expect(!FilePreviewWordWrapSettings.isEnabled())
        }
    }

    private func keyEvent(_ key: String, characters: String? = nil,
                          flags: NSEvent.ModifierFlags, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: characters ?? key, charactersIgnoringModifiers: key,
                                     isARepeat: false, keyCode: code))
    }

    private func withSettings(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let wrap = defaults.object(forKey: FilePreviewWordWrapSettings.key)
        let store = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cmux-wrap-shortcut")
        let shortcuts = Dictionary(uniqueKeysWithValues: KeyboardShortcutSettings.Action.allCases.compactMap { action in
            defaults.object(forKey: action.defaultsKey).map { (action.defaultsKey, $0) }
        })
        KeyboardShortcutSettings.resetAll()
        defaults.set(false, forKey: FilePreviewWordWrapSettings.key)
        defer {
            KeyboardShortcutSettings.resetAll()
            for (key, value) in shortcuts { defaults.set(value, forKey: key) }
            defaults.set(wrap, forKey: FilePreviewWordWrapSettings.key)
            KeyboardShortcutSettings.settingsFileStore = store
        }
        try body()
    }
}
