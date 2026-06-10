import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
let appDelegateLastSurfaceCloseShortcutDefaultsKey = "closeWorkspaceOnLastSurfaceShortcut"
final class FakeWKInspectorContainerView: NSView {}
final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
final class FakeTextBoxSubmitSurface: TextBoxSubmitSurfaceControlling {
    var clipboardReadGeneration = 0
    var textBoxSubmitObservationWindow: NSWindow?
    var textBoxSubmitTerminalSurface: TerminalSurface? { nil }
    var visibleTextValue: String?
    var sendKeyTextResult = true
    var sendTextResult = true
    var sendNamedKeyResult: TerminalSurface.NamedKeySendResult = .sent
    var performBindingActionResult = true
    private(set) var sentText: [String] = []
    private(set) var sentKeys: [String] = []

    func visibleText() -> String? {
        visibleTextValue
    }

    @discardableResult
    func sendKeyText(_ text: String) -> Bool {
        sentText.append(text)
        return sendKeyTextResult
    }

    @discardableResult
    func sendText(_ text: String) -> Bool {
        sentText.append(text)
        return sendTextResult
    }

    @discardableResult
    func sendNamedKey(_ keyName: String) -> TerminalSurface.NamedKeySendResult {
        sentKeys.append(keyName)
        return sendNamedKeyResult
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        sentKeys.append(action)
        return performBindingActionResult
    }

    func completeClipboardRead() {
        clipboardReadGeneration += 1
        NotificationCenter.default.post(
            name: .terminalSurfaceDidCompleteClipboardRead,
            object: self
        )
    }
}
final class MenuActionProbe: NSObject {
    var callCount = 0
    @objc func perform(_ sender: Any?) {
        callCount += 1
    }
}
final class GhosttyCommandEquivalentProbeView: GhosttyNSView {
    var afterMenuMissCallCount = 0
    var keyDownCallCount = 0
    var lastKeyDownCharactersIgnoringModifiers: String?
    var pasteCallCount = 0
    var pasteAsPlainTextCallCount = 0
    var performAfterMenuMissResult = true

    override func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
        afterMenuMissCallCount += 1
        return performAfterMenuMissResult
    }

    override func keyDown(with event: NSEvent) {
        keyDownCallCount += 1
        lastKeyDownCharactersIgnoringModifiers = event.charactersIgnoringModifiers
    }

    override func paste(_ sender: Any?) {
        pasteCallCount += 1
    }

    override func pasteAsPlainText(_ sender: Any?) {
        pasteAsPlainTextCallCount += 1
    }
}

@MainActor
final class AppDelegateShortcutRoutingTests: XCTestCase {
    static var retainedTextBoxUndoWindows: [NSWindow] = []
    static var retainedTextBoxRenderScrollViews: [NSScrollView] = []
    private static var retainedTextBoxRestoreViews: [TextBoxInputTextView] = []
    private var savedShortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var actionsWithPersistedShortcut: Set<KeyboardShortcutSettings.Action> = []
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

    func makeKeyEvent(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }

    override func setUp() {
        super.setUp()
        // Prevent a single hanging test from consuming the entire CI timeout budget.
        executionTimeAllowance = 30
        #if DEBUG
        KeyboardShortcutRecorderActivity.resetForTesting()
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
        actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cmux-shortcut-routing")
        KeyboardShortcutSettings.resetAll()
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
    }

