import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Sparkle
import CmuxUpdater

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Shortcut hint modifier policy, debug settings, and layout planners
final class ShortcutHintModifierPolicyTests: XCTestCase {
    func testTitlebarShortcutHintActionSlotsIncludeFocusHistoryNavigation() {
        XCTAssertEqual(
            TitlebarShortcutHintActionSlot.allCases.map(\.action),
            [
                .toggleSidebar,
                .showNotifications,
                .newTab,
                .focusHistoryBack,
                .focusHistoryForward,
            ]
        )
    }

    func testTitlebarShortcutHintAlwaysShowAllowsBoundNonCommandShortcut() {
        let controlShortcut = StoredShortcut(key: "R", command: false, shift: false, option: false, control: true)
        let commandShortcut = StoredShortcut(key: "R", command: true, shift: false, option: false, control: false)

        XCTAssertTrue(
            titlebarShortcutHintShouldShow(
                shortcut: controlShortcut,
                alwaysShowShortcutHints: true,
                modifierPressed: false
            )
        )
        XCTAssertFalse(
            titlebarShortcutHintShouldShow(
                shortcut: controlShortcut,
                alwaysShowShortcutHints: false,
                modifierPressed: true
            )
        )
        XCTAssertTrue(
            titlebarShortcutHintShouldShow(
                shortcut: commandShortcut,
                alwaysShowShortcutHints: false,
                modifierPressed: true
            )
        )
        XCTAssertFalse(
            titlebarShortcutHintShouldShow(
                shortcut: .unbound,
                alwaysShowShortcutHints: true,
                modifierPressed: true
            )
        )
    }

    func testShortcutHintRequiresEnabledCommandOrControlOnlyModifier() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.command, .shift], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.control, .shift], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.command, .option], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.control, .option], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.command, .control], defaults: defaults))
        }
    }

    func testShortcutHintShowsForControlModifier() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
        }
    }

    func testControlOnlyShortcutHintRequiresControlModifier() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowControlHints(for: [.control], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowControlHints(for: [.command], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowControlHints(for: [.control, .shift], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowControlHints(for: [.control, .option], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowControlHints(for: [], defaults: defaults))
        }
    }

    func testCommandOnlyShortcutHintRequiresCommandModifier() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowCommandHints(for: [.command], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowCommandHints(for: [.control], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowCommandHints(for: [.command, .shift], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowCommandHints(for: [.command, .option], defaults: defaults))
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowCommandHints(for: [], defaults: defaults))
        }
    }

    func testCommandAndControlHintsAreHardcodedEnabled() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
        }
    }

    func testShortcutHintIgnoresCustomizedWorkspaceShortcutModifiers() {
        let action = KeyboardShortcutSettings.Action.selectWorkspaceByNumber
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "1", command: false, shift: false, option: false, control: true),
            for: action
        )

        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
        }
    }

    func testShortcutHintIgnoresWorkspaceShortcutChords() {
        let action = KeyboardShortcutSettings.Action.selectWorkspaceByNumber
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "1",
                command: false,
                shift: false,
                option: false,
                control: true,
                chordKey: "2",
                chordCommand: true,
                chordShift: false,
                chordOption: false,
                chordControl: false
            ),
            for: action
        )

        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
        }
    }

    func testShortcutHintUsesIntentionalHoldDelay() {
        XCTAssertEqual(ShortcutHintModifierPolicy.intentionalHoldDelay, 0.30, accuracy: 0.001)
    }

    func testCurrentWindowRequiresHostWindowToBeKeyAndMatchEventWindow() {
        XCTAssertTrue(
            ShortcutHintModifierPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: 42,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            ShortcutHintModifierPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: 7,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            ShortcutHintModifierPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: false,
                eventWindowNumber: 42,
                keyWindowNumber: 42
            )
        )
    }

    func testWindowScopedShortcutHintsUseKeyWindowWhenNoEventWindowIsAvailable() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(
                ShortcutHintModifierPolicy.shouldShowHints(
                    for: [.command],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )

            XCTAssertFalse(
                ShortcutHintModifierPolicy.shouldShowHints(
                    for: [.command],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 7,
                    defaults: defaults
                )
            )

            XCTAssertTrue(
                ShortcutHintModifierPolicy.shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )
        }
    }

    private func withDefaultsSuite(_ body: (UserDefaults) -> Void) {
        let suiteName = "ShortcutHintModifierPolicyTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        body(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }
}


