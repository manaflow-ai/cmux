import AppKit
import Carbon.HIToolbox
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
@Suite("File preview editor TextKit backing", .serialized)
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

    @Test("text preview editor handles standard zoom key equivalents")
    func editorHandlesStandardZoomKeyEquivalents() throws {
        try withDefaultShortcutSettings {
            let textView = SavingTextView.makeFilePreviewTextView()
            let initialPointSize = try #require(textView.font?.pointSize)

            let zoomIn = try #require(Self.keyEvent(characters: "=", keyCode: UInt16(kVK_ANSI_Equal)))
            #expect(textView.performKeyEquivalent(with: zoomIn))
            let zoomedPointSize = try #require(textView.font?.pointSize)
            #expect(zoomedPointSize > initialPointSize)

            let reset = try #require(Self.keyEvent(characters: "0", keyCode: UInt16(kVK_ANSI_0)))
            #expect(textView.performKeyEquivalent(with: reset))
            let resetPointSize = try #require(textView.font?.pointSize)
            #expect(abs(resetPointSize - initialPointSize) < 0.01)

            let zoomOut = try #require(Self.keyEvent(characters: "-", keyCode: UInt16(kVK_ANSI_Minus)))
            #expect(textView.performKeyEquivalent(with: zoomOut))
            let smallerPointSize = try #require(textView.font?.pointSize)
            #expect(smallerPointSize < initialPointSize)
        }
    }

    @Test("text preview zoom in accepts dedicated plus keys")
    func editorZoomInAcceptsDedicatedPlusKeys() throws {
        try withDefaultShortcutSettings {
            let textView = SavingTextView.makeFilePreviewTextView()
            let initialPointSize = try #require(textView.font?.pointSize)
            // kVK_ANSI_RightBracket is the physical key that produces "+" on German/European layouts.
            let event = try #require(Self.keyEvent(characters: "+", keyCode: UInt16(kVK_ANSI_RightBracket)))

            #expect(textView.performKeyEquivalent(with: event))
            let zoomedPointSize = try #require(textView.font?.pointSize)
            #expect(zoomedPointSize > initialPointSize)
        }
    }

    @Test("text preview editor handles chorded zoom key equivalents")
    func editorHandlesChordedZoomKeyEquivalents() throws {
        try withDefaultShortcutSettings {
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(
                    first: ShortcutStroke(
                        key: "k",
                        command: false,
                        shift: false,
                        option: false,
                        control: true,
                        keyCode: UInt16(kVK_ANSI_K)
                    ),
                    second: ShortcutStroke(
                        key: "=",
                        command: true,
                        shift: false,
                        option: false,
                        control: false,
                        keyCode: UInt16(kVK_ANSI_Equal)
                    )
                ),
                for: .browserZoomIn
            )

            let textView = SavingTextView.makeFilePreviewTextView()
            let initialPointSize = try #require(textView.font?.pointSize)

            let prefix = try #require(Self.keyEvent(
                characters: "k",
                modifierFlags: [.control],
                keyCode: UInt16(kVK_ANSI_K)
            ))
            #expect(textView.performKeyEquivalent(with: prefix))
            #expect(abs((textView.font?.pointSize ?? 0) - initialPointSize) < 0.01)

            let suffix = try #require(Self.keyEvent(characters: "=", keyCode: UInt16(kVK_ANSI_Equal)))
            #expect(textView.performKeyEquivalent(with: suffix))
            let zoomedPointSize = try #require(textView.font?.pointSize)
            #expect(zoomedPointSize > initialPointSize)
        }
    }

    @Test("text preview editor allows save and zoom chords to share a prefix")
    func editorAllowsSaveAndZoomChordsToSharePrefix() throws {
        try withDefaultShortcutSettings {
            KeyboardShortcutSettings.setShortcut(
                Self.controlKChord(secondKey: "s", secondKeyCode: UInt16(kVK_ANSI_S)),
                for: .saveFilePreview
            )
            KeyboardShortcutSettings.setShortcut(
                Self.controlKChord(secondKey: "=", secondKeyCode: UInt16(kVK_ANSI_Equal)),
                for: .browserZoomIn
            )

            let panel = TextEditingPanelSpy()
            let textView = SavingTextView.makeFilePreviewTextView()
            textView.panel = panel
            let initialPointSize = try #require(textView.font?.pointSize)

            let zoomPrefix = try #require(Self.keyEvent(
                characters: "k",
                modifierFlags: [.control],
                keyCode: UInt16(kVK_ANSI_K)
            ))
            #expect(textView.performKeyEquivalent(with: zoomPrefix))

            let zoomSuffix = try #require(Self.keyEvent(characters: "=", keyCode: UInt16(kVK_ANSI_Equal)))
            #expect(textView.performKeyEquivalent(with: zoomSuffix))
            let zoomedPointSize = try #require(textView.font?.pointSize)
            #expect(zoomedPointSize > initialPointSize)
            #expect(panel.saveCount == 0)

            let savePrefix = try #require(Self.keyEvent(
                characters: "k",
                modifierFlags: [.control],
                keyCode: UInt16(kVK_ANSI_K)
            ))
            #expect(textView.performKeyEquivalent(with: savePrefix))

            let saveSuffix = try #require(Self.keyEvent(characters: "s", keyCode: UInt16(kVK_ANSI_S)))
            #expect(textView.performKeyEquivalent(with: saveSuffix))
            #expect(panel.saveCount == 1)
        }
    }

    @Test("text preview editor clears pending chord shortcuts when leaving a window")
    func editorClearsPendingShortcutChordsWhenLeavingWindow() throws {
        try withDefaultShortcutSettings {
            let originalAppDelegate = AppDelegate.shared
            AppDelegate.shared = nil
            defer { AppDelegate.shared = originalAppDelegate }

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(
                    first: ShortcutStroke(
                        key: "k",
                        command: false,
                        shift: false,
                        option: false,
                        control: true,
                        keyCode: UInt16(kVK_ANSI_K)
                    ),
                    second: ShortcutStroke(
                        key: "=",
                        command: true,
                        shift: false,
                        option: false,
                        control: false,
                        keyCode: UInt16(kVK_ANSI_Equal)
                    )
                ),
                for: .browserZoomIn
            )

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            let textView = SavingTextView.makeFilePreviewTextView()
            window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
            window.contentView?.addSubview(textView)
            defer { window.orderOut(nil) }

            let initialPointSize = try #require(textView.font?.pointSize)
            let prefix = try #require(Self.keyEvent(
                characters: "k",
                modifierFlags: [.control],
                keyCode: UInt16(kVK_ANSI_K)
            ))
            #expect(textView.performKeyEquivalent(with: prefix))

            textView.removeFromSuperview()

            let suffix = try #require(Self.keyEvent(characters: "=", keyCode: UInt16(kVK_ANSI_Equal)))
            #expect(!textView.performKeyEquivalent(with: suffix))
            #expect(abs((textView.font?.pointSize ?? 0) - initialPointSize) < 0.01)
        }
    }

    @Test("text preview editor honors configured zoom shortcut when clauses")
    func editorHonorsConfiguredZoomShortcutWhenClauses() throws {
        try withShortcutSettingsFile(
            """
            {
              "shortcuts": {
                "when": {
                  "browserZoomIn": "browserFocus"
                }
              }
            }
            """
        ) {
            let textView = SavingTextView.makeFilePreviewTextView()
            let initialPointSize = try #require(textView.font?.pointSize)
            let zoomIn = try #require(Self.keyEvent(characters: "=", keyCode: UInt16(kVK_ANSI_Equal)))

            #expect(!textView.performKeyEquivalent(with: zoomIn))
            #expect(abs((textView.font?.pointSize ?? 0) - initialPointSize) < 0.01)
        }
    }

    private func withDefaultShortcutSettings(_ body: () throws -> Void) rethrows {
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-file-preview-text-zoom"
        )
        KeyboardShortcutSettings.resetAll()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        }
        try body()
    }

    private func withShortcutSettingsFile(_ contents: String, _ body: () throws -> Void) throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let settingsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-preview-text-zoom-\(UUID().uuidString).json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: settingsFileURL)
        }
        try body()
    }

    private static func controlKChord(secondKey: String, secondKeyCode: UInt16) -> StoredShortcut {
        StoredShortcut(
            first: ShortcutStroke(
                key: "k",
                command: false,
                shift: false,
                option: false,
                control: true,
                keyCode: UInt16(kVK_ANSI_K)
            ),
            second: ShortcutStroke(
                key: secondKey,
                command: true,
                shift: false,
                option: false,
                control: false,
                keyCode: secondKeyCode
            )
        )
    }

    private static func keyEvent(
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = [.command],
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private final class TextEditingPanelSpy: FilePreviewTextEditingPanel {
        var textContent = ""
        var saveCount = 0

        func attachTextView(_: NSTextView) {}
        func retryPendingFocus() {}
        func updateTextContent(_ nextContent: String) {
            textContent = nextContent
        }

        func saveTextContent() -> Task<Void, Never>? {
            saveCount += 1
            return nil
        }
    }
}
