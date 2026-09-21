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
    /// Checks that Option-Z changes layout without replacing storage or the selection.
    func optionZReflowsEditor() throws {
        try withSettings { settings in
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
            let textView = SavingTextView.makeFilePreviewTextView(wordWrapSettings: settings)
            scrollView.documentView = textView
            textView.string = String(repeating: "wide source line ", count: 80) + "\nsecond line"
            textView.applyFilePreviewWordWrap(false, scrollView: scrollView)
            let storage = try #require(textView.textStorage)
            let selection = NSRange(location: 25, length: 18)
            textView.setSelectedRange(selection)
            let content = textView.string
            let event = try keyEvent("z", characters: "Ω", flags: .option, code: 6)

            #expect(textView.performKeyEquivalent(with: event))
            #expect(settings.isEnabled())
            #expect(textView.textContainer?.widthTracksTextView == true)
            #expect(!scrollView.hasHorizontalScroller)
            #expect(textView.textStorage === storage)
            #expect(textView.string == content)
            #expect(textView.selectedRange() == selection)

            #expect(textView.performKeyEquivalent(with: event))
            #expect(!settings.isEnabled())
            #expect(textView.textContainer?.widthTracksTextView == false)
            #expect(scrollView.hasHorizontalScroller)
            #expect(textView.selectedRange() == selection)
            #expect(textView.string == content)
        }
    }

    @Test("Wrap binding supports customization, chords, unbinding and focus clauses")
    /// Exercises rebinding, unbinding, chords, and the built-in editor-only scope.
    func configuredBinding() throws {
        try withSettings { settings in
            let action = try #require(KeyboardShortcutSettings.Action(rawValue: "toggleFileEditorWordWrap"))
            let textView = SavingTextView.makeFilePreviewTextView(wordWrapSettings: settings)
            let optionZ = try keyEvent("z", characters: "Ω", flags: .option, code: 6)
            KeyboardShortcutSettings.setShortcut(.unbound, for: action)
            #expect(!textView.performKeyEquivalent(with: optionZ))
            #expect(!settings.isEnabled())

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "w", command: true, shift: true, option: false, control: false),
                for: action
            )
            #expect(!textView.performKeyEquivalent(with: optionZ))
            #expect(textView.performKeyEquivalent(with: try keyEvent("w", flags: [.command, .shift], code: 13)))
            #expect(settings.isEnabled())

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "k", command: false, shift: false, option: false, control: true, chordKey: "w"),
                for: action
            )
            #expect(textView.performKeyEquivalent(with: try keyEvent("k", flags: .control, code: 40)))
            #expect(settings.isEnabled())
            #expect(textView.performKeyEquivalent(with: try keyEvent("w", flags: [], code: 13)))
            #expect(!settings.isEnabled())

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

    @Test("cmux.json bindings and when clauses gate the editor command")
    /// Verifies that a configured when clause can decline the editor shortcut.
    func fileConfiguredWhenClause() throws {
        try withSettings { settings in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("wrap-shortcut-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try """
            {"shortcuts":{"bindings":{"toggleFileEditorWordWrap":"opt+z"},
              "when":{"toggleFileEditorWordWrap":"browserFocus"}}}
            """.write(to: url, atomically: true, encoding: .utf8)
            KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
                primaryPath: url.path, fallbackPath: nil, additionalFallbackPaths: [], startWatching: false
            )
            let editor = SavingTextView.makeFilePreviewTextView(wordWrapSettings: settings)
            #expect(!editor.performKeyEquivalent(with: try keyEvent("z", characters: "Ω", flags: .option, code: 6)))
            #expect(!settings.isEnabled())
        }
    }

    @Test("Option-Z preserves active input method composition")
    /// Keeps active input-method composition in control of Option-modified input.
    func markedTextOwnsOptionZ() throws {
        try withSettings { settings in
            let textView = SavingTextView.makeFilePreviewTextView(wordWrapSettings: settings)
            textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
            _ = textView.performKeyEquivalent(with: try keyEvent("z", characters: "Ω", flags: .option, code: 6))
            #expect(textView.hasMarkedText())
            #expect(!settings.isEnabled())
        }
    }

    @Test("Reflow, resize and document replacement preserve editing state")
    /// Exercises reflow and resizing with an edited document, selection, and scroll offset.
    func reflowPreservesUndoAndViewport() throws {
        try withSettings { settings in
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
            let window = NSWindow(contentRect: scrollView.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = scrollView
            let textView = SavingTextView.makeFilePreviewTextView(wordWrapSettings: settings)
            scrollView.documentView = textView
            let original = String(repeating: "short line\n", count: 100) + String(repeating: "wide source ", count: 80)
            textView.string = original
            textView.applyFilePreviewWordWrap(false, scrollView: scrollView)
            window.makeFirstResponder(textView)
            textView.insertText("edit", replacementRange: NSRange(location: 0, length: 0))
            textView.breakUndoCoalescing()
            let undo = try #require(textView.undoManager)
            #expect(undo.canUndo)
            let selection = NSRange(location: 100, length: 8)
            textView.setSelectedRange(selection, affinity: .upstream, stillSelecting: false)
            let layout = try #require(textView.layoutManager)
            let container = try #require(textView.textContainer)
            layout.ensureLayout(for: container)
            textView.sizeToFit()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
            let origin = scrollView.contentView.bounds.origin

            #expect(textView.toggleFilePreviewWordWrap())
            layout.ensureLayout(for: container)
            #expect(textView.selectedRange() == selection)
            #expect(textView.selectionAffinity == .upstream)
            #expect(scrollView.contentView.bounds.origin == origin)
            #expect(undo.canUndo)
            #expect(layout.usedRect(for: container).maxX <= container.size.width + 1)

            scrollView.setFrameSize(NSSize(width: 260, height: 240))
            textView.applyFilePreviewWordWrap(true, scrollView: scrollView)
            layout.ensureLayout(for: container)
            #expect(container.size.width <= scrollView.contentSize.width)
            #expect(layout.usedRect(for: container).maxX <= container.size.width + 1)
            #expect(textView.selectedRange() == selection)
            #expect(textView.toggleFilePreviewWordWrap())
            #expect(scrollView.hasHorizontalScroller)
            undo.undo()
            #expect(textView.string == original)

            // Switching files keeps the same wrapping preference without clipping.
            textView.string = String(repeating: "another file ", count: 100)
            textView.applyFilePreviewWordWrap(true, scrollView: scrollView)
            layout.ensureLayout(for: container)
            #expect(layout.usedRect(for: container).maxX <= container.size.width + 1)
            #expect(!scrollView.hasHorizontalScroller)
        }
    }

    @Test("The app dispatcher handles Option-Z only for the actual editor responder")
    /// Routes a real window event through the app dispatcher and verifies focus gating.
    func appShortcutRouting() throws {
        try withSettings { settings in
            let delegate = try #require(AppDelegate.shared)
            let windowID = delegate.createMainWindow()
            let window = try #require(delegate.mainWindow(for: windowID))
            defer { window.close() }
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
            let textView = SavingTextView.makeFilePreviewTextView(wordWrapSettings: settings)
            scrollView.documentView = textView
            window.contentView?.addSubview(scrollView)
            #expect(window.makeFirstResponder(textView))
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .option,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "Ω", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
            ))
            #expect(delegate.handleConfiguredShortcutKeyEquivalent(event))
            #expect(settings.isEnabled())
            #expect(textView.string.isEmpty)
            #expect(window.makeFirstResponder(nil))
            #expect(!delegate.handleConfiguredShortcutKeyEquivalent(event))
            #expect(settings.isEnabled())
        }
    }

    @Test("Palette and editor use the same persisted word-wrap setting")
    /// Verifies that palette and editor actions agree on the same preference value.
    func paletteUsesSharedPreference() throws {
        let suite = "cmux-wrap-palette-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FilePreviewWordWrapSettings(defaults: defaults)
        let editor = SavingTextView.makeFilePreviewTextView(wordWrapSettings: settings)
        let descriptor = try #require(CommandPaletteSettingsToggleCommands.descriptor(
            commandId: "palette.toggleSetting.fileEditorWordWrap"
        ))
        descriptor.toggle(defaults: defaults)
        #expect(settings.isEnabled())
        #expect(editor.toggleFilePreviewWordWrap())
        #expect(!descriptor.isOn(defaults))
    }

    /// Constructs the key event delivered to the production shortcut matcher.
    private func keyEvent(_ key: String, characters: String? = nil,
                          flags: NSEvent.ModifierFlags, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: characters ?? key, charactersIgnoringModifiers: key,
                                     isARepeat: false, keyCode: code))
    }

    /// Isolates word-wrap persistence and restores the global shortcut test fixture.
    private func withSettings(_ body: (FilePreviewWordWrapSettings) throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let suite = "cmux-word-wrap-\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suite)!
        let settings = FilePreviewWordWrapSettings(defaults: isolatedDefaults)
        defer { isolatedDefaults.removePersistentDomain(forName: suite) }
        let store = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cmux-wrap-shortcut")
        let shortcuts = Dictionary(uniqueKeysWithValues: KeyboardShortcutSettings.Action.allCases.compactMap { action in
            defaults.object(forKey: action.defaultsKey).map { (action.defaultsKey, $0) }
        })
        KeyboardShortcutSettings.resetAll()
        settings.setEnabled(false)
        defer {
            KeyboardShortcutSettings.resetAll()
            for (key, value) in shortcuts { defaults.set(value, forKey: key) }
            KeyboardShortcutSettings.settingsFileStore = store
        }
        try body(settings)
    }
}