final class RightSidebarModeShortcutHintTests: XCTestCase {
    private let touchedShortcutActions: [KeyboardShortcutSettings.Action] = [
        .focusRightSidebar,
        .switchRightSidebarToFiles,
        .switchRightSidebarToFind,
        .switchRightSidebarToSessions,
        .switchRightSidebarToFeed,
        .switchRightSidebarToDock,
    ]
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
    private var savedShortcutData: [KeyboardShortcutSettings.Action: Data?] = [:]
    private var temporaryDirectoryURL: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        savedShortcutData = Dictionary(
            uniqueKeysWithValues: touchedShortcutActions.map { action in
                (action, UserDefaults.standard.data(forKey: action.defaultsKey))
            }
        )

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        temporaryDirectoryURL = directoryURL
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: directoryURL.appendingPathComponent("cmux.json", isDirectory: false).path,
            fallbackPath: nil,
            startWatching: false
        )
        for action in touchedShortcutActions {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
        KeyboardShortcutSettings.notifySettingsFileDidChange()
    }

    override func tearDownWithError() throws {
        for action in touchedShortcutActions {
            if case let .some(.some(data)) = savedShortcutData[action] {
                UserDefaults.standard.set(data, forKey: action.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: action.defaultsKey)
            }
        }
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.notifySettingsFileDidChange()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    func testModeShortcutActionsMatchModeSwitchingActions() {
        XCTAssertEqual(RightSidebarMode.files.shortcutAction, .switchRightSidebarToFiles)
        XCTAssertEqual(RightSidebarMode.find.shortcutAction, .switchRightSidebarToFind)
        XCTAssertEqual(RightSidebarMode.sessions.shortcutAction, .switchRightSidebarToSessions)
        XCTAssertEqual(RightSidebarMode.feed.shortcutAction, .switchRightSidebarToFeed)
        XCTAssertEqual(RightSidebarMode.dock.shortcutAction, .switchRightSidebarToDock)
    }

    func testModeShortcutsUsePrivateControlDigitDefaults() {
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "1", modifiers: [.control], keyCode: 18)),
            .files
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "2", modifiers: [.control], keyCode: 19)),
            .find
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "3", modifiers: [.control], keyCode: 20)),
            .sessions
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "4", modifiers: [.control], keyCode: 21)),
            .feed
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "5", modifiers: [.control], keyCode: 23)),
            .dock
        )
    }

    func testModeShortcutUsesConfiguredBindings() {
        let customFilesShortcut = StoredShortcut(
            key: "4",
            command: false,
            shift: false,
            option: false,
            control: true
        )
        KeyboardShortcutSettings.setShortcut(customFilesShortcut, for: .switchRightSidebarToFiles)

        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "4", modifiers: [.control], keyCode: 21)),
            .files
        )
        XCTAssertNil(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "1", modifiers: [.control], keyCode: 18))
        )
    }

    func testModeShortcutUsesSettingsFileBindings() throws {
        let settingsFileURL = try XCTUnwrap(temporaryDirectoryURL)
            .appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "switchRightSidebarToFiles": "ctrl+8"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        KeyboardShortcutSettings.settingsFileStore.reload()
        KeyboardShortcutSettings.notifySettingsFileDidChange()

        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "8", modifiers: [.control], keyCode: 28)),
            .files
        )
        XCTAssertNil(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "1", modifiers: [.control], keyCode: 18))
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "2", modifiers: [.control], keyCode: 19)),
            .find
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "3", modifiers: [.control], keyCode: 20)),
            .sessions
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "4", modifiers: [.control], keyCode: 21)),
            .feed
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "5", modifiers: [.control], keyCode: 23)),
            .dock
        )
    }

    func testFocusRightSidebarShortcutCanBeOverwrittenForHintRendering() {
        let customShortcut = StoredShortcut(
            key: "e",
            command: true,
            shift: true,
            option: true,
            control: false
        )
        KeyboardShortcutSettings.setShortcut(customShortcut, for: .focusRightSidebar)

        let resolvedShortcut = KeyboardShortcutSettings.shortcut(for: .focusRightSidebar)
        XCTAssertEqual(resolvedShortcut, customShortcut)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.focusRightSidebar.displayedShortcutString(for: resolvedShortcut),
            customShortcut.displayString
        )
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }
}

