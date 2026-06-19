import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CommandPaletteTextFieldSelectionTests: XCTestCase {
    func testCommandPaletteNativeTextFieldPerformsCommandShiftHorizontalSelection() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withVisibleCommandPaletteOverlay(appDelegate: appDelegate) { window, overlayContainer in
            let field = ContentView.CommandPaletteNativeTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            field.stringValue = "abcdef"
            field.isEditable = true
            field.isSelectable = true
            overlayContainer.addSubview(field)
            defer { field.removeFromSuperview() }

            XCTAssertTrue(window.makeFirstResponder(field))
            guard let editor = field.currentEditor() as? NSTextView else {
                XCTFail("Expected command palette field editor")
                return
            }

            guard let leftArrowEvent = makeKeyDownEvent(
                key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                modifiers: [.command, .shift],
                keyCode: 123,
                windowNumber: window.windowNumber
            ),
            let rightArrowEvent = makeKeyDownEvent(
                key: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                modifiers: [.command, .shift],
                keyCode: 124,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct command-shift horizontal arrow events")
                return
            }

            assertSelectsAll(editor: editor) {
                XCTAssertTrue(field.performKeyEquivalent(with: leftArrowEvent))
            }
            assertSelectsAll(editor: editor, fromStart: true) {
                XCTAssertTrue(field.performKeyEquivalent(with: rightArrowEvent))
            }
            assertSelectsAll(editor: editor) {
                field.keyDown(with: leftArrowEvent)
            }
            assertSelectsAll(editor: editor, fromStart: true) {
                field.keyDown(with: rightArrowEvent)
            }
            assertSelectsAll(editor: editor) {
                editor.keyDown(with: leftArrowEvent)
            }
            assertSelectsAll(editor: editor, fromStart: true) {
                editor.keyDown(with: rightArrowEvent)
            }
        }
    }

    private func assertSelectsAll(
        editor: NSTextView,
        fromStart: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line,
        action: () -> Void
    ) {
        let fullLength = editor.string.utf16.count
        editor.setSelectedRange(NSRange(location: fromStart ? 0 : fullLength, length: 0))
        action()
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: fullLength), file: file, line: line)
    }

    private func withVisibleCommandPaletteOverlay(
        appDelegate: AppDelegate,
        _ body: (NSWindow, NSView) -> Void
    ) {
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView else {
            XCTFail("Expected test window")
            return
        }

        let overlayContainer = NSView(frame: contentView.bounds)
        overlayContainer.identifier = commandPaletteOverlayContainerIdentifier
        overlayContainer.alphaValue = 1
        overlayContainer.isHidden = false
        contentView.addSubview(overlayContainer)

        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
            overlayContainer.removeFromSuperview()
        }

        body(window, overlayContainer)
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.performClose(nil)
    }
}