    override func tearDown() {
        #if DEBUG
        KeyboardShortcutRecorderActivity.resetForTesting()
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        KeyboardShortcutSettings.shortcutLookupObserver = nil
        TextBoxSubmit.debugResetForTesting()
        #endif
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        AppDelegate.shared?.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        AppDelegate.shared?.debugCloseMainWindowConfirmationHandler = nil
        AppDelegate.shared?.debugCreateMainWindowSourceIsNativeFullScreenOverride = nil
        if AppDelegate.shared?.dismissNotificationsPopoverIfShown() == true {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        for action in KeyboardShortcutSettings.Action.allCases {
            if actionsWithPersistedShortcut.contains(action),
               let savedShortcut = savedShortcutsByAction[action] {
                KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
        for window in Self.retainedTextBoxUndoWindows {
            window.orderOut(nil)
            window.close()
        }
        Self.retainedTextBoxUndoWindows.removeAll()
        Self.retainedTextBoxRenderScrollViews.removeAll()
        Self.retainedTextBoxRestoreViews.removeAll()
        super.tearDown()
    }

    func makeRegisteredShortcutRoutingWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    func closeRegisteredShortcutRoutingWindow(_ window: NSWindow, id: UUID) {
        AppDelegate.shared?.unregisterMainWindowContextForTesting(windowId: id)
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> NSEvent? {
        makeKeyEvent(
            type: .keyDown,
            key: key,
            modifiers: modifiers,
            keyCode: keyCode,
            windowNumber: windowNumber,
            isARepeat: isARepeat,
            timestamp: timestamp
        )
    }

    func makeKeyDownEvent(
        shortcut: StoredShortcut,
        windowNumber: Int
    ) -> NSEvent? {
        guard !shortcut.isUnbound,
              !shortcut.hasChord,
              let keyCode = shortcut.firstStroke.resolvedKeyCode() else {
            return nil
        }
        return makeKeyDownEvent(
            key: shortcut.menuItemKeyEquivalent ?? shortcut.key,
            modifiers: shortcut.modifierFlags,
            keyCode: keyCode,
            windowNumber: windowNumber
        )
    }

    func makeKeyEvent(
        type: NSEvent.EventType,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: isARepeat,
            keyCode: keyCode
        )
    }

    func sessionWindowSnapshot(tabManager: TabManager, windowId: UUID? = nil) -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            windowId: windowId,
            frame: nil,
            display: nil,
            tabManager: tabManager.sessionSnapshot(includeScrollback: false),
            sidebar: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: SessionPersistencePolicy.defaultSidebarWidth
            )
        )
    }

    func makeRetainedTextBoxInputTextView() -> TextBoxInputTextView {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        Self.retainedTextBoxRestoreViews.append(textView)
        return textView
    }

    func makeTemporaryPNGFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-textbox-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url.standardizedFileURL
    }

    func preparedSessionAttachmentSnapshot(
        _ attachment: TextBoxAttachment
    ) throws -> SessionTextBoxInputAttachmentSnapshot {
        _ = attachment.debugPrepareSessionDraftCopySynchronouslyForTesting()
        return SessionTextBoxInputAttachmentSnapshot(attachment)
    }

    enum TextBoxSubmissionPartSummary: Equatable {
        case text(String)
        case attachment(String)
    }

    func submissionPartSummaries(_ parts: [TextBoxSubmissionPart]) -> [TextBoxSubmissionPartSummary] {
        parts.map { part in
            switch part {
            case .text(let text):
                return .text(text)
            case .attachment(let attachment):
                return .attachment(attachment.submissionText)
            }
        }
    }

    func expectedImageSubmission(before: String, url: URL, after: String) -> String {
        var result = "\(before)\(TextBoxAttachment.submissionText(forLocalFileURL: url))"
        if result.last?.isWhitespace != true,
           after.first?.isWhitespace != true {
            result += " "
        }
        result += after
        return result
    }

    func withTemporaryShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut? = nil,
        _ body: () -> Void
    ) {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
            #if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
            #endif
        }
        KeyboardShortcutSettings.setShortcut(shortcut ?? action.defaultShortcut, for: action)
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
        body()
    }

    func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    func surfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
        var stack: [NSView] = [hostedView]
        while let current = stack.popLast() {
            if let surfaceView = current as? GhosttyNSView {
                return surfaceView
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        let appDelegate = AppDelegate.shared
        let originalConfirmationHandler = appDelegate?.debugCloseMainWindowConfirmationHandler
        appDelegate?.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate?.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    func waitFor(timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    func restoreDefaultsValue(_ value: Any?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

final class CommandPaletteMarkedTextFieldEditor: NSTextView {
    var hasMarkedTextForTesting = false

    override func hasMarkedText() -> Bool {
        hasMarkedTextForTesting
    }
}
