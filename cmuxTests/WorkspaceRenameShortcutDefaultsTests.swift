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


final class WorkspaceRenameShortcutDefaultsTests: XCTestCase {
    func testRenameTabShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.label, "Rename Tab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.defaultsKey, "shortcut.renameTab")

        let shortcut = KeyboardShortcutSettings.Action.renameTab.defaultShortcut
        XCTAssertEqual(shortcut.key, "r")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testCloseWindowShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWindow.label, "Close Window")
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWindow.defaultsKey, "shortcut.closeWindow")

        let shortcut = KeyboardShortcutSettings.Action.closeWindow.defaultShortcut
        XCTAssertEqual(shortcut.key, "w")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertTrue(shortcut.control)
    }

    func testRenameWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.label, "Rename Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.defaultsKey, "shortcut.renameWorkspace")

        let shortcut = KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "r")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testRenameWorkspaceShortcutConvertsToMenuShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        XCTAssertNotNil(shortcut.keyEquivalent)
        XCTAssertTrue(shortcut.eventModifiers.contains(.command))
        XCTAssertTrue(shortcut.eventModifiers.contains(.shift))
        XCTAssertFalse(shortcut.eventModifiers.contains(.option))
        XCTAssertFalse(shortcut.eventModifiers.contains(.control))
    }

    func testCloseWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWorkspace.label, "Close Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWorkspace.defaultsKey, "shortcut.closeWorkspace")

        let shortcut = KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "w")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testCloseWorkspaceShortcutConvertsToMenuShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        XCTAssertNotNil(shortcut.keyEquivalent)
        XCTAssertTrue(shortcut.eventModifiers.contains(.command))
        XCTAssertTrue(shortcut.eventModifiers.contains(.shift))
        XCTAssertFalse(shortcut.eventModifiers.contains(.option))
        XCTAssertFalse(shortcut.eventModifiers.contains(.control))
    }

    func testNextPreviousWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.label, "Next Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.label, "Previous Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.focusHistoryBack.label, "Focus Back")
        XCTAssertEqual(KeyboardShortcutSettings.Action.focusHistoryForward.label, "Focus Forward")
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.defaultsKey, "shortcut.nextSidebarTab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.defaultsKey, "shortcut.prevSidebarTab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.focusHistoryBack.defaultsKey, "shortcut.focusHistoryBack")
        XCTAssertEqual(KeyboardShortcutSettings.Action.focusHistoryForward.defaultsKey, "shortcut.focusHistoryForward")

        let nextShortcut = KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        XCTAssertEqual(nextShortcut.key, "]")
        XCTAssertTrue(nextShortcut.command)
        XCTAssertFalse(nextShortcut.shift)
        XCTAssertFalse(nextShortcut.option)
        XCTAssertTrue(nextShortcut.control)

        let prevShortcut = KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        XCTAssertEqual(prevShortcut.key, "[")
        XCTAssertTrue(prevShortcut.command)
        XCTAssertFalse(prevShortcut.shift)
        XCTAssertFalse(prevShortcut.option)
        XCTAssertTrue(prevShortcut.control)

        let focusBackShortcut = KeyboardShortcutSettings.Action.focusHistoryBack.defaultShortcut
        XCTAssertEqual(focusBackShortcut.key, "[")
        XCTAssertTrue(focusBackShortcut.command)
        XCTAssertFalse(focusBackShortcut.shift)
        XCTAssertFalse(focusBackShortcut.option)
        XCTAssertFalse(focusBackShortcut.control)

        let focusForwardShortcut = KeyboardShortcutSettings.Action.focusHistoryForward.defaultShortcut
        XCTAssertEqual(focusForwardShortcut.key, "]")
        XCTAssertTrue(focusForwardShortcut.command)
        XCTAssertFalse(focusForwardShortcut.shift)
        XCTAssertFalse(focusForwardShortcut.option)
        XCTAssertFalse(focusForwardShortcut.control)

        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.focusHistoryBack))
        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.focusHistoryForward))
    }

    func testNextPreviousWorkspaceShortcutsConvertToMenuShortcut() {
        let nextShortcut = KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        XCTAssertNotNil(nextShortcut.keyEquivalent)
        XCTAssertEqual(nextShortcut.menuItemKeyEquivalent, "]")
        XCTAssertTrue(nextShortcut.eventModifiers.contains(.command))
        XCTAssertTrue(nextShortcut.eventModifiers.contains(.control))

        let prevShortcut = KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        XCTAssertNotNil(prevShortcut.keyEquivalent)
        XCTAssertEqual(prevShortcut.menuItemKeyEquivalent, "[")
        XCTAssertTrue(prevShortcut.eventModifiers.contains(.command))
        XCTAssertTrue(prevShortcut.eventModifiers.contains(.control))
    }

    func testToggleTerminalCopyModeShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.toggleTerminalCopyMode.label, "Toggle Terminal Copy Mode")
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleTerminalCopyMode.defaultsKey,
            "shortcut.toggleTerminalCopyMode"
        )

        let shortcut = KeyboardShortcutSettings.Action.toggleTerminalCopyMode.defaultShortcut
        XCTAssertEqual(shortcut.key, "m")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testSaveFilePreviewShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.saveFilePreview.label, "Save File Preview")
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.saveFilePreview.defaultsKey,
            "shortcut.saveFilePreview"
        )

        let shortcut = KeyboardShortcutSettings.Action.saveFilePreview.defaultShortcut
        XCTAssertEqual(shortcut.key, "s")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testRightSidebarAndFindShortcutDefaultsMatchSettingsSurface() {
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.focusRightSidebar.label,
            String(localized: "shortcut.focusRightSidebar.label", defaultValue: "Toggle Right Sidebar Focus")
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleRightSidebar.label,
            String(localized: "shortcut.toggleRightSidebar.label", defaultValue: "Toggle Right Sidebar")
        )

        let toggleRightSidebar = KeyboardShortcutSettings.Action.toggleRightSidebar.defaultShortcut
        XCTAssertEqual(toggleRightSidebar.key, "b")
        XCTAssertTrue(toggleRightSidebar.command)
        XCTAssertFalse(toggleRightSidebar.shift)
        XCTAssertTrue(toggleRightSidebar.option)
        XCTAssertFalse(toggleRightSidebar.control)

        let focusRightSidebar = KeyboardShortcutSettings.Action.focusRightSidebar.defaultShortcut
        XCTAssertEqual(focusRightSidebar.key, "e")
        XCTAssertTrue(focusRightSidebar.command)
        XCTAssertTrue(focusRightSidebar.shift)
        XCTAssertFalse(focusRightSidebar.option)
        XCTAssertFalse(focusRightSidebar.control)

        let findInDirectory = KeyboardShortcutSettings.Action.findInDirectory.defaultShortcut
        XCTAssertEqual(findInDirectory.key, "f")
        XCTAssertTrue(findInDirectory.command)
        XCTAssertTrue(findInDirectory.shift)
        XCTAssertFalse(findInDirectory.option)
        XCTAssertFalse(findInDirectory.control)
    }

    func testRightSidebarModeSwitchesHavePrivateControlDigitDefaults() {
        let modeSwitchActions: [(KeyboardShortcutSettings.Action, String)] = [
            (.switchRightSidebarToFiles, "1"),
            (.switchRightSidebarToFind, "2"),
            (.switchRightSidebarToSessions, "3"),
            (.switchRightSidebarToFeed, "4"),
            (.switchRightSidebarToDock, "5"),
        ]

        for (action, key) in modeSwitchActions {
            XCTAssertEqual(action.defaultShortcut.key, key)
            XCTAssertFalse(action.defaultShortcut.command)
            XCTAssertFalse(action.defaultShortcut.shift)
            XCTAssertFalse(action.defaultShortcut.option)
            XCTAssertTrue(action.defaultShortcut.control)
            XCTAssertFalse(action.isPublicShortcutAction)
            XCTAssertFalse(KeyboardShortcutSettings.publicShortcutActions.contains(action))
            XCTAssertFalse(KeyboardShortcutSettings.settingsVisibleActions.contains(action))
        }
    }

    func testSettingsVisibleShortcutActionsIncludeRemappableExampleShortcuts() {
        let visibleActions = Set(KeyboardShortcutSettings.settingsVisibleActions)

        XCTAssertTrue(visibleActions.contains(.toggleRightSidebar))
        XCTAssertTrue(visibleActions.contains(.focusRightSidebar))
        XCTAssertTrue(visibleActions.contains(.findInDirectory))
        XCTAssertTrue(visibleActions.contains(.toggleUnread))
        XCTAssertTrue(visibleActions.contains(.markOldestUnreadAndJumpNext))
        XCTAssertFalse(visibleActions.contains(.showHideAllWindows))
    }

    func testToggleUnreadUsesConfigurableCommandOptionUDefault() {
        let shortcut = KeyboardShortcutSettings.Action.toggleUnread.defaultShortcut

        XCTAssertEqual(shortcut.key, "u")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.control)
        XCTAssertTrue(KeyboardShortcutSettings.publicShortcutActions.contains(.toggleUnread))
        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.toggleUnread))
    }

    func testMarkOldestUnreadAndJumpNextUsesConfigurableCommandControlUDefault() {
        let shortcut = KeyboardShortcutSettings.Action.markOldestUnreadAndJumpNext.defaultShortcut

        XCTAssertEqual(shortcut.key, "u")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertTrue(shortcut.control)
        XCTAssertTrue(KeyboardShortcutSettings.publicShortcutActions.contains(.markOldestUnreadAndJumpNext))
        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.markOldestUnreadAndJumpNext))
    }

    func testSettingsVisibleShortcutActionsColocateRightSidebarFileExplorerAndFindShortcuts() {
        let visibleActions = KeyboardShortcutSettings.settingsVisibleActions
        let expectedActions: [KeyboardShortcutSettings.Action] = [
            .focusRightSidebar,
            .toggleRightSidebar,
            .findInDirectory,
        ]

        guard let startIndex = visibleActions.firstIndex(of: .focusRightSidebar) else {
            XCTFail("Toggle Right Sidebar Focus should be visible in keyboard shortcut settings")
            return
        }

        let endIndex = startIndex + expectedActions.count
        guard endIndex <= visibleActions.count else {
            XCTFail("Expected shortcut settings to include the full right-sidebar shortcut run")
            return
        }
        XCTAssertEqual(Array(visibleActions[startIndex..<endIndex]), expectedActions)
    }

    func testMenuItemKeyEquivalentHandlesArrowAndTabKeys() {
        XCTAssertNotNil(StoredShortcut(key: "←", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "→", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "↑", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "↓", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertEqual(
            StoredShortcut(key: "\t", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent,
            "\t"
        )
    }

    func testShortcutDefaultsKeysRemainUnique() {
        let keys = KeyboardShortcutSettings.Action.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testChordedShortcutDisplayDisablesMenuKeyEquivalent() {
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )

        XCTAssertEqual(shortcut.displayString, "⌃B D")
        XCTAssertNil(shortcut.keyEquivalent)
        XCTAssertNil(shortcut.menuItemKeyEquivalent)
    }

    func testNumberedChordDisplayUsesChordSuffix() {
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "7"
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.selectWorkspaceByNumber.displayedShortcutString(for: shortcut),
            "⌃B 1…9"
        )
    }

    func testNumberedChordNormalizationTargetsSecondStroke() {
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "7"
        )

        let normalized = KeyboardShortcutSettings.Action.selectWorkspaceByNumber.normalizedRecordedShortcut(shortcut)
        XCTAssertEqual(normalized?.key, "b")
        XCTAssertEqual(normalized?.chordKey, "1")
    }

    func testStoredShortcutDecodesLegacySingleStrokePayload() throws {
        let data = """
        {"key":"d","command":true,"shift":false,"option":false,"control":false}
        """.data(using: .utf8)!

        let shortcut = try JSONDecoder().decode(StoredShortcut.self, from: data)

        XCTAssertEqual(shortcut.key, "d")
        XCTAssertFalse(shortcut.hasChord)
        XCTAssertNil(shortcut.chordKey)
    }

    func testEscapeCancelDetectionTreatsEscapeCharacterAsCancelEvenWithUnexpectedKeyCode() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 36
        ) else {
            XCTFail("Failed to construct escape-like event")
            return
        }

        XCTAssertTrue(ShortcutStroke.isEscapeCancelEvent(event))
        XCTAssertNil(ShortcutStroke.from(event: event, requireModifier: false))
    }

    func testEscapeCancelDetectionAllowsModifiedEscapeGeneratingShortcut() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 33
        ) else {
            XCTFail("Failed to construct modified escape-generating event")
            return
        }

        XCTAssertFalse(ShortcutStroke.isEscapeCancelEvent(event))
        XCTAssertEqual(
            ShortcutStroke.from(event: event, requireModifier: false),
            ShortcutStroke(key: "[", command: true, shift: false, option: false, control: false, keyCode: 33)
        )
    }

    func testShortcutRecorderStopsRecordingWhenFirstStrokeConfirmationIsRejected() {
#if DEBUG
        let button = ShortcutRecorderNSButton(frame: .zero)
        button.transformRecordedShortcut = { _ in .rejected(.reservedBySystem) }
        button.debugSetPendingChordStart(
            ShortcutStroke(
                key: "x",
                command: true,
                shift: false,
                option: false,
                control: false
            )
        )

        button.performClick(nil)

        XCTAssertFalse(button.debugIsRecording)
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }

    func testShortcutRecorderCommitsAcceptedFirstStrokeImmediately() {
#if DEBUG
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let button = ShortcutRecorderNSButton(frame: .zero)
        let recordedShortcut = StoredShortcut(
            key: "l",
            command: true,
            shift: true,
            option: false,
            control: false,
            keyCode: 37
        )
        var committedShortcut: StoredShortcut?
        var feedbackEvents: [ShortcutRecorderRejectedAttempt?] = []

        button.transformRecordedShortcut = { shortcut in
            XCTAssertEqual(shortcut, recordedShortcut)
            return .accepted(shortcut)
        }
        button.onShortcutRecorded = { committedShortcut = $0 }
        button.onRecorderFeedbackChanged = { feedbackEvents.append($0) }
        button.performClick(nil)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "L",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 37
        ) else {
            XCTFail("Failed to construct Command-Shift-L event")
            return
        }

        XCTAssertNil(button.debugHandleRecordingEvent(event))
        XCTAssertEqual(committedShortcut, recordedShortcut)
        XCTAssertEqual(button.shortcut, recordedShortcut)
        XCTAssertFalse(button.debugIsRecording)
        XCTAssertTrue(feedbackEvents.contains { $0 == nil })
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }

    func testShortcutRecorderCapturesKeyEquivalentWhileRecording() {
#if DEBUG
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let button = ShortcutRecorderNSButton(frame: .zero)
        let recordedShortcut = StoredShortcut(
            key: "t",
            command: true,
            shift: false,
            option: false,
            control: false,
            keyCode: 17
        )
        var committedShortcut: StoredShortcut?

        button.transformRecordedShortcut = { shortcut in
            XCTAssertEqual(shortcut, recordedShortcut)
            return .accepted(shortcut)
        }
        button.onShortcutRecorded = { committedShortcut = $0 }
        button.performClick(nil)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false,
            keyCode: 17
        ) else {
            XCTFail("Failed to construct Command-T event")
            return
        }

        XCTAssertTrue(button.performKeyEquivalent(with: event))
        XCTAssertEqual(committedShortcut, recordedShortcut)
        XCTAssertFalse(button.debugIsRecording)
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }

    func testShortcutRecorderStopAllNotificationStopsActiveRecorder() {
#if DEBUG
        let button = ShortcutRecorderNSButton(frame: .zero)
        button.debugSetPendingChordStart(
            ShortcutStroke(
                key: "l",
                command: true,
                shift: false,
                option: false,
                control: false
            )
        )

        KeyboardShortcutRecorderActivity.stopAllRecording()

        XCTAssertFalse(button.debugIsRecording)
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }
}

