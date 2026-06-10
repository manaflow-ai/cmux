import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Stored shortcut matching and mapping
final class StoredShortcutMatchingTests: XCTestCase {
    private func makeMediaKeyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        keyState: UInt8 = 0x0A
    ) -> NSEvent? {
        let data1 = Int((UInt32(keyCode) << 16) | (UInt32(keyState) << 8))
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: Int16(8),
            data1: data1,
            data2: -1
        )
    }

    func testMatchingIgnoresCapsLock() {
        let shortcut = StoredShortcut(key: "q", command: true, shift: false, option: false, control: false)

        XCTAssertTrue(
            shortcut.matches(
                keyCode: 12,
                modifierFlags: [.command, .capsLock],
                eventCharacter: "q",
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testMatchingUsesRecordedCharacterForRemappedCommandLetter() {
        let shortcut = StoredShortcut(key: "q", command: true, shift: false, option: false, control: false)

        XCTAssertTrue(
            shortcut.matches(
                keyCode: 13,
                modifierFlags: [.command],
                eventCharacter: "q",
                layoutCharacterProvider: { _, _ in nil }
            )
        )
        XCTAssertFalse(
            StoredShortcut(key: "w", command: true, shift: false, option: false, control: false).matches(
                keyCode: 13,
                modifierFlags: [.command],
                eventCharacter: "q",
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testCommandShortcutUsesPrintableEventLetterBeforePhysicalPunctuationFallback() {
        let jumpToUnread = StoredShortcut(key: "u", command: true, shift: true, option: false, control: false)
        let nextSurface = StoredShortcut(key: "]", command: true, shift: true, option: false, control: false)

        XCTAssertTrue(
            jumpToUnread.matches(
                keyCode: 30,
                modifierFlags: [.command, .shift],
                eventCharacter: "u",
                layoutCharacterProvider: { _, _ in "]" }
            )
        )
        XCTAssertFalse(
            nextSurface.matches(
                keyCode: 30,
                modifierFlags: [.command, .shift],
                eventCharacter: "u",
                layoutCharacterProvider: { _, _ in "]" }
            )
        )
    }

    func testCommandControlLetterCanUseLayoutFallbackForControlCharacter() {
        let markUnreadAndJump = StoredShortcut(key: "u", command: true, shift: false, option: false, control: true)

        XCTAssertTrue(
            markUnreadAndJump.matches(
                keyCode: 32,
                modifierFlags: [.command, .control],
                eventCharacter: "\u{15}",
                layoutCharacterProvider: { keyCode, _ in keyCode == 32 ? "u" : nil }
            )
        )
    }

    func testCommandControlLetterCanUseLayoutFallbackForPrintableEventCharacter() {
        let markUnreadAndJump = StoredShortcut(key: "u", command: true, shift: false, option: false, control: true)

        XCTAssertTrue(
            markUnreadAndJump.matches(
                keyCode: 32,
                modifierFlags: [.command, .control],
                eventCharacter: "g",
                layoutCharacterProvider: { keyCode, _ in keyCode == 32 ? "u" : nil }
            )
        )
    }

    func testCommandControlPunctuationDoesNotStealPrintableLetterShortcut() {
        let nextWorkspace = StoredShortcut(key: "]", command: true, shift: false, option: false, control: true)

        XCTAssertFalse(
            nextWorkspace.matches(
                keyCode: 30,
                modifierFlags: [.command, .control],
                eventCharacter: "u",
                layoutCharacterProvider: { _, _ in "]" }
            )
        )
    }

    func testMatchingTreatsKeypadEnterAsReturn() {
        let shortcut = StoredShortcut(key: "\r", command: true, shift: false, option: false, control: false)

        XCTAssertTrue(
            shortcut.matches(
                keyCode: 76,
                modifierFlags: [.command],
                eventCharacter: "\r",
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testMatchingFallsBackToLayoutCharacterForNonLatinInput() {
        let shortcut = StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)

        XCTAssertTrue(
            shortcut.matches(
                keyCode: 17,
                modifierFlags: [.command],
                eventCharacter: "е",
                layoutCharacterProvider: { keyCode, _ in
                    keyCode == 17 ? "t" : nil
                }
            )
        )
    }

    func testResolvedKeyCodeUsesCurrentLayoutWhenShortcutWasStoredByCharacter() {
        let stroke = ShortcutStroke(key: "q", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            stroke.resolvedKeyCode(
                layoutCharacterProvider: { keyCode, flags in
                    guard flags == [.command] else { return nil }
                    switch keyCode {
                    case 12:
                        return "'"
                    case 13:
                        return "q"
                    default:
                        return nil
                    }
                }
            ),
            13
        )
    }

    func testResolvedKeyCodePrefersRecordedPhysicalKeyOverLayoutLookup() {
        let stroke = ShortcutStroke(key: "q", command: true, shift: false, option: false, control: false, keyCode: 13)

        XCTAssertEqual(
            stroke.resolvedKeyCode(
                layoutCharacterProvider: { keyCode, _ in
                    keyCode == 12 ? "q" : nil
                }
            ),
            13
        )
        XCTAssertEqual(stroke.carbonHotKeyRegistration?.keyCode, 13)
    }

    func testShortcutRecordingResultRejectsBareLetterWithoutModifier() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            XCTFail("Failed to construct bare letter event")
            return
        }

        XCTAssertEqual(
            ShortcutStroke.recordingResult(from: event, requireModifier: true),
            .rejected(.bareKeyNotAllowed)
        )
    }

    func testShortcutRecordingResultAcceptsBareFunctionKeyWithoutModifier() {
        let f1Characters = String(UnicodeScalar(NSF1FunctionKey)!)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: f1Characters,
            charactersIgnoringModifiers: f1Characters,
            isARepeat: false,
            keyCode: 122
        ) else {
            XCTFail("Failed to construct F1 event")
            return
        }

        XCTAssertEqual(
            ShortcutStroke.recordingResult(from: event, requireModifier: true),
            .accepted(ShortcutStroke(key: "f1", command: false, shift: false, option: false, control: false, keyCode: 122))
        )
    }

    func testShortcutRecordingResultSafelyIgnoresNonMediaSystemDefinedEvent() {
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) else {
            XCTFail("Failed to construct non-media system-defined event")
            return
        }

        XCTAssertFalse(ShortcutStroke.isEscapeCancelEvent(event))
        XCTAssertEqual(
            ShortcutStroke.recordingResult(from: event, requireModifier: true),
            .unsupportedKey
        )
    }

    func testMediaShortcutDoesNotMatchOrdinaryKeyDownWithSameKeyCode() {
        let shortcut = ShortcutStroke(
            key: "media.volumeUp",
            command: false,
            shift: false,
            option: false,
            control: false,
            keyCode: 0
        )

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            XCTFail("Failed to construct A key event")
            return
        }

        XCTAssertFalse(shortcut.matches(event: event))
    }

    func testMediaShortcutMatchesSystemDefinedMediaEvent() {
        let shortcut = ShortcutStroke(
            key: "media.volumeUp",
            command: false,
            shift: false,
            option: false,
            control: false,
            keyCode: 0
        )

        guard let event = makeMediaKeyEvent(keyCode: 0) else {
            XCTFail("Failed to construct media key event")
            return
        }

        XCTAssertTrue(shortcut.matches(event: event))
    }

    func testShortcutRecorderResolutionReportsConflictingAction() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let shortcut = StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.openBrowser.normalizedRecordedShortcutResult(shortcut),
            .rejected(.conflictsWithAction(.newSurface))
        )
    }

    func testShortcutRecorderResolutionRejectsNumberedShortcutAgainstReservedDigitFamily() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "3", command: true, shift: false, option: false, control: false),
            for: .openBrowser
        )

        let shortcut = StoredShortcut(key: "2", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.selectWorkspaceByNumber.normalizedRecordedShortcutResult(shortcut),
            .rejected(.conflictsWithAction(.openBrowser))
        )
    }

    func testShortcutRecorderResolutionRejectsSingleStrokeThatMatchesChordPrefix() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "k",
                command: true,
                shift: false,
                option: false,
                control: false,
                chordKey: "c",
                chordCommand: true,
                chordShift: false,
                chordOption: false,
                chordControl: false
            ),
            for: .openBrowser
        )

        let shortcut = StoredShortcut(key: "k", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.newTab.normalizedRecordedShortcutResult(shortcut),
            .rejected(.conflictsWithAction(.openBrowser))
        )
    }

    func testShortcutRecorderResolutionRejectsChordThatMatchesExistingSingleStrokePrefix() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: false, option: false, control: false),
            for: .openBrowser
        )

        let shortcut = StoredShortcut(
            key: "k",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "c",
            chordCommand: true,
            chordShift: false,
            chordOption: false,
            chordControl: false
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.newTab.normalizedRecordedShortcutResult(shortcut),
            .rejected(.conflictsWithAction(.openBrowser))
        )
    }

    func testSystemWideHotkeyNormalizationReportsCmuxActionConflictByRecordedPhysicalKey() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let shortcut = StoredShortcut(
            key: "q",
            command: true,
            shift: false,
            option: false,
            control: false,
            keyCode: 13
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.showHideAllWindows.normalizedRecordedShortcutResult(shortcut),
            .rejected(.conflictsWithAction(.quit))
        )
    }

    func testSystemWideHotkeyNormalizationReportsReservedHotkeyReason() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let shortcut = StoredShortcut(key: ".", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.showHideAllWindows.normalizedRecordedShortcutResult(shortcut),
            .rejected(.reservedBySystem)
        )
    }

    func testShortcutRecorderValidationPresentationSurfacesBareKeyMessage() {
        let presentation = ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(reason: .bareKeyNotAllowed, proposedShortcut: nil),
            action: .openBrowser,
            currentShortcut: KeyboardShortcutSettings.Action.openBrowser.defaultShortcut
        )

        XCTAssertEqual(presentation?.message, "Shortcuts must include ⌘ ⌥ ⌃ or ⇧")
        XCTAssertNil(presentation?.swapButtonTitle)
        XCTAssertFalse(presentation?.canSwap ?? true)
        XCTAssertEqual(presentation?.undoButtonTitle, "Undo")
    }

    func testShortcutRecorderValidationPresentationSurfacesConflictActionAndSwapAffordance() {
        let presentation = ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(
                reason: .conflictsWithAction(.newSurface),
                proposedShortcut: StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
            ),
            action: .openBrowser,
            currentShortcut: KeyboardShortcutSettings.Action.openBrowser.defaultShortcut,
            shortcutForAction: { $0.defaultShortcut }
        )

        XCTAssertEqual(presentation?.message, "This shortcut conflicts with New Surface (⌘T). Swap shortcuts?")
        XCTAssertEqual(presentation?.swapButtonTitle, "Swap")
        XCTAssertTrue(presentation?.canSwap ?? false)
        XCTAssertEqual(presentation?.undoButtonTitle, "Undo")
    }

    func testShortcutRecorderValidationPresentationUsesNumberedDisplayOnlyForNumberedConflicts() {
        let presentation = ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(
                reason: .conflictsWithAction(.selectWorkspaceByNumber),
                proposedShortcut: StoredShortcut(key: "2", command: true, shift: false, option: false, control: false)
            ),
            action: .openBrowser,
            currentShortcut: KeyboardShortcutSettings.Action.openBrowser.defaultShortcut,
            shortcutForAction: { $0.defaultShortcut }
        )

        XCTAssertEqual(
            presentation?.message,
            "This shortcut conflicts with Select Workspace 1…9 (⌘1…9)."
        )
        XCTAssertNil(presentation?.swapButtonTitle)
        XCTAssertFalse(presentation?.canSwap ?? true)
        XCTAssertEqual(presentation?.undoButtonTitle, "Undo")
    }

    func testShortcutRecorderValidationPresentationSurfacesReservedSystemMessage() {
        let presentation = ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(reason: .reservedBySystem, proposedShortcut: nil),
            action: .showHideAllWindows,
            currentShortcut: KeyboardShortcutSettings.Action.showHideAllWindows.defaultShortcut
        )

        XCTAssertEqual(presentation?.message, "This keystroke is reserved by macOS.")
        XCTAssertNil(presentation?.swapButtonTitle)
        XCTAssertFalse(presentation?.canSwap ?? true)
        XCTAssertEqual(presentation?.undoButtonTitle, "Undo")
    }
}


final class WorkspaceShortcutMapperTests: XCTestCase {
    func testCommandNineMapsToLastWorkspaceIndex() {
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forDigit: 9, workspaceCount: 1), 0)
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forDigit: 9, workspaceCount: 4), 3)
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forDigit: 9, workspaceCount: 12), 11)
    }

    func testCommandDigitBadgesUseNineForLastWorkspaceWhenNeeded() {
        XCTAssertEqual(WorkspaceShortcutMapper.digitForWorkspace(at: 0, workspaceCount: 12), 1)
        XCTAssertEqual(WorkspaceShortcutMapper.digitForWorkspace(at: 7, workspaceCount: 12), 8)
        XCTAssertEqual(WorkspaceShortcutMapper.digitForWorkspace(at: 11, workspaceCount: 12), 9)
        XCTAssertNil(WorkspaceShortcutMapper.digitForWorkspace(at: 8, workspaceCount: 12))
    }
}