final class ShortcutHintDebugSettingsTests: XCTestCase {
    func testClampKeepsValuesWithinSupportedRange() {
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(0.0), 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(4.0), 4.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(-100.0), ShortcutHintDebugSettings.offsetRange.lowerBound)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(100.0), ShortcutHintDebugSettings.offsetRange.upperBound)
    }

    func testDefaultOffsetsMatchCurrentBadgePlacements() {
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintY, -5.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultRightSidebarCloseHintX, -10.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultRightSidebarCloseHintY, 3.3)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultRightSidebarFocusHintX, -1.6)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultRightSidebarFocusHintY, 1.7)
        XCTAssertFalse(ShortcutHintDebugSettings.defaultAlwaysShowHints)
        XCTAssertTrue(ShortcutHintDebugSettings.defaultShowHintsOnCommandHold)
        XCTAssertTrue(ShortcutHintDebugSettings.defaultShowHintsOnControlHold)
    }

    func testAlwaysShowHintsIsOnlyEnabledForUITests() {
        XCTAssertFalse(ShortcutHintDebugSettings.alwaysShowHints(environment: [:]))
        XCTAssertTrue(
            ShortcutHintDebugSettings.alwaysShowHints(
                environment: ["CMUX_UI_TEST_SHORTCUT_HINTS_ALWAYS_SHOW": "1"]
            )
        )
    }

    func testShowHintsOnCommandHoldIsHardcodedEnabled() {
        let suiteName = "ShortcutHintDebugSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(defaults: defaults))
    }

    func testShowHintsOnControlHoldIsHardcodedEnabled() {
        let suiteName = "ShortcutHintDebugSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ShortcutHintDebugSettings.showHintsOnControlHoldEnabled(defaults: defaults))
    }
}


final class ShortcutHintLanePlannerTests: XCTestCase {
    func testAssignLanesKeepsSeparatedIntervalsOnSingleLane() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 28...40, 48...64]
        XCTAssertEqual(ShortcutHintLanePlanner.assignLanes(for: intervals, minSpacing: 4), [0, 0, 0])
    }

    func testAssignLanesStacksOverlappingIntervalsIntoAdditionalLanes() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 22...38, 40...56]
        XCTAssertEqual(ShortcutHintLanePlanner.assignLanes(for: intervals, minSpacing: 4), [0, 1, 2, 0])
    }
}


final class ShortcutHintHorizontalPlannerTests: XCTestCase {
    func testAssignRightEdgesResolvesOverlapWithMinimumSpacing() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 30...46]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 6)

        XCTAssertEqual(rightEdges.count, intervals.count)

        let adjustedIntervals = zip(intervals, rightEdges).map { interval, rightEdge in
            let width = interval.upperBound - interval.lowerBound
            return (rightEdge - width)...rightEdge
        }

        XCTAssertGreaterThanOrEqual(adjustedIntervals[1].lowerBound - adjustedIntervals[0].upperBound, 6)
        XCTAssertGreaterThanOrEqual(adjustedIntervals[2].lowerBound - adjustedIntervals[1].upperBound, 6)
    }

    func testAssignRightEdgesKeepsAlreadySeparatedIntervalsInPlace() {
        let intervals: [ClosedRange<CGFloat>] = [0...12, 20...32, 40...52]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 4)
        XCTAssertEqual(rightEdges, [12, 32, 52])
    }

    func testAssignRightEdgesKeepsCrowdedHintsInsideLeadingEdge() {
        let intervals: [ClosedRange<CGFloat>] = [-2...24, 27...50, 50...76, 78...102, 104...128]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 6)

        let adjustedIntervals = zip(intervals, rightEdges).map { interval, rightEdge in
            let width = interval.upperBound - interval.lowerBound
            return (rightEdge - width)...rightEdge
        }

        XCTAssertGreaterThanOrEqual(adjustedIntervals[0].lowerBound, 0)
        for index in 1..<adjustedIntervals.count {
            XCTAssertGreaterThanOrEqual(
                adjustedIntervals[index].lowerBound - adjustedIntervals[index - 1].upperBound,
                6
            )
        }
    }
}


