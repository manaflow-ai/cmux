import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import UserNotifications
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
func makeTemporaryBrowserProfile(named prefix: String) throws -> BrowserProfileDefinition {
    try XCTUnwrap(
        BrowserProfileStore.shared.createProfile(
            named: "\(prefix)-\(UUID().uuidString)"
        )
    )
}

final class SidebarSelectedWorkspaceColorTests: XCTestCase {
    func testLightModeUsesConfiguredSelectedWorkspaceBackgroundColor() {
        guard let color = sidebarSelectedWorkspaceBackgroundNSColor(for: .light).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 136.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testDarkModeUsesConfiguredSelectedWorkspaceBackgroundColor() {
        guard let color = sidebarSelectedWorkspaceBackgroundNSColor(for: .dark).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 145.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testSelectedWorkspaceForegroundAlwaysUsesWhiteWithRequestedOpacity() {
        guard let color = sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.65).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }
}


@MainActor
final class WorkspaceSplitPolicyTests: XCTestCase {
    func testCloseTabHonorsDisabledClosePolicy() throws {
        let controller = WorkspaceLayoutController(
            configuration: WorkspaceLayoutConfiguration(allowCloseTabs: false)
        )
        let tab = try XCTUnwrap(controller.createTab(title: "One"))

        XCTAssertFalse(controller.closeTab(tab))
        XCTAssertNotNil(controller.rootNode.findTab(tab))
    }

    func testSamePaneMoveHonorsDisabledReorderPolicy() throws {
        let controller = WorkspaceLayoutController(
            configuration: WorkspaceLayoutConfiguration(allowTabReordering: false)
        )
        let first = try XCTUnwrap(controller.createTab(title: "One"))
        let second = try XCTUnwrap(controller.createTab(title: "Two"))
        let paneId = try XCTUnwrap(controller.focusedPaneId)

        XCTAssertEqual(controller.rootNode.findPane(paneId)?.tabIds, [first.id, second.id])
        XCTAssertFalse(controller.reorderTab(first, toIndex: 2))
        XCTAssertFalse(controller.moveTab(first, toPane: paneId, atIndex: 2))
        XCTAssertEqual(controller.rootNode.findPane(paneId)?.tabIds, [first.id, second.id])
    }

    func testCrossPaneMoveHonorsDisabledCrossPanePolicy() throws {
        let controller = WorkspaceLayoutController(
            configuration: WorkspaceLayoutConfiguration(allowCrossPaneTabMove: false)
        )
        let tab = try XCTUnwrap(controller.createTab(title: "One"))
        let sourcePaneId = try XCTUnwrap(controller.focusedPaneId)
        let targetPaneId = try XCTUnwrap(
            controller.splitPane(sourcePaneId, orientation: .horizontal)
        )

        XCTAssertFalse(controller.moveTab(tab, toPane: targetPaneId))
        XCTAssertEqual(controller.rootNode.findPane(sourcePaneId)?.tabIds, [tab.id])
        XCTAssertEqual(controller.rootNode.findPane(targetPaneId)?.tabIds, [])
    }

    func testCrossPaneMovePreservesEmptySourcePaneWhenAutoCloseDisabled() throws {
        let controller = WorkspaceLayoutController(
            configuration: WorkspaceLayoutConfiguration(autoCloseEmptyPanes: false)
        )
        let tab = try XCTUnwrap(controller.createTab(title: "One"))
        let sourcePaneId = try XCTUnwrap(controller.focusedPaneId)
        let targetPaneId = try XCTUnwrap(
            controller.splitPane(sourcePaneId, orientation: .horizontal)
        )

        XCTAssertTrue(controller.moveTab(tab, toPane: targetPaneId))
        XCTAssertEqual(controller.rootNode.findPane(sourcePaneId)?.tabIds, [])
        XCTAssertEqual(controller.rootNode.findPane(targetPaneId)?.tabIds, [tab.id])
        XCTAssertEqual(Set(controller.allPaneIds), Set([sourcePaneId, targetPaneId]))
    }

    func testCloseTabPreservesEmptyPaneWhenAutoCloseDisabled() throws {
        let controller = WorkspaceLayoutController(
            configuration: WorkspaceLayoutConfiguration(autoCloseEmptyPanes: false)
        )
        let tab = try XCTUnwrap(controller.createTab(title: "One"))
        let sourcePaneId = try XCTUnwrap(controller.focusedPaneId)
        let targetPaneId = try XCTUnwrap(
            controller.splitPane(sourcePaneId, orientation: .horizontal)
        )

        XCTAssertTrue(controller.closeTab(tab, inPane: sourcePaneId))
        XCTAssertEqual(controller.rootNode.findPane(sourcePaneId)?.tabIds, [])
        XCTAssertNotNil(controller.rootNode.findPane(targetPaneId))
        XCTAssertEqual(Set(controller.allPaneIds), Set([sourcePaneId, targetPaneId]))
    }

    func testCloseLastPaneReplacesItWithEmptyPaneWhenAllowed() throws {
        let controller = WorkspaceLayoutController(
            configuration: WorkspaceLayoutConfiguration(allowCloseLastPane: true)
        )
        let originalPaneId = try XCTUnwrap(controller.focusedPaneId)

        XCTAssertTrue(controller.closePane(originalPaneId))
        XCTAssertNil(controller.rootNode.findPane(originalPaneId))
        XCTAssertEqual(controller.allPaneIds.count, 1)

        let replacementPaneId = try XCTUnwrap(controller.focusedPaneId)
        XCTAssertNotEqual(replacementPaneId, originalPaneId)
        XCTAssertEqual(controller.rootNode.findPane(replacementPaneId)?.tabIds, [])
    }
}


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
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.defaultsKey, "shortcut.nextSidebarTab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.defaultsKey, "shortcut.prevSidebarTab")

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
            ShortcutStroke(key: "[", command: true, shift: false, option: false, control: false)
        )
    }

    func testShortcutRecorderStopsRecordingWhenFirstStrokeConfirmationIsRejected() {
#if DEBUG
        let button = ShortcutRecorderNSButton(frame: .zero)
        button.transformRecordedShortcut = { _ in nil }
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
}

final class KeyboardShortcutSettingsFileStoreTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"

    override func setUp() {
        super.setUp()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        AppIconSettings.resetLiveEnvironmentProviderForTesting()
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    func testSettingsFileStoreParsesSingleStrokeChordAndNumberedChord() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "toggleSidebar": "cmd+b",
                "newTab": ["ctrl+b", "c"],
                "selectWorkspaceByNumber": ["ctrl+b", "7"]
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .toggleSidebar),
            StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(
            store.override(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
        XCTAssertEqual(
            store.override(for: .selectWorkspaceByNumber),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "1")
        )
        XCTAssertEqual(store.activeSourcePath, settingsFileURL.path)
    }

    func testSettingsFileStoreDoesNotApplyAutomaticAppIconDuringStartupReplay() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: AppIconSettings.modeKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: AppIconSettings.modeKey)
            } else {
                defaults.removeObject(forKey: AppIconSettings.modeKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: AppIconSettings.modeKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "appIcon": "automatic"
              }
            }
            """,
            to: settingsFileURL
        )

        var startObservationCallCount = 0
        var stopObservationCallCount = 0
        var imageRequestCount = 0
        var runtimeIconSetCount = 0
        var dockTileNotificationCount = 0
        AppIconSettings.setLiveEnvironmentProviderForTesting {
            AppIconSettings.Environment(
                isApplicationFinishedLaunching: { false },
                imageForMode: { _ in
                    imageRequestCount += 1
                    return nil
                },
                setApplicationIconImage: { _ in
                    runtimeIconSetCount += 1
                },
                startAppearanceObservation: {
                    startObservationCallCount += 1
                },
                stopAppearanceObservation: {
                    stopObservationCallCount += 1
                },
                notifyDockTilePlugin: {
                    dockTileNotificationCount += 1
                }
            )
        }

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.string(forKey: AppIconSettings.modeKey), AppIconMode.automatic.rawValue)
        XCTAssertEqual(startObservationCallCount, 0)
        XCTAssertEqual(stopObservationCallCount, 0)
        XCTAssertEqual(imageRequestCount, 0)
        XCTAssertEqual(runtimeIconSetCount, 0)
        XCTAssertEqual(dockTileNotificationCount, 0)
    }

    func testSettingsFileStoreCanReplayAutomaticAppIconSettingTwiceWithoutTouchingAppKit() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: AppIconSettings.modeKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: AppIconSettings.modeKey)
            } else {
                defaults.removeObject(forKey: AppIconSettings.modeKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: AppIconSettings.modeKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "appIcon": "automatic"
              }
            }
            """,
            to: settingsFileURL
        )

        var startObservationCallCount = 0
        var stopObservationCallCount = 0
        var imageRequestCount = 0
        var runtimeIconSetCount = 0
        var dockTileNotificationCount = 0
        AppIconSettings.setLiveEnvironmentProviderForTesting {
            AppIconSettings.Environment(
                isApplicationFinishedLaunching: { false },
                imageForMode: { _ in
                    imageRequestCount += 1
                    return nil
                },
                setApplicationIconImage: { _ in
                    runtimeIconSetCount += 1
                },
                startAppearanceObservation: {
                    startObservationCallCount += 1
                },
                stopAppearanceObservation: {
                    stopObservationCallCount += 1
                },
                notifyDockTilePlugin: {
                    dockTileNotificationCount += 1
                }
            )
        }

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.string(forKey: AppIconSettings.modeKey), AppIconMode.automatic.rawValue)
        XCTAssertEqual(startObservationCallCount, 0)
        XCTAssertEqual(stopObservationCallCount, 0)
        XCTAssertEqual(imageRequestCount, 0)
        XCTAssertEqual(runtimeIconSetCount, 0)
        XCTAssertEqual(dockTileNotificationCount, 0)
    }

    func testSettingsFileStoreRejectsModifierFreeFirstStroke() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "toggleSidebar": "b",
                "newTab": ["b", "c"],
                "splitRight": ["ctrl+b", "d"]
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(store.override(for: .toggleSidebar))
        XCTAssertNil(store.override(for: .newTab))
        XCTAssertEqual(
            store.override(for: .splitRight),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "d")
        )
    }

    func testSettingsFileStoreUsesFallbackOnlyWhenPrimaryIsMissing() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let fallbackStore = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )
        XCTAssertEqual(
            fallbackStore.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(fallbackStore.activeSourcePath, fallbackURL.path)

        try writeSettingsFile("{ not valid json", to: primaryURL)

        let invalidPrimaryStore = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )
        XCTAssertNil(invalidPrimaryStore.override(for: .showNotifications))
        XCTAssertEqual(invalidPrimaryStore.activeSourcePath, primaryURL.path)
    }

    func testShortcutSettingsFileOverridesPersistedShortcutValues() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false),
            for: .newTab
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
        XCTAssertTrue(KeyboardShortcutSettings.isManagedBySettingsFile(.newTab))
        XCTAssertNotNil(KeyboardShortcutSettings.settingsFileManagedSubtitle(for: .newTab))
    }

    @MainActor
    func testReloadConfigurationReloadsShortcutSettingsFile() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": "cmd+n"
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        )

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        GhosttyApp.shared.reloadConfiguration(source: "test.reload_config")

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
    }

    func testManagedShortcutWritesDoNotOverwritePersistedValue() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        let missingSettingsFileURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        let persistedShortcut = StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        let managedShortcut = StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")

        KeyboardShortcutSettings.setShortcut(persistedShortcut, for: .newTab)

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), managedShortcut)

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "t", command: true, shift: false, option: false, control: false),
            for: .newTab
        )

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), managedShortcut)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertFalse(KeyboardShortcutSettings.isManagedBySettingsFile(.newTab))
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), persistedShortcut)
    }

    func testSystemWideHotkeySettingsPreserveInvalidManagedShortcutWithoutFallingBackToDefault() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showHideAllWindows": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let invalidShortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "c"
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.settingsFileStore.override(for: .showHideAllWindows),
            invalidShortcut
        )
        XCTAssertTrue(SystemWideHotkeySettings.isManagedBySettingsFile())
        XCTAssertEqual(SystemWideHotkeySettings.shortcut(), invalidShortcut)
        XCTAssertNotEqual(SystemWideHotkeySettings.shortcut(), SystemWideHotkeySettings.defaultShortcut)
        XCTAssertNil(SystemWideHotkeySettings.shortcut().carbonHotKeyRegistration)
    }

    func testSystemWideHotkeyLegacyMigrationPreservesInvalidShortcut() throws {
        let invalidShortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "c"
        )
        let encodedShortcut = try XCTUnwrap(try? JSONEncoder().encode(invalidShortcut))
        let defaults = UserDefaults.standard
        defaults.set(encodedShortcut, forKey: SystemWideHotkeySettings.legacyShortcutKey)

        let migratedShortcut = SystemWideHotkeySettings.shortcut()

        XCTAssertEqual(migratedShortcut, invalidShortcut)
        XCTAssertNil(defaults.object(forKey: SystemWideHotkeySettings.legacyShortcutKey))

        let migratedData = try XCTUnwrap(
            defaults.data(forKey: KeyboardShortcutSettings.Action.showHideAllWindows.defaultsKey)
        )
        let storedShortcut = try XCTUnwrap(try? JSONDecoder().decode(StoredShortcut.self, from: migratedData))
        XCTAssertEqual(storedShortcut, invalidShortcut)
        XCTAssertNil(storedShortcut.carbonHotKeyRegistration)
    }

    func testBootstrapCreatesCommentedTemplateWhenPrimaryAndFallbackAreMissing() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL
            .appendingPathComponent(".config/cmux", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsFileURL.path))
        XCTAssertEqual(store.activeSourcePath, settingsFileURL.path)
        XCTAssertNil(store.override(for: .newTab))

        let contents = try String(contentsOf: settingsFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains(#""$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json""#))
        XCTAssertTrue(contents.contains(#""schemaVersion": 1,"#))
        XCTAssertTrue(contents.contains(#"//   "app" : {"#))
        XCTAssertTrue(contents.contains(#"//     "colors" : {"#))
        XCTAssertTrue(contents.contains(##"//       "Red" : "#C0392B""##))
        XCTAssertTrue(contents.contains(#"//   "shortcuts" : {"#))
    }

    func testBootstrapDoesNotCreatePrimaryWhenFallbackAlreadyExists() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary/settings.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback/settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertEqual(store.activeSourcePath, fallbackURL.path)
    }

    func testSettingsFileURLForEditingUsesActiveFallbackWithoutCreatingPrimary() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary/settings.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback/settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertEqual(store.settingsFileURLForEditing().path, fallbackURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
    }

    func testSettingsFileURLForEditingPrefersInvalidPrimaryForRepair() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary/settings.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback/settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSettingsFile("{ not valid json", to: primaryURL)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertEqual(store.settingsFileURLForEditing().path, primaryURL.path)
        XCTAssertEqual(store.activeSourcePath, primaryURL.path)
    }

    func testSettingsFileStoreParsesJSONCCommentsAndTrailingCommas() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json",
              "schemaVersion": 1,
              // tmux-like prefix
              "shortcuts": {
                "bindings": {
                  "newTab": [
                    "ctrl+b",
                    "c",
                  ],
                },
              },
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
    }

    func testFutureSchemaVersionStillParsesKnownFields() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "schemaVersion": 999,
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )
    }

    func testManagedUserDefaultSettingRestoresBackedUpValueWhenFileSettingIsRemoved() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspaceAutoReorderSettings.key
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.set(false, forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let managedSettingsURL = directoryURL.appendingPathComponent("managed.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "reorderOnNotification": true
              }
            }
            """,
            to: managedSettingsURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: managedSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.object(forKey: managedKey) as? Bool, true)

        let missingSettingsURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.object(forKey: managedKey) as? Bool, false)
        XCTAssertNil(defaults.data(forKey: settingsFileBackupsDefaultsKey))
    }

    func testSettingsFileStoreAppliesWorkspaceColorDictionaryAndAllowsRemovingDefaults() throws {
        let defaults = UserDefaults.standard
        let previousPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey) as? [String: String]
        let previousLegacyOverrides = defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") as? [String: String]
        let previousLegacyCustomColors = defaults.array(forKey: "workspaceTabColor.customColors") as? [String]
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            WorkspaceTabColorSettings.reset(defaults: defaults)
            if let previousPalette {
                defaults.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
            }
            if let previousLegacyOverrides {
                defaults.set(previousLegacyOverrides, forKey: "workspaceTabColor.defaultOverrides")
            }
            if let previousLegacyCustomColors {
                defaults.set(previousLegacyCustomColors, forKey: "workspaceTabColor.customColors")
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceColors": {
                "colors": {
                  "Blue": "#2244ff",
                  "Neon Mint": "#00f5d4"
                }
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let palette = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(palette.map(\.name), ["Blue", "Neon Mint"])
        XCTAssertEqual(palette.map(\.hex), ["#2244FF", "#00F5D4"])
    }

    func testManagedWorkspaceColorsRestoreLegacyPaletteWhenFileSettingIsRemoved() throws {
        let defaults = UserDefaults.standard
        let previousPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey) as? [String: String]
        let previousLegacyOverrides = defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") as? [String: String]
        let previousLegacyCustomColors = defaults.array(forKey: "workspaceTabColor.customColors") as? [String]
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            WorkspaceTabColorSettings.reset(defaults: defaults)
            if let previousPalette {
                defaults.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
            }
            if let previousLegacyOverrides {
                defaults.set(previousLegacyOverrides, forKey: "workspaceTabColor.defaultOverrides")
            }
            if let previousLegacyCustomColors {
                defaults.set(previousLegacyCustomColors, forKey: "workspaceTabColor.customColors")
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.set(["Blue": "#010203"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#778899"], forKey: "workspaceTabColor.customColors")
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let managedSettingsURL = directoryURL.appendingPathComponent("managed.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceColors": {
                "colors": {
                  "Neon Mint": "#00F5D4"
                }
              }
            }
            """,
            to: managedSettingsURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: managedSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults).map(\.name), ["Neon Mint"])

        let missingSettingsURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let restored = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(restored.first(where: { $0.name == "Blue" })?.hex, "#010203")
        XCTAssertEqual(restored.first(where: { $0.name == "Custom 1" })?.hex, "#778899")
        XCTAssertNil(defaults.data(forKey: settingsFileBackupsDefaultsKey))
    }

    @MainActor
    func testReloadConfigurationReloadsManagedAppSettingsFromSettingsFile() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspacePlacementSettings.placementKey
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "newWorkspacePlacement": "top"
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(WorkspacePlacementSettings.current(), .top)

        try writeSettingsFile(
            """
            {
              "app": {
                "newWorkspacePlacement": "end"
              }
            }
            """,
            to: settingsFileURL
        )

        GhosttyApp.shared.reloadConfiguration(source: "test.reload_config_app_setting")

        XCTAssertEqual(WorkspacePlacementSettings.current(), .end)
    }

    @MainActor
    func testManagedWorkspacePlacementChangesDefaultInsertionBehavior() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspacePlacementSettings.placementKey
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "newWorkspacePlacement": "top"
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let manager = TabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace(placementOverride: .end)
        let third = manager.addWorkspace(placementOverride: .end)
        manager.selectWorkspace(first)

        let inserted = manager.addWorkspace()

        XCTAssertEqual(manager.tabs.map(\.id), [inserted.id, first.id, second.id, third.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class StoredShortcutMatchingTests: XCTestCase {
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

    func testSystemWideHotkeyNormalizationRejectsReservedShortcutByRecordedPhysicalKey() {
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

        XCTAssertNil(KeyboardShortcutSettings.Action.showHideAllWindows.normalizedRecordedShortcut(shortcut))
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
@MainActor
final class WorkspaceCustomDescriptionTests: XCTestCase {
    func testSetCustomDescriptionPreservesMeaningfulLeadingAndTrailingWhitespace() {
        let workspace = Workspace()
        let description = "  line one\n\nline two\n\n"

        workspace.setCustomDescription(description)

        XCTAssertEqual(workspace.customDescription, description)
        XCTAssertTrue(workspace.hasCustomDescription)
    }

    func testSetCustomDescriptionClearsWhitespaceOnlyDescriptions() {
        let workspace = Workspace()

        workspace.setCustomDescription(" \n\t \n")

        XCTAssertNil(workspace.customDescription)
        XCTAssertFalse(workspace.hasCustomDescription)
    }
}
final class WorkspacePlacementSettingsTests: XCTestCase {
    func testCurrentPlacementDefaultsToAfterCurrentWhenUnset() {
        let suiteName = "WorkspacePlacementSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .afterCurrent)
    }

    func testCurrentPlacementReadsStoredValidValueAndFallsBackForInvalid() {
        let suiteName = "WorkspacePlacementSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(NewWorkspacePlacement.top.rawValue, forKey: WorkspacePlacementSettings.placementKey)
        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .top)

        defaults.set("nope", forKey: WorkspacePlacementSettings.placementKey)
        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .afterCurrent)
    }

    func testInsertionIndexTopInsertsBeforeUnpinned() {
        let index = WorkspacePlacementSettings.insertionIndex(
            placement: .top,
            selectedIndex: 4,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 7
        )
        XCTAssertEqual(index, 2)
    }

    func testInsertionIndexAfterCurrentHandlesPinnedAndUnpinnedSelection() {
        let afterUnpinned = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 3,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterUnpinned, 4)

        let afterPinned = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 0,
            selectedIsPinned: true,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterPinned, 2)
    }

    func testInsertionIndexEndAndNoSelectionAppend() {
        let endIndex = WorkspacePlacementSettings.insertionIndex(
            placement: .end,
            selectedIndex: 1,
            selectedIsPinned: false,
            pinnedCount: 1,
            totalCount: 5
        )
        XCTAssertEqual(endIndex, 5)

        let noSelectionIndex = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: nil,
            selectedIsPinned: false,
            pinnedCount: 0,
            totalCount: 5
        )
        XCTAssertEqual(noSelectionIndex, 5)
    }
}


@MainActor
final class WorkspaceCreationPlacementTests: XCTestCase {
    private final class SnapshotMutatingTabManager: TabManager {
        var afterCaptureWorkspaceCreationSnapshot: (() -> Void)?
        var beforeCreateWorkspace: (() -> Void)?

        override func didCaptureWorkspaceCreationSnapshot() {
            afterCaptureWorkspaceCreationSnapshot?()
        }

        override func makeWorkspaceForCreation(
            title: String,
            workingDirectory: String?,
            portOrdinal: Int,
            configTemplate: CmuxSurfaceConfigTemplate?,
            initialTerminalCommand: String?,
            initialTerminalEnvironment: [String: String]
        ) -> Workspace {
            beforeCreateWorkspace?()
            return super.makeWorkspaceForCreation(
                title: title,
                workingDirectory: workingDirectory,
                portOrdinal: portOrdinal,
                configTemplate: configTemplate,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalEnvironment: initialTerminalEnvironment
            )
        }
    }

    func testAddWorkspaceDefaultPlacementMatchesCurrentSetting() {
        let currentPlacement = WorkspacePlacementSettings.current()

        let defaultManager = makeManagerWithThreeWorkspaces()
        let defaultBaselineOrder = defaultManager.tabs.map(\.id)
        let defaultInserted = defaultManager.addWorkspace()
        guard let defaultInsertedIndex = defaultManager.tabs.firstIndex(where: { $0.id == defaultInserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }
        XCTAssertEqual(defaultManager.tabs.map(\.id).filter { $0 != defaultInserted.id }, defaultBaselineOrder)

        let explicitManager = makeManagerWithThreeWorkspaces()
        let explicitBaselineOrder = explicitManager.tabs.map(\.id)
        let explicitInserted = explicitManager.addWorkspace(placementOverride: currentPlacement)
        guard let explicitInsertedIndex = explicitManager.tabs.firstIndex(where: { $0.id == explicitInserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }
        XCTAssertEqual(explicitManager.tabs.map(\.id).filter { $0 != explicitInserted.id }, explicitBaselineOrder)
        XCTAssertEqual(defaultInsertedIndex, explicitInsertedIndex)
    }

    func testAddWorkspaceEndOverrideAlwaysAppends() {
        let manager = makeManagerWithThreeWorkspaces()
        let baselineCount = manager.tabs.count
        guard baselineCount >= 3 else {
            XCTFail("Expected at least three workspaces for placement regression test")
            return
        }

        let inserted = manager.addWorkspace(placementOverride: .end)
        guard let insertedIndex = manager.tabs.firstIndex(where: { $0.id == inserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }

        XCTAssertEqual(insertedIndex, baselineCount)
    }

    func testAddWorkspaceAfterCurrentOverrideAppendsAfterLastSelectedWorkspace() {
        let manager = TabManager()
        guard !manager.tabs.isEmpty else {
            XCTFail("Expected TabManager to initialise with at least one workspace")
            return
        }
        _ = manager.addWorkspace()
        _ = manager.addWorkspace()
        let fourth = manager.addWorkspace()
        let baselineOrder = manager.tabs.map(\.id)

        manager.selectWorkspace(fourth)
        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.last?.id, inserted.id)
    }

    func testAddWorkspaceAfterCurrentUsesPrecreationSnapshotWhenSelectionMutatesDuringBootstrap() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        manager.setPinned(first, pinned: true)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        let baselineOrder = manager.tabs.map(\.id)
        manager.beforeCreateWorkspace = {
            manager.selectWorkspace(first)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentDoesNotReinsertClosedWorkspaceCapturedInSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.closeWorkspace(second)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id, inserted.id])
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == second.id }))
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceSurvivesSelectedWorkspaceClosingAfterSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.closeWorkspace(third)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, inserted.id])
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == third.id }))
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceSurvivesMidCreationClose() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let closingWorkspace = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        let closingWorkspaceId = closingWorkspace.id
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, closingWorkspaceId, third.id])

        manager.afterCaptureWorkspaceCreationSnapshot = {
            guard let liveWorkspace = manager.tabs.first(where: { $0.id == closingWorkspaceId }) else {
                XCTFail("Expected captured workspace to still be present when closing after snapshot")
                return
            }
            manager.closeWorkspace(liveWorkspace)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == closingWorkspaceId }))
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentUsesSnapshotPinnedStateWhenPinningMutatesAfterSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        manager.setPinned(first, pinned: true)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(first)
        let baselineOrder = manager.tabs.map(\.id)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.setPinned(first, pinned: false)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, inserted.id, second.id, third.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentFollowsLiveReorderUsingSnapshotTabValues() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(second)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            XCTAssertTrue(
                manager.reorderWorkspace(tabId: third.id, toIndex: 0),
                "Expected to reorder live workspaces after the snapshot is captured"
            )
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(
            manager.tabs.map(\.id).filter { $0 != inserted.id },
            [third.id, first.id, second.id]
        )
        XCTAssertEqual(manager.tabs.map(\.id), [third.id, first.id, second.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    private func makeManagerWithThreeWorkspaces() -> TabManager {
        let manager = TabManager()
        _ = manager.addWorkspace()
        _ = manager.addWorkspace()
        if let first = manager.tabs.first {
            manager.selectWorkspace(first)
        }
        return manager
    }
}

@MainActor
final class WorkspaceCreationConfigSanitizationTests: XCTestCase {
    private final class UnsafeConfigSnapshotTabManager: TabManager {
        private var injectedConfig: CmuxSurfaceConfigTemplate?
        var capturedConfigTemplate: CmuxSurfaceConfigTemplate?

        func installInjectedConfig(fontSize: Float) {
            var config = CmuxSurfaceConfigTemplate()
            config.fontSize = fontSize
            config.workingDirectory = "/tmp/cmux-workspace-snapshot"
            config.command = "echo snapshot"
            config.environmentVariables = ["CMUX_INHERITED_ENV": "1"]
            injectedConfig = config
        }

        override func inheritedTerminalConfigForNewWorkspace(
            workspace: Workspace?
        ) -> CmuxSurfaceConfigTemplate? {
            injectedConfig ?? super.inheritedTerminalConfigForNewWorkspace(workspace: workspace)
        }

        override func makeWorkspaceForCreation(
            title: String,
            workingDirectory: String?,
            portOrdinal: Int,
            configTemplate: CmuxSurfaceConfigTemplate?,
            initialTerminalCommand: String?,
            initialTerminalEnvironment: [String: String]
        ) -> Workspace {
            capturedConfigTemplate = configTemplate
            return super.makeWorkspaceForCreation(
                title: title,
                workingDirectory: workingDirectory,
                portOrdinal: portOrdinal,
                configTemplate: configTemplate,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalEnvironment: initialTerminalEnvironment
            )
        }
    }

    func testAddWorkspacePassesSanitizedInheritedConfigTemplate() {
        let manager = UnsafeConfigSnapshotTabManager()
        manager.installInjectedConfig(fontSize: 19)

        _ = manager.addWorkspace()

        guard let capturedConfig = manager.capturedConfigTemplate else {
            XCTFail("Expected captured config template for new workspace")
            return
        }

        XCTAssertEqual(capturedConfig.fontSize, 19, accuracy: 0.001)
        XCTAssertNil(capturedConfig.workingDirectory)
        XCTAssertNil(capturedConfig.command)
        XCTAssertTrue(capturedConfig.environmentVariables.isEmpty)
    }
}


final class WorkspaceTabColorSettingsTests: XCTestCase {
    func testNormalizedHexAcceptsAndNormalizesValidInput() {
        XCTAssertEqual(WorkspaceTabColorSettings.normalizedHex("#abc123"), "#ABC123")
        XCTAssertEqual(WorkspaceTabColorSettings.normalizedHex("  aBcDeF "), "#ABCDEF")
        XCTAssertNil(WorkspaceTabColorSettings.normalizedHex("#1234"))
        XCTAssertNil(WorkspaceTabColorSettings.normalizedHex("#GG1234"))
    }

    func testBuiltInPaletteMatchesOriginalPRPalette() {
        let palette = WorkspaceTabColorSettings.defaultPalette
        XCTAssertEqual(palette.count, 16)
        XCTAssertEqual(palette.first?.name, "Red")
        XCTAssertEqual(palette.first?.hex, "#C0392B")
        XCTAssertEqual(palette.last?.name, "Charcoal")
        XCTAssertFalse(palette.contains(where: { $0.name == "Gold" }))
    }

    func testPaletteFallsBackToBuiltInDefaultsWhenUnset() {
        let suiteName = "WorkspaceTabColorSettingsTests.BuiltInPalette.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults), WorkspaceTabColorSettings.defaultPalette)
    }

    func testSetColorRoundTripFallsBackWhenResetToBase() {
        let suiteName = "WorkspaceTabColorSettingsTests.SetColor.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = WorkspaceTabColorSettings.defaultPalette[0]
        XCTAssertEqual(
            WorkspaceTabColorSettings.currentColorHex(named: first.name, defaults: defaults),
            first.hex
        )

        WorkspaceTabColorSettings.setColor(named: first.name, hex: "#00aa33", defaults: defaults)
        XCTAssertEqual(
            WorkspaceTabColorSettings.currentColorHex(named: first.name, defaults: defaults),
            "#00AA33"
        )
        XCTAssertNotNil(defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey))

        WorkspaceTabColorSettings.setColor(named: first.name, hex: first.hex, defaults: defaults)
        XCTAssertEqual(
            WorkspaceTabColorSettings.currentColorHex(named: first.name, defaults: defaults),
            first.hex
        )
        XCTAssertNil(defaults.object(forKey: WorkspaceTabColorSettings.paletteKey))
    }

    func testAddCustomColorCreatesNamedEntriesAndDeduplicatesByHex() {
        let suiteName = "WorkspaceTabColorSettingsTests.NamedCustomColors.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor(" #00aa33 ", defaults: defaults),
            "#00AA33"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor("#112233", defaults: defaults),
            "#112233"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor("#00AA33", defaults: defaults),
            "#00AA33"
        )
        XCTAssertNil(WorkspaceTabColorSettings.addCustomColor("nope", defaults: defaults))

        let customEntries = WorkspaceTabColorSettings.customPaletteEntries(defaults: defaults)
        XCTAssertEqual(customEntries.map(\.name), ["Custom 1", "Custom 2"])
        XCTAssertEqual(customEntries.map(\.hex), ["#00AA33", "#112233"])
    }

    func testPaletteDictionaryCanRemoveBuiltInEntriesAndAddNamedOnes() {
        let suiteName = "WorkspaceTabColorSettingsTests.DictionaryPalette.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var palette = Dictionary(uniqueKeysWithValues: WorkspaceTabColorSettings.defaultPalette.map { ($0.name, $0.hex) })
        palette.removeValue(forKey: "Red")
        palette["Neon Mint"] = "#00F5D4"
        WorkspaceTabColorSettings.persistPaletteMap(palette, defaults: defaults)

        let resolved = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertFalse(resolved.contains(where: { $0.name == "Red" }))
        XCTAssertEqual(resolved.first?.name, "Crimson")
        XCTAssertEqual(resolved.last?.name, "Neon Mint")
        XCTAssertEqual(resolved.last?.hex, "#00F5D4")
    }

    func testLegacyKeysStillResolveIntoEffectivePalette() {
        let suiteName = "WorkspaceTabColorSettingsTests.LegacyKeys.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["Blue": "#010203"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#778899"], forKey: "workspaceTabColor.customColors")

        let resolved = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(
            resolved.first(where: { $0.name == "Blue" })?.hex,
            "#010203"
        )
        XCTAssertEqual(
            resolved.first(where: { $0.name == "Custom 1" })?.hex,
            "#778899"
        )
    }

    func testResetClearsNewAndLegacyStorage() {
        let suiteName = "WorkspaceTabColorSettingsTests.Reset.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        WorkspaceTabColorSettings.persistPaletteMap(["Neon Mint": "#00F5D4"], defaults: defaults)
        defaults.set(["Blue": "#010203"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#778899"], forKey: "workspaceTabColor.customColors")

        WorkspaceTabColorSettings.reset(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: WorkspaceTabColorSettings.paletteKey))
        XCTAssertNil(defaults.object(forKey: "workspaceTabColor.defaultOverrides"))
        XCTAssertNil(defaults.object(forKey: "workspaceTabColor.customColors"))
        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults), WorkspaceTabColorSettings.defaultPalette)
    }

    func testDisplayColorLightModeKeepsOriginalHex() {
        let originalHex = "#1A5276"
        let rendered = WorkspaceTabColorSettings.displayNSColor(
            hex: originalHex,
            colorScheme: .light
        )

        XCTAssertEqual(rendered?.hexString(), originalHex)
    }

    func testDisplayColorDarkModeBrightensColor() {
        let originalHex = "#1A5276"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .dark
              ) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertNotEqual(rendered.hexString(), originalHex)
        XCTAssertGreaterThan(rendered.luminance, base.luminance)
    }

    func testDisplayColorDarkModeKeepsGrayscaleNeutral() {
        let originalHex = "#808080"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .dark
              ),
              let renderedSRGB = rendered.usingColorSpace(.sRGB) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertGreaterThan(rendered.luminance, base.luminance)
        XCTAssertLessThan(abs(renderedSRGB.redComponent - renderedSRGB.greenComponent), 0.003)
        XCTAssertLessThan(abs(renderedSRGB.greenComponent - renderedSRGB.blueComponent), 0.003)
    }

    func testDisplayColorForceBrightensInLightMode() {
        let originalHex = "#1A5276"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .light,
                  forceBright: true
              ) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertNotEqual(rendered.hexString(), originalHex)
        XCTAssertGreaterThan(rendered.luminance, base.luminance)
    }
}


final class WorkspaceAutoReorderSettingsTests: XCTestCase {
    func testDefaultIsEnabled() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }

    func testDisabledWhenSetToFalse() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Disabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: WorkspaceAutoReorderSettings.key)
        XCTAssertFalse(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }

    func testEnabledWhenSetToTrue() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Enabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: WorkspaceAutoReorderSettings.key)
        XCTAssertTrue(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }
}


final class SidebarWorkspaceDetailSettingsTests: XCTestCase {
    func testDefaultPreferencesWhenUnset() {
        let suiteName = "SidebarWorkspaceDetailSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults))
        XCTAssertTrue(SidebarWorkspaceDetailSettings.showsNotificationMessage(defaults: defaults))
        XCTAssertTrue(
            SidebarWorkspaceDetailSettings.resolvedNotificationMessageVisibility(
                showNotificationMessage: SidebarWorkspaceDetailSettings.showsNotificationMessage(defaults: defaults),
                hideAllDetails: SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults)
            )
        )
    }

    func testStoredPreferencesOverrideDefaults() {
        let suiteName = "SidebarWorkspaceDetailSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: SidebarWorkspaceDetailSettings.hideAllDetailsKey)
        defaults.set(false, forKey: SidebarWorkspaceDetailSettings.showNotificationMessageKey)

        XCTAssertTrue(SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults))
        XCTAssertFalse(SidebarWorkspaceDetailSettings.showsNotificationMessage(defaults: defaults))
        XCTAssertFalse(
            SidebarWorkspaceDetailSettings.resolvedNotificationMessageVisibility(
                showNotificationMessage: SidebarWorkspaceDetailSettings.showsNotificationMessage(defaults: defaults),
                hideAllDetails: false
            )
        )
        XCTAssertFalse(
            SidebarWorkspaceDetailSettings.resolvedNotificationMessageVisibility(
                showNotificationMessage: true,
                hideAllDetails: SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults)
            )
        )
    }
}


final class SidebarWorkspaceAuxiliaryDetailVisibilityTests: XCTestCase {
    func testResolvedVisibilityPreservesPerRowTogglesWhenDetailsAreShown() {
        XCTAssertEqual(
            SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
                showMetadata: true,
                showLog: false,
                showProgress: true,
                showBranchDirectory: false,
                showPullRequests: true,
                showPorts: false,
                hideAllDetails: false
            ),
            SidebarWorkspaceAuxiliaryDetailVisibility(
                showsMetadata: true,
                showsLog: false,
                showsProgress: true,
                showsBranchDirectory: false,
                showsPullRequests: true,
                showsPorts: false
            )
        )
    }

    func testResolvedVisibilityHidesAllAuxiliaryRowsWhenDetailsAreHidden() {
        XCTAssertEqual(
            SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
                showMetadata: true,
                showLog: true,
                showProgress: true,
                showBranchDirectory: true,
                showPullRequests: true,
                showPorts: true,
                hideAllDetails: true
            ),
            .hidden
        )
    }
}


final class WorkspaceReorderTests: XCTestCase {
    @MainActor
    func testReorderWorkspaceMovesWorkspaceToRequestedIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        XCTAssertTrue(manager.reorderWorkspace(tabId: second.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id, third.id])
        XCTAssertEqual(manager.selectedTabId, second.id)
    }

    @MainActor
    func testReorderWorkspaceClampsOutOfRangeTargetIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: first.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
    }

    @MainActor
    func testReorderWorkspaceReturnsFalseForUnknownWorkspace() {
        let manager = TabManager()
        XCTAssertFalse(manager.reorderWorkspace(tabId: UUID(), toIndex: 0))
    }

    @MainActor
    func testReorderWorkspaceKeepsUnpinnedWorkspaceBelowPinnedSegment() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: unpinned.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [firstPinned.id, secondPinned.id, unpinned.id])
    }

    @MainActor
    func testReorderWorkspaceKeepsPinnedWorkspaceInsidePinnedSegment() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: firstPinned.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [secondPinned.id, firstPinned.id, unpinned.id])
    }
}


@MainActor
final class WorkspaceNotificationReorderTests: XCTestCase {
    func testNotificationAutoReorderDoesNotMovePinnedWorkspace() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let notificationStore = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let defaults = UserDefaults.standard
        let originalAutoReorderSetting = defaults.object(forKey: WorkspaceAutoReorderSettings.key)
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = notificationStore
        defaults.set(true, forKey: WorkspaceAutoReorderSettings.key)
        AppFocusState.overrideIsFocused = false

        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalAutoReorderSetting {
                defaults.set(originalAutoReorderSetting, forKey: WorkspaceAutoReorderSettings.key)
            } else {
                defaults.removeObject(forKey: WorkspaceAutoReorderSettings.key)
            }
        }

        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()
        let expectedOrder = [firstPinned.id, secondPinned.id, unpinned.id]

        notificationStore.addNotification(
            tabId: secondPinned.id,
            surfaceId: nil,
            title: "Build finished",
            subtitle: "",
            body: "Pinned workspaces should stay put"
        )

        XCTAssertEqual(manager.tabs.map(\.id), expectedOrder)
    }
}


@MainActor
final class WorkspaceTeardownTests: XCTestCase {
    func testTeardownAllPanelsClearsPanelMetadataCaches() {
        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        workspace.setPanelCustomTitle(panelId: initialPanelId, title: "Initial custom title")
        workspace.setPanelPinned(panelId: initialPanelId, pinned: true)

        guard let splitPanel = workspace.splitTerminalPanel(fromPanelId: initialPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }

        workspace.setPanelCustomTitle(panelId: splitPanel.id, title: "Split custom title")
        workspace.setPanelPinned(panelId: splitPanel.id, pinned: true)
        workspace.markPanelUnread(initialPanelId)

        XCTAssertFalse(workspace.panels.isEmpty)
        XCTAssertTrue(workspace.surfaceStatesSnapshot().values.contains { $0.title != nil })
        XCTAssertTrue(workspace.surfaceStatesSnapshot().values.contains { $0.customTitle != nil })
        XCTAssertTrue(workspace.surfaceStatesSnapshot().values.contains(where: \.isPinned))
        XCTAssertTrue(workspace.surfaceStatesSnapshot().values.contains(where: \.isManuallyUnread))

        workspace.teardownAllPanels()

        XCTAssertTrue(workspace.panels.isEmpty)
        XCTAssertTrue(workspace.surfaceStatesSnapshot().values.allSatisfy { $0.title == nil })
        XCTAssertTrue(workspace.surfaceStatesSnapshot().values.allSatisfy { $0.customTitle == nil })
        XCTAssertTrue(workspace.surfaceStatesSnapshot().values.allSatisfy { !$0.isPinned })
        XCTAssertTrue(workspace.surfaceStatesSnapshot().values.allSatisfy { !$0.isManuallyUnread })
    }
}

@MainActor
final class WorkspaceLayoutSimplificationTests: XCTestCase {
    private func temporaryMarkdownFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-layout-simplification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("note.md")
        try "# workspace\n".write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func firstPaneSnapshot(
        from snapshot: WorkspaceLayoutRenderSnapshot
    ) -> WorkspaceLayoutPaneRenderSnapshot? {
        switch snapshot.root {
        case .pane(let pane):
            return pane
        case .split(let split):
            if case .pane(let first) = split.first {
                return first
            }
            if case .pane(let second) = split.second {
                return second
            }
            return nil
        }
    }

    private func firstSplitSnapshot(
        from snapshot: WorkspaceLayoutRenderSnapshot
    ) -> WorkspaceLayoutSplitRenderSnapshot? {
        guard case .split(let split) = snapshot.root else { return nil }
        return split
    }

    private func viewport(
        in snapshot: WorkspaceLayoutRenderSnapshot,
        for paneId: PaneID
    ) -> WorkspaceLayoutViewportSnapshot? {
        snapshot.viewports.first { $0.paneId == paneId }
    }

    func testSurfaceAndPanelIdentityRoundTripUsesCanonicalID() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        guard let surfaceId = workspace.surfaceIdFromPanelId(panelId) else {
            XCTFail("Expected surface ID for focused panel")
            return
        }

        XCTAssertEqual(surfaceId.id, panelId)
        XCTAssertEqual(workspace.panel(for: surfaceId)?.id, panelId)
    }

    func testRenderTabChromeProjectsWorkspaceOwnedChromeState() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        XCTAssertTrue(workspace.updatePanelTitle(panelId: panelId, title: "runtime title"))
        workspace.setPanelCustomTitle(panelId: panelId, title: "custom title")
        workspace.setPanelPinned(panelId: panelId, pinned: true)
        workspace.markPanelUnread(panelId)
        let projectionState = workspace.makeTabChromeProjectionState(notificationStore: nil)

        let rendered = workspace.renderTabChrome(
            for: WorkspaceLayout.Tab(
                id: TabID(id: panelId),
                title: "stale title",
                hasCustomTitle: false,
                icon: "wrong.icon",
                iconImageData: Data([0x01]),
                kind: .browser,
                isDirty: true,
                showsNotificationBadge: false,
                isLoading: true,
                isPinned: false
            ),
            using: projectionState
        )

        XCTAssertEqual(rendered.id.id, panelId)
        XCTAssertEqual(rendered.title, "custom title")
        XCTAssertTrue(rendered.hasCustomTitle)
        XCTAssertEqual(rendered.icon, "terminal.fill")
        XCTAssertNil(rendered.iconImageData)
        XCTAssertEqual(rendered.kind, .terminal)
        XCTAssertFalse(rendered.isDirty)
        XCTAssertTrue(rendered.showsNotificationBadge)
        XCTAssertFalse(rendered.isLoading)
        XCTAssertTrue(rendered.isPinned)
    }

    func testRenderTabChromeLeavesUnknownSurfaceUnchanged() {
        let workspace = Workspace()
        let tab = WorkspaceLayout.Tab(
            id: TabID(),
            title: "Placeholder",
            hasCustomTitle: true,
            icon: "questionmark.circle",
            iconImageData: Data([0x02]),
            kind: .markdown,
            isDirty: true,
            showsNotificationBadge: true,
            isLoading: true,
            isPinned: true
        )

        XCTAssertEqual(
            workspace.renderTabChrome(
                for: tab,
                using: workspace.makeTabChromeProjectionState(notificationStore: nil)
            ),
            tab
        )
    }

    func testTabChromeProjectionStateReflectsUpdatedPanelTitle() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        XCTAssertTrue(workspace.updatePanelTitle(panelId: panelId, title: "projected title"))
        let projectionState = workspace.makeTabChromeProjectionState(notificationStore: nil)

        let rendered = workspace.renderTabChrome(
            for: WorkspaceLayout.Tab(id: TabID(id: panelId), title: "stale title"),
            using: projectionState
        )

        XCTAssertEqual(rendered.title, "projected title")
    }

    func testWorkspaceLayoutTabStoresSerializedFallbackFields() {
        let tab = WorkspaceLayout.Tab(
            title: "Fallback title",
            hasCustomTitle: true,
            icon: "globe",
            iconImageData: Data([0xAA]),
            kind: .browser,
            isDirty: true,
            showsNotificationBadge: true,
            isLoading: true,
            isPinned: true
        )

        XCTAssertEqual(tab.title, "Fallback title")
        XCTAssertTrue(tab.hasCustomTitle)
        XCTAssertEqual(tab.icon, "globe")
        XCTAssertEqual(tab.iconImageData, Data([0xAA]))
        XCTAssertEqual(tab.kind, .browser)
        XCTAssertTrue(tab.isDirty)
        XCTAssertTrue(tab.showsNotificationBadge)
        XCTAssertTrue(tab.isLoading)
        XCTAssertTrue(tab.isPinned)
    }

    func testRenderSnapshotProjectsWorkspaceOwnedChromeState() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        workspace.setPanelCustomTitle(panelId: panelId, title: "Snapshot custom title")
        workspace.setPanelPinned(panelId: panelId, pinned: true)
        workspace.markPanelUnread(panelId)
        let snapshot = workspace.makeLayoutRenderSnapshot(
            context: WorkspaceLayoutRenderContext(
                notificationStore: nil,
                isWorkspaceVisible: true,
                isWorkspaceInputActive: true,
                isMinimalMode: false,
                appearance: PanelAppearance(
                    dividerColor: .clear,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                ),
                workspacePortalPriority: 0,
                usesWorkspacePaneOverlay: false,
                showSplitButtons: true
            )
        )

        guard let pane = firstPaneSnapshot(from: snapshot),
              let renderedTab = pane.chrome.tabs.first?.tab else {
            XCTFail("Expected pane snapshot with a rendered tab")
            return
        }

        XCTAssertEqual(renderedTab.id.id, panelId)
        XCTAssertEqual(renderedTab.title, "Snapshot custom title")
        XCTAssertTrue(renderedTab.hasCustomTitle)
        XCTAssertTrue(renderedTab.showsNotificationBadge)
        XCTAssertTrue(renderedTab.isPinned)
        XCTAssertEqual(pane.chrome.selectedTabId, panelId)
    }

    func testTreeSnapshotProjectsWorkspaceOwnedTabTitles() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        XCTAssertTrue(workspace.updatePanelTitle(panelId: panelId, title: "runtime title"))
        workspace.setPanelCustomTitle(panelId: panelId, title: "custom title")

        guard case .pane(let pane) = workspace.treeSnapshot(),
              let tab = pane.tabs.first else {
            XCTFail("Expected pane tree snapshot with one tab")
            return
        }

        XCTAssertEqual(tab.id, panelId.uuidString)
        XCTAssertEqual(tab.title, "custom title")
    }

    func testRenderSnapshotUsesWorkspaceSelectedPaneContent() throws {
        let workspace = Workspace()
        let fileURL = try temporaryMarkdownFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        guard let paneId = workspace.paneIds.first,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial pane and focused panel")
            return
        }

        let result = workspace.performLayoutCommand(
            .createMarkdown(inPane: paneId, filePath: fileURL.path, focus: false)
        )
        guard let markdownPanel = result.markdownPanel else {
            XCTFail("Expected markdown panel")
            return
        }

        let context = WorkspaceLayoutRenderContext(
            notificationStore: nil,
            isWorkspaceVisible: true,
            isWorkspaceInputActive: true,
            isMinimalMode: false,
            appearance: PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            workspacePortalPriority: 0,
            usesWorkspacePaneOverlay: false,
            showSplitButtons: true
        )

        let initialSnapshot = workspace.makeLayoutRenderSnapshot(context: context)
        guard let initialPane = firstPaneSnapshot(from: initialSnapshot) else {
            XCTFail("Expected pane snapshot")
            return
        }
        XCTAssertEqual(initialPane.chrome.tabs.count, 2)
        XCTAssertEqual(initialPane.contentId, terminalPanelId)
        if case .terminal = initialPane.content {
        } else {
            XCTFail("Expected selected terminal content to be emitted in the pane snapshot")
        }
        XCTAssertNil(viewport(in: initialSnapshot, for: paneId))

        XCTAssertTrue(workspace.selectSurface(markdownPanel.id))

        let markdownSnapshot = workspace.makeLayoutRenderSnapshot(context: context)
        guard let markdownPane = firstPaneSnapshot(from: markdownSnapshot) else {
            XCTFail("Expected pane snapshot after selecting markdown")
            return
        }
        guard let markdownViewport = viewport(in: markdownSnapshot, for: paneId) else {
            XCTFail("Expected viewport snapshot after selecting markdown")
            return
        }
        XCTAssertEqual(markdownPane.chrome.tabs.count, 2)
        XCTAssertEqual(markdownPane.contentId, markdownPanel.id)
        if case .markdown = markdownPane.content {
        } else {
            XCTFail("Expected selected markdown content to be emitted in the pane snapshot")
        }
        XCTAssertEqual(markdownViewport.contentId, markdownPanel.id)
        if case .markdown = markdownViewport.content {
        } else {
            XCTFail("Expected selected markdown content to be emitted")
        }
    }

    func testHiddenWorkspaceRenderSnapshotKeepsMarkdownViewport() throws {
        let workspace = Workspace()
        let fileURL = try temporaryMarkdownFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        guard let paneId = workspace.paneIds.first else {
            XCTFail("Expected initial pane")
            return
        }

        let result = workspace.performLayoutCommand(
            .createMarkdown(inPane: paneId, filePath: fileURL.path, focus: true)
        )
        guard let markdownPanel = result.markdownPanel else {
            XCTFail("Expected markdown panel")
            return
        }

        let context = WorkspaceLayoutRenderContext(
            notificationStore: nil,
            isWorkspaceVisible: false,
            isWorkspaceInputActive: false,
            isMinimalMode: false,
            appearance: PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            workspacePortalPriority: 0,
            usesWorkspacePaneOverlay: false,
            showSplitButtons: true
        )

        let snapshot = workspace.makeLayoutRenderSnapshot(context: context)
        guard let markdownViewport = viewport(in: snapshot, for: paneId) else {
            XCTFail("Expected hidden workspace to keep the selected markdown viewport mounted")
            return
        }

        XCTAssertEqual(markdownViewport.contentId, markdownPanel.id)
        if case .markdown = markdownViewport.content {
        } else {
            XCTFail("Expected selected markdown viewport content")
        }
    }

    func testUnreadPaneRingSettingGatesTerminalContentDescriptor() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: NotificationPaneRingSettings.enabledKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: NotificationPaneRingSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: NotificationPaneRingSettings.enabledKey)
            }
        }

        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused terminal")
            return
        }

        let notificationStore = TerminalNotificationStore.shared
        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }
        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Unread",
            subtitle: "",
            body: "Unread terminal"
        )

        func terminalContentWhenRingSetting(enabled: Bool) -> WorkspaceTerminalPaneContent? {
            defaults.set(enabled, forKey: NotificationPaneRingSettings.enabledKey)
            let context = WorkspaceLayoutRenderContext(
                notificationStore: notificationStore,
                isWorkspaceVisible: true,
                isWorkspaceInputActive: true,
                isMinimalMode: false,
                appearance: PanelAppearance(
                    dividerColor: .clear,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                ),
                workspacePortalPriority: 0,
                usesWorkspacePaneOverlay: false,
                showSplitButtons: true
            )
            guard let pane = firstPaneSnapshot(from: workspace.makeLayoutRenderSnapshot(context: context)),
                  case .terminal(let content) = pane.content else {
                return nil
            }
            return content
        }

        XCTAssertTrue(terminalContentWhenRingSetting(enabled: true)?.hasUnreadNotification == true)
        XCTAssertTrue(terminalContentWhenRingSetting(enabled: false)?.hasUnreadNotification == false)
    }

    func testSelectedBrowserRenderSnapshotOmitsViewportAndUsesDirectPaneContent() {
        let workspace = Workspace()
        guard let paneId = workspace.paneIds.first,
              let browserPanel = workspace.createBrowserPanel(
                inPane: paneId,
                url: URL(string: "about:blank"),
                focus: false
              ) else {
            XCTFail("Expected browser panel")
            return
        }

        XCTAssertTrue(workspace.selectSurface(browserPanel.id))

        let snapshot = workspace.makeLayoutRenderSnapshot(
            context: WorkspaceLayoutRenderContext(
                notificationStore: nil,
                isWorkspaceVisible: true,
                isWorkspaceInputActive: true,
                isMinimalMode: false,
                appearance: PanelAppearance(
                    dividerColor: .clear,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                ),
                workspacePortalPriority: 0,
                usesWorkspacePaneOverlay: false,
                showSplitButtons: true
            )
        )

        guard let pane = firstPaneSnapshot(from: snapshot) else {
            XCTFail("Expected pane snapshot")
            return
        }
        XCTAssertEqual(pane.contentId, browserPanel.id)
        if case .browser = pane.content {
        } else {
            XCTFail("Expected selected browser content in the pane snapshot")
        }
        XCTAssertNil(viewport(in: snapshot, for: paneId))
    }

    func testRootHostMountsSelectedTerminalDirectlyInPaneHost() throws {
        _ = NSApplication.shared

        let workspace = Workspace()
        guard let paneId = workspace.focusedPaneId,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal pane")
            return
        }

        let renderContext = WorkspaceLayoutRenderContext(
            notificationStore: nil,
            isWorkspaceVisible: true,
            isWorkspaceInputActive: true,
            isMinimalMode: false,
            appearance: PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            workspacePortalPriority: 0,
            usesWorkspacePaneOverlay: false,
            showSplitButtons: true
        )
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
            surfaceRegistry: workspace.surfaceRegistry
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        rootHost.frame = contentView.bounds
        rootHost.autoresizingMask = [.width, .height]
        contentView.addSubview(rootHost)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        rootHost.layoutSubtreeIfNeeded()

        let mountedExpectation = expectation(description: "terminal mounted directly")
        func pollMounted() {
            if panel.hostedView.window === window &&
                panel.hostedView.superview != nil &&
                !panel.hostedView.isHidden {
                mountedExpectation.fulfill()
            } else {
                DispatchQueue.main.async {
                    pollMounted()
                }
            }
        }
        pollMounted()
        wait(for: [mountedExpectation], timeout: 2.0)

        XCTAssertTrue(rootHost.debugPaneUsesDirectTerminalHost(paneId))
        XCTAssertFalse(rootHost.debugViewportMountIdentities.contains(WorkspacePaneMountIdentity.terminal(panel.id)))
    }

    func testRootHostMountsSelectedBrowserDirectlyInPaneHostBelowTabBar() throws {
        _ = NSApplication.shared

        let workspace = Workspace()
        guard let paneId = workspace.focusedPaneId,
              let browserPanel = workspace.createBrowserPanel(
                inPane: paneId,
                url: URL(string: "about:blank"),
                focus: true
              ) else {
            XCTFail("Expected focused browser pane")
            return
        }

        let renderContext = WorkspaceLayoutRenderContext(
            notificationStore: nil,
            isWorkspaceVisible: true,
            isWorkspaceInputActive: true,
            isMinimalMode: false,
            appearance: PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            workspacePortalPriority: 0,
            usesWorkspacePaneOverlay: false,
            showSplitButtons: true
        )
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
            surfaceRegistry: workspace.surfaceRegistry
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        rootHost.frame = contentView.bounds
        rootHost.autoresizingMask = [.width, .height]
        contentView.addSubview(rootHost)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        rootHost.layoutSubtreeIfNeeded()

        let mountedExpectation = expectation(description: "browser pane mounted directly")
        func pollMounted() {
            if rootHost.debugPaneMountedDirectContentIdentity(paneId) == .browser(browserPanel.id) &&
                rootHost.debugPaneDirectContentBounds(paneId).height > 0 {
                mountedExpectation.fulfill()
            } else {
                DispatchQueue.main.async {
                    pollMounted()
                }
            }
        }
        pollMounted()
        wait(for: [mountedExpectation], timeout: 2.0)

        XCTAssertEqual(rootHost.debugPaneMountedDirectContentIdentity(paneId), .browser(browserPanel.id))
        XCTAssertFalse(rootHost.debugViewportMountIdentities.contains(WorkspacePaneMountIdentity.browser(browserPanel.id)))
        XCTAssertNotEqual(
            BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)?.visibleInUI,
            true,
            "Visible browser pane should not still be presented through the portal path"
        )

        let contentBounds = rootHost.debugPaneDirectContentBounds(paneId)
        let layoutSnapshot = workspace.splitController.layoutSnapshot()
        guard let paneGeometry = layoutSnapshot.panes.first(where: { $0.paneId == paneId.id.uuidString }) else {
            XCTFail("Expected pane geometry")
            return
        }

        let paneFrame = CGRect(
            x: CGFloat(paneGeometry.frame.x) - CGFloat(layoutSnapshot.containerFrame.x),
            y: CGFloat(paneGeometry.frame.y) - CGFloat(layoutSnapshot.containerFrame.y),
            width: CGFloat(paneGeometry.frame.width),
            height: CGFloat(paneGeometry.frame.height)
        )
        let expectedHeight = max(
            0,
            paneFrame.height - min(
                workspace.splitController.configuration.appearance.tabBarHeight,
                max(0, paneFrame.height - 1)
            )
        )

        XCTAssertEqual(contentBounds.width, paneFrame.width, accuracy: 0.001)
        XCTAssertEqual(contentBounds.height, expectedHeight, accuracy: 0.001)
    }

    func testHiddenWorkspaceRenderSnapshotOmitsViewportMounts() {
        let workspace = Workspace()

        let snapshot = workspace.makeLayoutRenderSnapshot(
            context: WorkspaceLayoutRenderContext(
                notificationStore: nil,
                isWorkspaceVisible: false,
                isWorkspaceInputActive: false,
                isMinimalMode: false,
                appearance: PanelAppearance(
                    dividerColor: .clear,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                ),
                workspacePortalPriority: 0,
                usesWorkspacePaneOverlay: false,
                showSplitButtons: true
            )
        )

        XCTAssertTrue(snapshot.viewports.isEmpty)
        XCTAssertNotNil(firstPaneSnapshot(from: snapshot))
    }

    func testRenderSnapshotCarriesSplitGeometryFromControllerState() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        let context = WorkspaceLayoutRenderContext(
            notificationStore: nil,
            isWorkspaceVisible: true,
            isWorkspaceInputActive: true,
            isMinimalMode: false,
            appearance: PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            workspacePortalPriority: 0,
            usesWorkspacePaneOverlay: false,
            showSplitButtons: true
        )

        let result = workspace.performLayoutCommand(
            .splitTerminal(fromPanelId: panelId, orientation: .horizontal)
        )
        XCTAssertNotNil(result.terminalPanel, "Expected split terminal panel")

        let initialSnapshot = workspace.makeLayoutRenderSnapshot(context: context)
        guard let split = firstSplitSnapshot(from: initialSnapshot) else {
            XCTFail("Expected split root snapshot after splitting")
            return
        }

        XCTAssertEqual(split.orientation, .horizontal)
        XCTAssertEqual(split.dividerPosition, 0.5, accuracy: 0.001)
        XCTAssertEqual(split.animationOrigin, .fromSecond)

        workspace.consumeSplitEntryAnimation(split.splitId)
        let consumedSnapshot = workspace.makeLayoutRenderSnapshot(context: context)
        XCTAssertNil(
            firstSplitSnapshot(from: consumedSnapshot)?.animationOrigin,
            "Expected the render snapshot to stop carrying consumed split-entry animation state"
        )

        XCTAssertTrue(workspace.setDividerPosition(0.33, forSplit: split.splitId))
        let resizedSnapshot = workspace.makeLayoutRenderSnapshot(context: context)
        let resizedDividerPosition = try XCTUnwrap(
            firstSplitSnapshot(from: resizedSnapshot)?.dividerPosition,
            "Expected divider position in resized split snapshot"
        )
        XCTAssertEqual(Double(resizedDividerPosition), 0.33, accuracy: 0.001)
    }

    func testRenderSnapshotCarriesPresentationStateFromWorkspace() throws {
        let workspace = Workspace()
        guard let paneId = workspace.paneIds.first,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial pane and focused panel")
            return
        }

        workspace.tabBarLeadingInset = 19
        workspace.layoutInteractionHandlers.beginTabDrag(tabId: TabID(id: panelId), sourcePaneId: paneId)

        let snapshot = workspace.makeLayoutRenderSnapshot(
            context: WorkspaceLayoutRenderContext(
                notificationStore: nil,
                isWorkspaceVisible: true,
                isWorkspaceInputActive: false,
                isMinimalMode: true,
                appearance: PanelAppearance(
                    dividerColor: .clear,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                ),
                workspacePortalPriority: 0,
                usesWorkspacePaneOverlay: false,
                showSplitButtons: true
            )
        )

        XCTAssertFalse(snapshot.presentation.isInteractive)
        XCTAssertTrue(snapshot.presentation.isMinimalMode)
        XCTAssertEqual(snapshot.presentation.appearance.tabBarLeadingInset, 19, accuracy: 0.001)
        XCTAssertEqual(snapshot.presentation.localTabDrag?.tabId, TabID(id: panelId))
        XCTAssertEqual(snapshot.presentation.localTabDrag?.sourcePaneId, paneId)

        workspace.layoutInteractionHandlers.clearDragState()
        let clearedSnapshot = workspace.makeLayoutRenderSnapshot(
            context: WorkspaceLayoutRenderContext(
                notificationStore: nil,
                isWorkspaceVisible: true,
                isWorkspaceInputActive: true,
                isMinimalMode: false,
                appearance: PanelAppearance(
                    dividerColor: .clear,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                ),
                workspacePortalPriority: 0,
                usesWorkspacePaneOverlay: false,
                showSplitButtons: true
            )
        )
        XCTAssertNil(clearedSnapshot.presentation.localTabDrag)
    }

    func testRootHostPropagatesLocalTabDragImmediatelyWithoutSnapshotRefresh() throws {
        let workspace = Workspace()
        guard let paneId = workspace.focusedPaneId,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused pane and panel")
            return
        }

        let renderContext = WorkspaceLayoutRenderContext(
            notificationStore: nil,
            isWorkspaceVisible: true,
            isWorkspaceInputActive: true,
            isMinimalMode: false,
            appearance: PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            workspacePortalPriority: 0,
            usesWorkspacePaneOverlay: false,
            showSplitButtons: true
        )
        let renderSnapshot = workspace.makeLayoutRenderSnapshot(
            context: renderContext
        )
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: renderSnapshot,
            surfaceRegistry: workspace.surfaceRegistry
        )

        XCTAssertNil(rootHost.debugPaneLocalTabDrag(paneId))

        let draggedTabId = TabID(id: panelId)
        let expectedDrag = WorkspaceLayoutLocalDragSnapshot(
            tabId: draggedTabId,
            sourcePaneId: paneId
        )
        rootHost.debugBeginLocalTabDrag(tabId: draggedTabId, sourcePaneId: paneId)

        XCTAssertEqual(rootHost.debugPaneLocalTabDrag(paneId), expectedDrag)
        XCTAssertEqual(workspace.makeLayoutRenderSnapshot(context: renderContext).presentation.localTabDrag, expectedDrag)

        rootHost.debugClearLocalTabDrag()

        XCTAssertNil(rootHost.debugPaneLocalTabDrag(paneId))
        XCTAssertNil(workspace.makeLayoutRenderSnapshot(context: renderContext).presentation.localTabDrag)
    }

    func testEffectiveTabDropTargetIndexRejectsSamePaneNoOpReorderTargets() {
        let paneId = PaneID(id: UUID())
        let firstTabId = TabID(id: UUID())
        let secondTabId = TabID(id: UUID())
        let thirdTabId = TabID(id: UUID())
        let localDrag = WorkspaceLayoutLocalDragSnapshot(
            tabId: secondTabId,
            sourcePaneId: paneId
        )

        XCTAssertNil(
            workspaceLayoutEffectiveTabDropTargetIndex(
                rawTargetIndex: 1,
                tabIds: [firstTabId, secondTabId, thirdTabId],
                paneId: paneId,
                localTabDrag: localDrag
            )
        )
        XCTAssertNil(
            workspaceLayoutEffectiveTabDropTargetIndex(
                rawTargetIndex: 2,
                tabIds: [firstTabId, secondTabId, thirdTabId],
                paneId: paneId,
                localTabDrag: localDrag
            )
        )
        XCTAssertEqual(
            workspaceLayoutEffectiveTabDropTargetIndex(
                rawTargetIndex: 0,
                tabIds: [firstTabId, secondTabId, thirdTabId],
                paneId: paneId,
                localTabDrag: localDrag
            ),
            0
        )
        XCTAssertEqual(
            workspaceLayoutEffectiveTabDropTargetIndex(
                rawTargetIndex: 3,
                tabIds: [firstTabId, secondTabId, thirdTabId],
                paneId: paneId,
                localTabDrag: localDrag
            ),
            3
        )
    }

    func testPaneDropOverlayCoordinatorTransitionsVisibleToHidingOnlyOnceOnClear() {
        let paneId = PaneID(id: UUID())
        var coordinator = WorkspacePaneDropOverlayCoordinator()

        XCTAssertTrue(coordinator.setZone(.left, for: paneId))
        let visiblePresentation = coordinator.overlayPresentation(for: paneId)
        XCTAssertEqual(visiblePresentation.phase, .visible)
        XCTAssertEqual(visiblePresentation.zone, .left)
        XCTAssertEqual(coordinator.activeDropZone(for: paneId), .left)

        XCTAssertTrue(coordinator.clearZone(for: paneId))
        let hidingPresentation = coordinator.overlayPresentation(for: paneId)
        XCTAssertEqual(hidingPresentation.phase, .hiding)
        XCTAssertEqual(hidingPresentation.zone, .left)
        XCTAssertNil(coordinator.activeDropZone(for: paneId))

        XCTAssertFalse(coordinator.clearZone(for: paneId))
        XCTAssertEqual(coordinator.overlayPresentation(for: paneId), hidingPresentation)
    }

    func testPaneDropOverlayCoordinatorIgnoresStaleHideCompletion() {
        let paneId = PaneID(id: UUID())
        var coordinator = WorkspacePaneDropOverlayCoordinator()

        XCTAssertTrue(coordinator.setZone(.right, for: paneId))
        XCTAssertTrue(coordinator.clearZone(for: paneId))
        let hidingPresentation = coordinator.overlayPresentation(for: paneId)

        XCTAssertFalse(coordinator.completeHide(for: paneId, generation: hidingPresentation.generation + 1))
        XCTAssertEqual(coordinator.overlayPresentation(for: paneId), hidingPresentation)

        XCTAssertTrue(coordinator.completeHide(for: paneId, generation: hidingPresentation.generation))
        XCTAssertEqual(coordinator.overlayPresentation(for: paneId), .hidden)
    }

    func testPaneDropOverlayCoordinatorClearsImmediatelyOnSuccessfulDrop() {
        let paneId = PaneID(id: UUID())
        var coordinator = WorkspacePaneDropOverlayCoordinator()

        XCTAssertTrue(coordinator.setZone(.right, for: paneId))
        let visiblePresentation = coordinator.overlayPresentation(for: paneId)
        XCTAssertEqual(visiblePresentation.phase, .visible)
        XCTAssertEqual(visiblePresentation.zone, .right)

        XCTAssertTrue(coordinator.clearZoneImmediately(for: paneId))
        XCTAssertEqual(coordinator.overlayPresentation(for: paneId), .hidden)
        XCTAssertNil(coordinator.activeDropZone(for: paneId))
    }

    func testRenderSnapshotProjectsContextMenuStateFromWorkspaceFacts() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        let result = workspace.performLayoutCommand(
            .splitTerminal(fromPanelId: panelId, orientation: .horizontal)
        )
        XCTAssertNotNil(result.terminalPanel, "Expected split terminal panel")

        let snapshot = workspace.makeLayoutRenderSnapshot(
            context: WorkspaceLayoutRenderContext(
                notificationStore: nil,
                isWorkspaceVisible: true,
                isWorkspaceInputActive: true,
                isMinimalMode: false,
                appearance: PanelAppearance(
                    dividerColor: .clear,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                ),
                workspacePortalPriority: 0,
                usesWorkspacePaneOverlay: false,
                showSplitButtons: true
            )
        )

        guard let split = firstSplitSnapshot(from: snapshot),
              case .pane(let firstPane) = split.first,
              case .pane(let secondPane) = split.second,
              let firstContext = firstPane.chrome.tabs.first?.contextMenuState,
              let secondContext = secondPane.chrome.tabs.first?.contextMenuState else {
            XCTFail("Expected split snapshot with pane-level context menu state")
            return
        }

        XCTAssertTrue(firstContext.hasSplits)
        XCTAssertTrue(secondContext.hasSplits)
        XCTAssertFalse(firstContext.canMoveToLeftPane)
        XCTAssertTrue(firstContext.canMoveToRightPane)
        XCTAssertTrue(secondContext.canMoveToLeftPane)
        XCTAssertFalse(secondContext.canMoveToRightPane)
        XCTAssertFalse(firstContext.isZoomed)
        XCTAssertFalse(secondContext.isZoomed)
    }

    func testProgrammaticDividerUpdatePublishesCachedGeometrySnapshot() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        let result = workspace.performLayoutCommand(
            .splitTerminal(fromPanelId: panelId, orientation: .horizontal)
        )
        XCTAssertNotNil(result.terminalPanel, "Expected split terminal panel")

        let renderSnapshot = workspace.makeLayoutRenderSnapshot(
            context: WorkspaceLayoutRenderContext(
                notificationStore: nil,
                isWorkspaceVisible: true,
                isWorkspaceInputActive: true,
                isMinimalMode: false,
                appearance: PanelAppearance(
                    dividerColor: .clear,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                ),
                workspacePortalPriority: 0,
                usesWorkspacePaneOverlay: false,
                showSplitButtons: true
            )
        )
        let splitId = try XCTUnwrap(
            firstSplitSnapshot(from: renderSnapshot)?.splitId,
            "Expected split snapshot"
        )

        workspace.layoutInteractionHandlers.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))
        workspace.layoutInteractionHandlers.notifyGeometryChange(isDragging: false)

        let baselineSnapshot = try XCTUnwrap(
            workspace.tmuxLayoutSnapshot,
            "Expected cached geometry snapshot after initial publish"
        )
        let baselineFrames = Dictionary(
            baselineSnapshot.panes.map { ($0.paneId, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )

        XCTAssertTrue(workspace.setDividerPosition(0.33, forSplit: splitId))

        let updatedSnapshot = try XCTUnwrap(
            workspace.tmuxLayoutSnapshot,
            "Expected cached geometry snapshot after divider update"
        )
        XCTAssertEqual(updatedSnapshot.panes.count, 2)
        XCTAssertTrue(
            updatedSnapshot.panes.contains { pane in
                guard let baselineFrame = baselineFrames[pane.paneId] else { return false }
                return pane.frame != baselineFrame
            },
            "Expected divider update to publish new pane geometry"
        )
    }

    func testPerformLayoutCommandSplitTerminalCreatesSecondPane() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        let result = workspace.performLayoutCommand(
            .splitTerminal(fromPanelId: panelId, orientation: .horizontal)
        )

        guard let newPanel = result.terminalPanel else {
            XCTFail("Expected split terminal panel")
            return
        }

        XCTAssertNotEqual(newPanel.id, panelId)
        XCTAssertNotNil(workspace.panels[newPanel.id])
        XCTAssertEqual(workspace.paneCount, 2)
    }

    func testPerformLayoutCommandCreateMarkdownCreatesPanelInPane() throws {
        let workspace = Workspace()
        let fileURL = try temporaryMarkdownFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        guard let paneId = workspace.paneIds.first else {
            XCTFail("Expected pane in new workspace")
            return
        }

        let result = workspace.performLayoutCommand(
            .createMarkdown(inPane: paneId, filePath: fileURL.path, focus: false)
        )

        guard let panel = result.markdownPanel else {
            XCTFail("Expected markdown panel")
            return
        }

        XCTAssertEqual(panel.filePath, fileURL.path)
        XCTAssertNotNil(workspace.panels[panel.id])
        XCTAssertEqual(workspace.paneId(forPanelId: panel.id), paneId)
    }

    func testPerformLayoutCommandSplitMarkdownCreatesSecondPane() throws {
        let workspace = Workspace()
        let fileURL = try temporaryMarkdownFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        let result = workspace.performLayoutCommand(
            .splitMarkdown(fromPanelId: panelId, orientation: .horizontal, filePath: fileURL.path)
        )

        guard let panel = result.markdownPanel else {
            XCTFail("Expected split markdown panel")
            return
        }

        XCTAssertEqual(panel.filePath, fileURL.path)
        XCTAssertNotEqual(panel.id, panelId)
        XCTAssertNotNil(workspace.panels[panel.id])
        XCTAssertEqual(workspace.paneCount, 2)
    }

    func testLayoutControllerPaneReadsAreValueCopies() throws {
        let initialPane = PaneState(tabIds: [UUID()])
        let controller = WorkspaceLayoutController(rootNode: .pane(initialPane))
        let paneId = try XCTUnwrap(controller.allPaneIds.first, "Expected initial pane")
        let stalePane = try XCTUnwrap(controller.rootNode.findPane(paneId), "Expected pane snapshot")

        _ = controller.createTab(title: "two", inPane: paneId, select: false)

        XCTAssertEqual(stalePane.tabIds.count, 1)
        XCTAssertEqual(controller.tabIds(inPane: paneId).count, 2)
    }

    func testLayoutControllerSplitReadsAreValueCopies() throws {
        let initialPane = PaneState(tabIds: [UUID()])
        let controller = WorkspaceLayoutController(rootNode: .pane(initialPane))
        let paneId = try XCTUnwrap(controller.allPaneIds.first, "Expected initial pane")
        let newPaneId = controller.splitPane(paneId, orientation: .horizontal)

        XCTAssertNotNil(newPaneId, "Expected split to succeed")

        guard case .split(let liveSplit) = controller.rootNode else {
            XCTFail("Expected split root after splitting")
            return
        }

        let splitId = liveSplit.id
        let staleSplit = try XCTUnwrap(controller.rootNode.findSplit(splitId), "Expected split snapshot")

        XCTAssertTrue(controller.setDividerPosition(0.33, forSplit: splitId))

        XCTAssertEqual(staleSplit.dividerPosition, 0.5, accuracy: 0.001)
        let liveDividerPosition = try XCTUnwrap(
            controller.rootNode.findSplit(splitId)?.dividerPosition,
            "Expected updated divider position"
        )
        XCTAssertEqual(Double(liveDividerPosition), 0.33, accuracy: 0.001)
    }

    func testLayoutControllerSplitPaneReturnsNilForUnknownPaneId() throws {
        let initialPane = PaneState(tabIds: [UUID()])
        let controller = WorkspaceLayoutController(rootNode: .pane(initialPane))
        let stalePaneId = PaneID(id: UUID())

        XCTAssertNil(controller.splitPane(stalePaneId, orientation: .horizontal))
        XCTAssertEqual(controller.allPaneIds.count, 1)
    }

    func testLayoutControllerSplitPaneWithTabReturnsNilForUnknownPaneId() throws {
        let existingTabId = UUID()
        let initialPane = PaneState(tabIds: [existingTabId], selectedTabId: existingTabId)
        let controller = WorkspaceLayoutController(rootNode: .pane(initialPane))
        let stalePaneId = PaneID(id: UUID())
        let newTabId = TabID(id: UUID())

        XCTAssertNil(
            controller.splitPane(
                stalePaneId,
                orientation: .horizontal,
                withTabId: newTabId,
                insertFirst: false
            )
        )
        let paneId = try XCTUnwrap(controller.allPaneIds.first)
        XCTAssertEqual(controller.tabIds(inPane: paneId), [TabID(id: existingTabId)])
    }

    func testLayoutControllerClosePaneReturnsFalseForUnknownPaneId() throws {
        let leftPane = PaneState(tabIds: [UUID()])
        let rightPane = PaneState(tabIds: [UUID()])
        let controller = WorkspaceLayoutController(
            rootNode: .split(
                SplitState(
                    orientation: .horizontal,
                    first: .pane(leftPane),
                    second: .pane(rightPane)
                )
            )
        )

        XCTAssertFalse(controller.closePane(PaneID(id: UUID())))
        XCTAssertEqual(Set(controller.allPaneIds), Set([leftPane.id, rightPane.id]))
    }

    func testLayoutControllerStartsWithGenuinelyEmptyPane() throws {
        let controller = WorkspaceLayoutController()
        let paneId = try XCTUnwrap(controller.allPaneIds.first, "Expected initial pane")

        XCTAssertEqual(controller.allPaneIds.count, 1)
        XCTAssertTrue(controller.tabIds(inPane: paneId).isEmpty)
        XCTAssertNil(controller.selectedTabId(inPane: paneId))
        XCTAssertTrue(controller.allTabIds.isEmpty)
    }

    func testMovingOnlyTabIntoSplitLeavesSourcePaneEmpty() throws {
        let surfaceId = UUID()
        let paneId = PaneID()
        let controller = WorkspaceLayoutController(
            rootNode: .pane(
                PaneState(
                    id: paneId,
                    tabIds: [surfaceId],
                    selectedTabId: surfaceId
                )
            )
        )

        let newPaneId = try XCTUnwrap(
            controller.splitPane(
                paneId,
                orientation: .horizontal,
                movingTab: TabID(id: surfaceId),
                insertFirst: false
            ),
            "Expected split to succeed"
        )

        XCTAssertTrue(controller.tabIds(inPane: paneId).isEmpty)
        XCTAssertNil(controller.selectedTabId(inPane: paneId))
        XCTAssertEqual(controller.tabIds(inPane: newPaneId), [TabID(id: surfaceId)])
        XCTAssertEqual(controller.allTabIds, [TabID(id: surfaceId)])
    }

    func testMovingTabSplitRejectsUnknownTargetAndPreservesSourcePane() throws {
        let surfaceId = UUID()
        let sourcePaneId = PaneID()
        let controller = WorkspaceLayoutController(
            rootNode: .pane(
                PaneState(
                    id: sourcePaneId,
                    tabIds: [surfaceId],
                    selectedTabId: surfaceId
                )
            )
        )
        let staleTargetPaneId = PaneID(id: UUID())

        XCTAssertNil(
            controller.splitPane(
                staleTargetPaneId,
                orientation: .horizontal,
                movingTab: TabID(id: surfaceId),
                insertFirst: false
            )
        )

        XCTAssertEqual(controller.allPaneIds, [sourcePaneId])
        XCTAssertEqual(controller.tabIds(inPane: sourcePaneId), [TabID(id: surfaceId)])
        XCTAssertEqual(controller.selectedTabId(inPane: sourcePaneId), TabID(id: surfaceId))
    }

    func testWorkspaceLayoutRemoveSubviewIfOwnedPreservesReparentedChild() {
        let oldContainer = NSView(frame: .zero)
        let newContainer = NSView(frame: .zero)
        let child = NSView(frame: .zero)
        newContainer.addSubview(child)

        workspaceLayoutRemoveSubviewIfOwned(child, from: oldContainer)

        XCTAssertTrue(child.superview === newContainer)

        workspaceLayoutRemoveSubviewIfOwned(child, from: newContainer)

        XCTAssertNil(child.superview)
    }
}


@MainActor
final class WorkspaceSplitWorkingDirectoryTests: XCTestCase {
    private func waitForCondition(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    private func hostTerminalPanelInWindow(_ panel: TerminalPanel) throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let contentView = try XCTUnwrap(window.contentView, "Expected content view")

        let hostedView = panel.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            waitForCondition {
                panel.surface.surface != nil
            },
            "Expected runtime surface to materialize after hosting panel in a window"
        )
        return window
    }

    func testNewTerminalSplitFallsBackToRequestedWorkingDirectoryWhenReportedDirectoryIsStale() {
        let workspace = Workspace()
        guard let sourcePaneId = workspace.focusedPaneId else {
            XCTFail("Expected focused pane in new workspace")
            return
        }

        let staleCurrentDirectory = workspace.currentDirectory
        let requestedDirectory = "/tmp/cmux-requested-split-cwd-\(UUID().uuidString)"
        guard let sourcePanel = workspace.createTerminalPanel(
            inPane: sourcePaneId,
            focus: false,
            workingDirectory: requestedDirectory
        ) else {
            XCTFail("Expected source terminal panel to be created")
            return
        }

        XCTAssertEqual(sourcePanel.requestedWorkingDirectory, requestedDirectory)
        XCTAssertNil(
            workspace.panelDirectory(panelId: sourcePanel.id),
            "Expected requested cwd to exist before shell integration reports a live cwd"
        )
        XCTAssertEqual(
            workspace.currentDirectory,
            staleCurrentDirectory,
            "Expected focused workspace cwd to remain stale before panel directory updates"
        )

        guard let splitPanel = workspace.splitTerminalPanel(fromPanelId: sourcePanel.id,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected split terminal panel to be created")
            return
        }

        XCTAssertEqual(
            splitPanel.requestedWorkingDirectory,
            requestedDirectory,
            "Expected split to inherit the source terminal's requested cwd when no reported cwd exists yet"
        )
    }

    func testNewTerminalSplitSkipsFreedInheritedSurfacePointer() throws {
#if DEBUG
        let workspace = Workspace()
        guard let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let window = try hostTerminalPanelInWindow(sourcePanel)
        defer { window.orderOut(nil) }

        XCTAssertNotNil(sourcePanel.surface.surface, "Expected runtime surface before forcing stale pointer")

        sourcePanel.surface.replaceSurfaceWithFreedPointerForTesting()
        XCTAssertNotNil(
            sourcePanel.surface.surface,
            "Expected Swift wrapper to remain non-nil while simulating a stale native surface"
        )

        let splitPanel = workspace.splitTerminalPanel(fromPanelId: sourcePanelId,
            orientation: .horizontal,
            focus: false
        )

        XCTAssertNotNil(splitPanel, "Expected split creation to survive a stale inherited surface pointer")
        XCTAssertNil(sourcePanel.surface.surface, "Expected stale surface pointer to be quarantined")
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testNewTerminalSurfaceSkipsFreedInheritedSurfacePointer() throws {
#if DEBUG
        let workspace = Workspace()
        guard let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId),
              let sourcePaneId = workspace.paneId(forPanelId: sourcePanelId) else {
            XCTFail("Expected focused terminal panel and pane")
            return
        }

        let window = try hostTerminalPanelInWindow(sourcePanel)
        defer { window.orderOut(nil) }

        XCTAssertNotNil(sourcePanel.surface.surface, "Expected runtime surface before forcing stale pointer")

        sourcePanel.surface.replaceSurfaceWithFreedPointerForTesting()
        XCTAssertNotNil(
            sourcePanel.surface.surface,
            "Expected Swift wrapper to remain non-nil while simulating a stale native surface"
        )

        let createdPanel = workspace.createTerminalPanel(
            inPane: sourcePaneId,
            focus: false
        )

        XCTAssertNotNil(createdPanel, "Expected terminal creation to survive a stale inherited surface pointer")
        XCTAssertNil(sourcePanel.surface.surface, "Expected stale surface pointer to be quarantined")
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}

@MainActor
final class WorkspaceSurfaceRegistryTests: XCTestCase {
    private func waitForCondition(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    private func makeRenderContext() -> WorkspaceLayoutRenderContext {
        WorkspaceLayoutRenderContext(
            notificationStore: nil,
            isWorkspaceVisible: true,
            isWorkspaceInputActive: true,
            isMinimalMode: false,
            appearance: PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            workspacePortalPriority: 0,
            usesWorkspacePaneOverlay: false,
            showSplitButtons: true
        )
    }

    private func terminalDescriptor(for panelId: UUID) -> WorkspaceTerminalPaneContent {
        WorkspaceTerminalPaneContent(
            surfaceId: panelId,
            isFocused: true,
            isVisibleInUI: true,
            isSplit: false,
            appearance: WorkspaceTerminalPaneAppearance(PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            )),
            hasUnreadNotification: false,
            onFocus: {},
            onTriggerFlash: {}
        )
    }

    private func browserDescriptor(
        for panelId: UUID,
        paneId: PaneID
    ) -> WorkspaceBrowserPaneContent {
        WorkspaceBrowserPaneContent(
            surfaceId: panelId,
            paneId: paneId,
            isFocused: true,
            isVisibleInUI: true,
            prefersLocalInlineHosting: true,
            portalPriority: 0,
            onRequestPanelFocus: {}
        )
    }

    private func markdownDescriptor(for panelId: UUID) -> WorkspaceMarkdownPaneContent {
        WorkspaceMarkdownPaneContent(
            surfaceId: panelId,
            isVisibleInUI: true,
            onRequestPanelFocus: {}
        )
    }

    private func placeholderDescriptor(paneId: PaneID = PaneID()) -> WorkspacePlaceholderPaneContent {
        WorkspacePlaceholderPaneContent(
            paneId: paneId,
            onCreateTerminal: {},
            onCreateBrowser: {}
        )
    }

    private func temporaryMarkdownFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("note.md")
        try "# retained markdown host\n".write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func testOffWindowTerminalMountKeepsHostedViewInstalled() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let slotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )

        workspace.surfaceRegistry.mountContent(
            .terminal(terminalDescriptor(for: panel.id)),
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )

        XCTAssertTrue(
            panel.hostedView.superview === slotView,
            "Expected off-window mount to keep the terminal hosted view installed instead of leaving the pane empty"
        )
        XCTAssertFalse(slotView.isHidden)
        XCTAssertNil(
            panel.surface.surface,
            "Expected runtime surface attachment to remain deferred until the host enters a window"
        )
    }

    func testTerminalMountAttachesAfterWindowEntryRefresh() throws {
        _ = NSApplication.shared

        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let slotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )
        let descriptor = terminalDescriptor(for: panel.id)

        workspace.surfaceRegistry.mountContent(
            .terminal(descriptor),
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )
        XCTAssertNil(panel.surface.surface)

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        slotView.frame = contentView.bounds
        slotView.autoresizingMask = [.width, .height]
        contentView.addSubview(slotView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        slotView.layoutSubtreeIfNeeded()

        workspace.surfaceRegistry.mountContent(
            .terminal(descriptor),
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )

        XCTAssertTrue(
            waitForCondition {
                panel.hostedView.window === window &&
                panel.hostedView.superview === slotView &&
                !panel.hostedView.isHidden
            },
            "Expected the retained terminal host to stay attached and visible after entering a window"
        )
        XCTAssertTrue(panel.hostedView.window === window)
        XCTAssertTrue(panel.hostedView.superview === slotView)
        XCTAssertFalse(panel.hostedView.isHidden)
    }

    func testTerminalViewportLifecycleReconcileCreatesRuntimeAfterWindowEntry() throws {
        _ = NSApplication.shared

        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let slotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )
        let descriptor = terminalDescriptor(for: panel.id)

        workspace.surfaceRegistry.mountContent(
            .terminal(descriptor),
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )

        XCTAssertNil(panel.surface.surface)

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        slotView.frame = contentView.bounds
        slotView.autoresizingMask = [.width, .height]
        contentView.addSubview(slotView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        slotView.layoutSubtreeIfNeeded()

        workspace.surfaceRegistry.reconcileViewportLifecycle(
            .terminal(descriptor),
            contentId: panel.id,
            in: slotView,
            reason: "test.windowEntry"
        )

        XCTAssertTrue(
            waitForCondition { panel.surface.surface != nil },
            "Expected viewport lifecycle reconcile to create the runtime surface once the host entered a window"
        )
    }

    func testTerminalViewportLifecycleReconcileDefersRuntimeUntilGeometryIsUsable() throws {
        _ = NSApplication.shared

        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let slotView = WorkspaceLayoutPaneContentSlotView(frame: .zero)
        let descriptor = terminalDescriptor(for: panel.id)

        workspace.surfaceRegistry.mountContent(
            .terminal(descriptor),
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        contentView.addSubview(slotView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        slotView.layoutSubtreeIfNeeded()

        workspace.surfaceRegistry.reconcileViewportLifecycle(
            .terminal(descriptor),
            contentId: panel.id,
            in: slotView,
            reason: "test.zeroGeometry"
        )

        XCTAssertNil(
            panel.surface.surface,
            "Expected visible runtime realization to wait for usable geometry instead of creating at zero size"
        )

        slotView.frame = contentView.bounds
        slotView.autoresizingMask = [.width, .height]
        contentView.layoutSubtreeIfNeeded()
        slotView.layoutSubtreeIfNeeded()

        workspace.surfaceRegistry.reconcileViewportLifecycle(
            .terminal(descriptor),
            contentId: panel.id,
            in: slotView,
            reason: "test.geometryReady"
        )

        XCTAssertTrue(
            waitForCondition { panel.surface.surface != nil },
            "Expected runtime realization once visible geometry became usable"
        )
    }

    func testTerminalRuntimeReadyCallbackFiresAfterViewportLifecycleReconcile() throws {
        _ = NSApplication.shared

        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let slotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )
        let descriptor = terminalDescriptor(for: panel.id)
        let readyExpectation = expectation(description: "runtime ready")

        workspace.surfaceRegistry.mountContent(
            .terminal(descriptor),
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )

        let token = panel.surface.onRuntimeReady {
            readyExpectation.fulfill()
        }
        XCTAssertNotNil(token)

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        slotView.frame = contentView.bounds
        slotView.autoresizingMask = [.width, .height]
        contentView.addSubview(slotView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        slotView.layoutSubtreeIfNeeded()

        workspace.surfaceRegistry.reconcileViewportLifecycle(
            .terminal(descriptor),
            contentId: panel.id,
            in: slotView,
            reason: "test.runtimeReady"
        )

        wait(for: [readyExpectation], timeout: 2.0)
        XCTAssertNotNil(panel.surface.surface)
    }

    func testBackgroundRuntimeRequestBeforeWindowEntryPersistsUntilHostCanRealize() throws {
        _ = NSApplication.shared

        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let slotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )
        let hiddenDescriptor = WorkspaceTerminalPaneContent(
            surfaceId: panel.id,
            isFocused: false,
            isVisibleInUI: false,
            isSplit: false,
            appearance: WorkspaceTerminalPaneAppearance(PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            )),
            hasUnreadNotification: false,
            onFocus: {},
            onTriggerFlash: {}
        )

        workspace.surfaceRegistry.mountContent(
            .terminal(hiddenDescriptor),
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )

        XCTAssertNil(panel.surface.surface)

        panel.surface.requestBackgroundSurfaceStartIfNeeded()
        XCTAssertNil(
            panel.surface.surface,
            "Background runtime demand should persist instead of creating a runtime before window entry"
        )

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)
        slotView.frame = contentView.bounds
        slotView.autoresizingMask = [.width, .height]
        contentView.addSubview(slotView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        slotView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            waitForCondition { panel.surface.surface != nil },
            "Expected a background runtime demand made before window entry to be fulfilled once the host entered a window"
        )
    }

    func testPlaceholderMountInstallsContentViewAndUnmountClearsIt() {
        let workspace = Workspace()
        let paneId = PaneID()
        let descriptor = placeholderDescriptor(paneId: paneId)
        let slotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )

        workspace.surfaceRegistry.mountContent(
            .placeholder(descriptor),
            contentId: paneId.id,
            in: slotView,
            activeDropZone: nil
        )

        XCTAssertEqual(slotView.subviews.count, 1)
        XCTAssertFalse(slotView.isHidden)

        workspace.surfaceRegistry.unmountContent(
            .placeholder(descriptor),
            contentId: paneId.id,
            from: slotView
        )

        XCTAssertTrue(slotView.subviews.isEmpty)
    }

    func testPlaceholderStaleUnmountDoesNotDiscardMovedHost() {
        let workspace = Workspace()
        let paneId = PaneID()
        let descriptor = placeholderDescriptor(paneId: paneId)
        let content = WorkspacePaneContent.placeholder(descriptor)
        let contentId = paneId.id
        let oldSlotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )
        let newSlotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )

        workspace.surfaceRegistry.mountContent(
            content,
            contentId: contentId,
            in: oldSlotView,
            activeDropZone: nil
        )
        let hostedView = oldSlotView.subviews.first

        workspace.surfaceRegistry.mountContent(
            content,
            contentId: contentId,
            in: newSlotView,
            activeDropZone: nil
        )
        workspace.surfaceRegistry.unmountContent(
            content,
            contentId: contentId,
            from: oldSlotView
        )

        XCTAssertTrue(hostedView?.superview === newSlotView)
        XCTAssertEqual(newSlotView.subviews.count, 1)
    }

    func testBrowserMountReusesRetainedContentViewAndUnmountClearsIt() throws {
        let workspace = Workspace()
        guard let paneId = workspace.focusedPaneId,
              let panel = workspace.createBrowserPanel(inPane: paneId, focus: false) else {
            XCTFail("Expected browser panel")
            return
        }

        let descriptor = browserDescriptor(for: panel.id, paneId: paneId)
        let content = WorkspacePaneContent.browser(descriptor)
        let slotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )

        workspace.surfaceRegistry.mountContent(
            content,
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )

        let initialView = try XCTUnwrap(
            slotView.subviews.first,
            "Expected browser mount to install a retained content view"
        )
        XCTAssertTrue(initialView is BrowserPanelWorkspaceContentView)
        XCTAssertEqual(slotView.subviews.count, 1)
        XCTAssertFalse(slotView.isHidden)

        workspace.surfaceRegistry.mountContent(
            content,
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )

        XCTAssertEqual(slotView.subviews.count, 1)
        XCTAssertTrue(
            slotView.subviews.first === initialView,
            "Expected browser remount to reuse the retained workspace content view"
        )

        workspace.surfaceRegistry.unmountContent(
            content,
            contentId: panel.id,
            from: slotView
        )

        XCTAssertTrue(slotView.subviews.isEmpty)
    }

    func testBrowserMountPreservesRetainedWebViewHostAcrossSlotMove() throws {
        let workspace = Workspace()
        guard let paneId = workspace.focusedPaneId,
              let panel = workspace.createBrowserPanel(inPane: paneId, focus: false) else {
            XCTFail("Expected browser panel")
            return
        }

        let sourceSlotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )
        let destinationSlotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 280, height: 200)
        )
        let sourceContent = WorkspacePaneContent.browser(
            browserDescriptor(for: panel.id, paneId: paneId)
        )
        let destinationPaneId = PaneID()
        let destinationContent = WorkspacePaneContent.browser(
            browserDescriptor(for: panel.id, paneId: destinationPaneId)
        )

        workspace.surfaceRegistry.mountContent(
            sourceContent,
            contentId: panel.id,
            in: sourceSlotView,
            activeDropZone: nil
        )

        let sourceHost = try XCTUnwrap(
            sourceSlotView.subviews.first as? BrowserPanelWorkspaceContentView,
            "Expected retained browser content view in source slot"
        )
        let retainedWebViewHost = sourceHost.debugRetainedWebViewHost

        workspace.surfaceRegistry.unmountContent(
            sourceContent,
            contentId: panel.id,
            from: sourceSlotView
        )
        workspace.surfaceRegistry.mountContent(
            destinationContent,
            contentId: panel.id,
            in: destinationSlotView,
            activeDropZone: nil
        )

        let destinationHost = try XCTUnwrap(
            destinationSlotView.subviews.first as? BrowserPanelWorkspaceContentView,
            "Expected retained browser content view in destination slot"
        )

        XCTAssertTrue(
            destinationHost === sourceHost,
            "Expected browser pane move to reuse the retained browser workspace content view"
        )
        XCTAssertTrue(
            destinationHost.debugRetainedWebViewHost === retainedWebViewHost,
            "Expected browser pane move to preserve the same retained webview host"
        )
    }

    func testMarkdownMountReusesRetainedContentViewAndUnmountClearsIt() throws {
        let workspace = Workspace()
        let fileURL = try temporaryMarkdownFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        guard let paneId = workspace.focusedPaneId,
              let panel = workspace.createMarkdownPanel(
                inPane: paneId,
                filePath: fileURL.path,
                focus: false
              ) else {
            XCTFail("Expected markdown panel")
            return
        }

        let descriptor = markdownDescriptor(for: panel.id)
        let content = WorkspacePaneContent.markdown(descriptor)
        let slotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )

        workspace.surfaceRegistry.mountContent(
            content,
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )

        let initialView = try XCTUnwrap(
            slotView.subviews.first,
            "Expected markdown mount to install a retained hosting view"
        )
        XCTAssertEqual(slotView.subviews.count, 1)
        XCTAssertFalse(slotView.isHidden)

        workspace.surfaceRegistry.mountContent(
            content,
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )

        XCTAssertEqual(slotView.subviews.count, 1)
        XCTAssertTrue(
            slotView.subviews.first === initialView,
            "Expected markdown remount to reuse the retained hosting view"
        )

        workspace.surfaceRegistry.unmountContent(
            content,
            contentId: panel.id,
            from: slotView
        )

        XCTAssertTrue(slotView.subviews.isEmpty)
    }

    func testSharedSlotTransitionReplacesTerminalWithPlaceholder() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let slotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )
        let terminalContent = WorkspacePaneContent.terminal(terminalDescriptor(for: panel.id))
        let paneId = PaneID()
        let placeholderContent = WorkspacePaneContent.placeholder(
            placeholderDescriptor(paneId: paneId)
        )

        workspace.surfaceRegistry.mountContent(
            terminalContent,
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )
        XCTAssertTrue(panel.hostedView.superview === slotView)

        workspace.surfaceRegistry.unmountContent(
            terminalContent,
            contentId: panel.id,
            from: slotView
        )
        workspace.surfaceRegistry.mountContent(
            placeholderContent,
            contentId: paneId.id,
            in: slotView,
            activeDropZone: nil
        )

        XCTAssertNil(panel.hostedView.superview)
        XCTAssertEqual(slotView.subviews.count, 1)
    }

    func testRemoveSurfaceDetachesTerminalHostedView() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let slotView = WorkspaceLayoutPaneContentSlotView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 220)
        )

        workspace.surfaceRegistry.mountContent(
            .terminal(terminalDescriptor(for: panel.id)),
            contentId: panel.id,
            in: slotView,
            activeDropZone: nil
        )
        XCTAssertTrue(panel.hostedView.superview === slotView)

        workspace.surfaceRegistry.removeSurface(surfaceId: panel.id)

        XCTAssertNil(panel.hostedView.superview)
        XCTAssertTrue(slotView.subviews.isEmpty)
    }

    func testSplitThenCloseSelectedPaneKeepsSurvivingTerminalVisible() throws {
        _ = NSApplication.shared

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId) else {
            XCTFail("Expected selected workspace with a focused terminal")
            return
        }

        let renderContext = makeRenderContext()
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
            surfaceRegistry: workspace.surfaceRegistry
        )

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView, "Expected content view")
        rootHost.frame = contentView.bounds
        rootHost.autoresizingMask = [.width, .height]
        contentView.addSubview(rootHost)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        rootHost.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            waitForCondition {
                sourcePanel.hostedView.window === window &&
                sourcePanel.hostedView.superview != nil &&
                !sourcePanel.hostedView.isHidden
            },
            "Expected the initial terminal to be mounted and visible"
        )

        guard let splitPanelId = manager.createSplit(direction: .right),
              let splitPanel = workspace.terminalPanel(for: splitPanelId) else {
            XCTFail("Expected cmd+d path to create a split terminal")
            return
        }

        rootHost.update(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
            surfaceRegistry: workspace.surfaceRegistry
        )
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        rootHost.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            waitForCondition {
                splitPanel.hostedView.window === window &&
                splitPanel.hostedView.superview != nil &&
                !splitPanel.hostedView.isHidden
            },
            "Expected the split terminal to become the visible selected pane"
        )

        XCTAssertTrue(
            workspace.closePanel(splitPanelId, force: true),
            "Expected cmd+w close path to succeed for the selected split terminal"
        )

        rootHost.update(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
            surfaceRegistry: workspace.surfaceRegistry
        )
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        rootHost.layoutSubtreeIfNeeded()

        XCTAssertEqual(workspace.paneCount, 1)
        XCTAssertTrue(
            waitForCondition {
                sourcePanel.hostedView.window === window &&
                sourcePanel.hostedView.superview != nil &&
                !sourcePanel.hostedView.isHidden
            },
            "Expected the surviving terminal to remain visible after closing the selected split"
        )
        XCTAssertNil(splitPanel.hostedView.superview)
    }

    func testRepeatedSplitThenCloseSelectedPaneKeepsSurvivingTerminalVisible() throws {
        _ = NSApplication.shared

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId) else {
            XCTFail("Expected selected workspace with a focused terminal")
            return
        }

        let renderContext = makeRenderContext()
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
            surfaceRegistry: workspace.surfaceRegistry
        )

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView, "Expected content view")
        rootHost.frame = contentView.bounds
        rootHost.autoresizingMask = [.width, .height]
        contentView.addSubview(rootHost)

        func refreshHost() {
            rootHost.update(
                hostBridge: workspace.layoutInteractionHandlers,
                renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
                surfaceRegistry: workspace.surfaceRegistry
            )
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            rootHost.layoutSubtreeIfNeeded()
        }

        window.makeKeyAndOrderFront(nil)
        refreshHost()

        XCTAssertTrue(
            waitForCondition {
                sourcePanel.hostedView.window === window &&
                sourcePanel.hostedView.superview != nil &&
                !sourcePanel.hostedView.isHidden
            },
            "Expected the initial terminal to be mounted and visible"
        )

        for cycle in 1...3 {
            guard let splitPanelId = manager.createSplit(direction: .right),
                  let splitPanel = workspace.terminalPanel(for: splitPanelId) else {
                XCTFail("Expected cmd+d path to create a split terminal on cycle \(cycle)")
                return
            }

            refreshHost()

            XCTAssertTrue(
                waitForCondition {
                    splitPanel.hostedView.window === window &&
                    splitPanel.hostedView.superview != nil &&
                    !splitPanel.hostedView.isHidden
                },
                "Expected the split terminal to become visible on cycle \(cycle)"
            )

            XCTAssertTrue(
                workspace.closePanel(splitPanelId, force: true),
                "Expected cmd+w close path to succeed on cycle \(cycle)"
            )

            refreshHost()

            XCTAssertEqual(
                workspace.paneCount,
                1,
                "Expected one pane after closing split on cycle \(cycle)"
            )
            XCTAssertTrue(
                waitForCondition {
                    sourcePanel.hostedView.window === window &&
                    sourcePanel.hostedView.superview != nil &&
                    !sourcePanel.hostedView.isHidden
                },
                "Expected the surviving terminal to remain visible on cycle \(cycle)"
            )
            XCTAssertNil(
                splitPanel.hostedView.superview,
                "Expected the closed split terminal to stay detached on cycle \(cycle)"
            )
        }
    }

    func testSplitThenCloseRefocusedSourcePaneKeepsSplitVisible() throws {
        _ = NSApplication.shared

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId),
              let sourcePaneId = workspace.focusedPaneId else {
            XCTFail("Expected selected workspace with a focused terminal")
            return
        }

        let renderContext = makeRenderContext()
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
            surfaceRegistry: workspace.surfaceRegistry
        )

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView, "Expected content view")
        rootHost.frame = contentView.bounds
        rootHost.autoresizingMask = [.width, .height]
        contentView.addSubview(rootHost)

        func refreshHost() {
            rootHost.update(
                hostBridge: workspace.layoutInteractionHandlers,
                renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
                surfaceRegistry: workspace.surfaceRegistry
            )
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            rootHost.layoutSubtreeIfNeeded()
        }

        window.makeKeyAndOrderFront(nil)
        refreshHost()

        XCTAssertTrue(
            waitForCondition {
                sourcePanel.hostedView.window === window &&
                sourcePanel.hostedView.superview != nil &&
                !sourcePanel.hostedView.isHidden
            },
            "Expected the initial terminal to be mounted and visible"
        )

        guard let splitPanelId = manager.createSplit(direction: .right),
              let splitPanel = workspace.terminalPanel(for: splitPanelId) else {
            XCTFail("Expected cmd+d path to create a split terminal")
            return
        }

        refreshHost()

        XCTAssertTrue(
            waitForCondition {
                splitPanel.hostedView.window === window &&
                splitPanel.hostedView.superview != nil &&
                !splitPanel.hostedView.isHidden
            },
            "Expected the split terminal to become visible after creation"
        )

        XCTAssertTrue(workspace.focusPane(sourcePaneId))
        workspace.focusPanel(sourcePanelId)
        refreshHost()

        XCTAssertEqual(workspace.focusedPanelId, sourcePanelId)
        XCTAssertTrue(
            waitForCondition {
                sourcePanel.hostedView.window === window &&
                sourcePanel.hostedView.superview != nil &&
                !sourcePanel.hostedView.isHidden
            },
            "Expected the source terminal to become visible again after refocus"
        )

        XCTAssertTrue(
            workspace.closePanel(sourcePanelId, force: true),
            "Expected closing the refocused source pane to succeed"
        )

        refreshHost()

        XCTAssertEqual(workspace.paneCount, 1)
        XCTAssertEqual(workspace.focusedPanelId, splitPanelId)
        XCTAssertTrue(
            waitForCondition {
                splitPanel.hostedView.window === window &&
                splitPanel.hostedView.superview != nil &&
                !splitPanel.hostedView.isHidden
            },
            "Expected the split terminal to remain visible after closing the refocused source pane"
        )
        XCTAssertNil(sourcePanel.hostedView.superview)
    }

    func testVerticalSplitThenCloseSelectedPaneKeepsSurvivingTerminalVisible() throws {
        _ = NSApplication.shared

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId) else {
            XCTFail("Expected selected workspace with a focused terminal")
            return
        }

        let renderContext = makeRenderContext()
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
            surfaceRegistry: workspace.surfaceRegistry
        )

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView, "Expected content view")
        rootHost.frame = contentView.bounds
        rootHost.autoresizingMask = [.width, .height]
        contentView.addSubview(rootHost)

        func refreshHost() {
            rootHost.update(
                hostBridge: workspace.layoutInteractionHandlers,
                renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
                surfaceRegistry: workspace.surfaceRegistry
            )
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            rootHost.layoutSubtreeIfNeeded()
        }

        window.makeKeyAndOrderFront(nil)
        refreshHost()

        XCTAssertTrue(
            waitForCondition {
                sourcePanel.hostedView.window === window &&
                sourcePanel.hostedView.superview != nil &&
                !sourcePanel.hostedView.isHidden
            },
            "Expected the initial terminal to be mounted and visible"
        )

        guard let splitPanelId = manager.createSplit(direction: .down),
              let splitPanel = workspace.terminalPanel(for: splitPanelId) else {
            XCTFail("Expected cmd+shift+d path to create a split terminal")
            return
        }

        refreshHost()

        XCTAssertTrue(
            waitForCondition {
                splitPanel.hostedView.window === window &&
                splitPanel.hostedView.superview != nil &&
                !splitPanel.hostedView.isHidden
            },
            "Expected the vertical split terminal to become the visible selected pane"
        )

        XCTAssertTrue(
            workspace.closePanel(splitPanelId, force: true),
            "Expected cmd+w close path to succeed for the selected vertical split terminal"
        )

        refreshHost()

        XCTAssertEqual(workspace.paneCount, 1)
        XCTAssertTrue(
            waitForCondition {
                sourcePanel.hostedView.window === window &&
                sourcePanel.hostedView.superview != nil &&
                !sourcePanel.hostedView.isHidden
            },
            "Expected the surviving terminal to remain visible after closing the selected vertical split"
        )
        XCTAssertNil(splitPanel.hostedView.superview)
    }

    func testVerticalSplitThenCloseRefocusedSourcePaneKeepsSplitVisible() throws {
        _ = NSApplication.shared

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId),
              let sourcePaneId = workspace.focusedPaneId else {
            XCTFail("Expected selected workspace with a focused terminal")
            return
        }

        let renderContext = makeRenderContext()
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
            surfaceRegistry: workspace.surfaceRegistry
        )

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView, "Expected content view")
        rootHost.frame = contentView.bounds
        rootHost.autoresizingMask = [.width, .height]
        contentView.addSubview(rootHost)

        func refreshHost() {
            rootHost.update(
                hostBridge: workspace.layoutInteractionHandlers,
                renderSnapshot: workspace.makeLayoutRenderSnapshot(context: renderContext),
                surfaceRegistry: workspace.surfaceRegistry
            )
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            rootHost.layoutSubtreeIfNeeded()
        }

        window.makeKeyAndOrderFront(nil)
        refreshHost()

        XCTAssertTrue(
            waitForCondition {
                sourcePanel.hostedView.window === window &&
                sourcePanel.hostedView.superview != nil &&
                !sourcePanel.hostedView.isHidden
            },
            "Expected the initial terminal to be mounted and visible"
        )

        guard let splitPanelId = manager.createSplit(direction: .down),
              let splitPanel = workspace.terminalPanel(for: splitPanelId) else {
            XCTFail("Expected cmd+shift+d path to create a split terminal")
            return
        }

        refreshHost()

        XCTAssertTrue(
            waitForCondition {
                splitPanel.hostedView.window === window &&
                splitPanel.hostedView.superview != nil &&
                !splitPanel.hostedView.isHidden
            },
            "Expected the vertical split terminal to become visible after creation"
        )

        XCTAssertTrue(workspace.focusPane(sourcePaneId))
        workspace.focusPanel(sourcePanelId)
        refreshHost()

        XCTAssertEqual(workspace.focusedPanelId, sourcePanelId)
        XCTAssertTrue(
            waitForCondition {
                sourcePanel.hostedView.window === window &&
                sourcePanel.hostedView.superview != nil &&
                !sourcePanel.hostedView.isHidden
            },
            "Expected the source terminal to become visible again after refocus"
        )

        XCTAssertTrue(
            workspace.closePanel(sourcePanelId, force: true),
            "Expected closing the refocused source pane to succeed for the vertical split"
        )

        refreshHost()

        XCTAssertEqual(workspace.paneCount, 1)
        XCTAssertEqual(workspace.focusedPanelId, splitPanelId)
        XCTAssertTrue(
            waitForCondition {
                splitPanel.hostedView.window === window &&
                splitPanel.hostedView.superview != nil &&
                !splitPanel.hostedView.isHidden
            },
            "Expected the vertical split terminal to remain visible after closing the refocused source pane"
        )
        XCTAssertNil(sourcePanel.hostedView.superview)
    }
}


@MainActor
final class WorkspaceTerminalFocusRecoveryTests: XCTestCase {
    private final class FocusHandoffTestWindow: NSWindow {
        var nilFirstResponderRequestCount = 0

        override var isKeyWindow: Bool { true }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if responder == nil {
                nilFirstResponderRequestCount += 1
            }
            return super.makeFirstResponder(responder)
        }
    }

    private func makeWindow() -> FocusHandoffTestWindow {
        FocusHandoffTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
        var stack: [NSView] = [hostedView]
        while let current = stack.popLast() {
            if let surfaceView = current as? GhosttyNSView {
                return surfaceView
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    func testSwitchingFromBrowserToTerminalPreservesBrowserResponderUntilTerminalFocus() throws {
        let workspace = Workspace()
        guard let terminalPanelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: terminalPanelId),
              let browserPanel = workspace.splitBrowserPanel(
                  fromPanelId: terminalPanelId,
                  orientation: .horizontal,
                  focus: true
              ) else {
            XCTFail("Expected terminal/browser split setup to succeed")
            return
        }

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try XCTUnwrap(window.contentView)

        terminalPanel.hostedView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        browserPanel.webView.frame = NSRect(x: 180, y: 0, width: 180, height: 220)
        contentView.addSubview(terminalPanel.hostedView)
        contentView.addSubview(browserPanel.webView)

        terminalPanel.hostedView.setVisibleInUI(true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()

        let cmuxWebView = try XCTUnwrap(browserPanel.webView as? CmuxWebView)
        cmuxWebView.allowsFirstResponderAcquisition = true
        XCTAssertTrue(window.makeFirstResponder(browserPanel.webView))
        XCTAssertTrue(window.firstResponder === browserPanel.webView)
        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        let nilRequestsBeforeSwitch = window.nilFirstResponderRequestCount
        workspace.focusPanel(terminalPanelId)

        XCTAssertEqual(
            window.nilFirstResponderRequestCount,
            nilRequestsBeforeSwitch,
            "Expected browser WebView first responder handoff to avoid a nil responder bounce"
        )
        XCTAssertFalse(window.firstResponder === browserPanel.webView)
        XCTAssertTrue(window.firstResponder === surfaceView(in: terminalPanel.hostedView))
    }

    func testTerminalFirstResponderConvergesSplitActiveStateWhenSelectionAlreadyMatches() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.splitTerminalPanel(fromPanelId: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        XCTAssertEqual(
            workspace.focusedPanelId,
            rightPanel.id,
            "Expected the new split panel to be selected before simulating stale focus state"
        )

        // Simulate the split-pane failure mode: WorkspaceSplit already points at the right panel,
        // but the active terminal state is still stale on the left panel.
        leftPanel.surface.setFocus(true)
        leftPanel.hostedView.setActive(true)
        rightPanel.surface.setFocus(false)
        rightPanel.hostedView.setActive(false)

        workspace.focusPanel(rightPanel.id, trigger: .terminalFirstResponder)

        XCTAssertFalse(
            leftPanel.hostedView.debugRenderStats().isActive,
            "Expected stale left-pane active state to be cleared"
        )
        XCTAssertTrue(
            rightPanel.hostedView.debugRenderStats().isActive,
            "Expected terminal-first-responder recovery to reactivate the selected split pane"
        )
    }

    func testTerminalClickRecoversSplitActiveStateWhenFocusCallbackIsSuppressed() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.splitTerminalPanel(fromPanelId: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        let window = makeWindow()
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        leftPanel.hostedView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        rightPanel.hostedView.frame = NSRect(x: 180, y: 0, width: 180, height: 220)
        contentView.addSubview(leftPanel.hostedView)
        contentView.addSubview(rightPanel.hostedView)

        leftPanel.hostedView.setVisibleInUI(true)
        rightPanel.hostedView.setVisibleInUI(true)
        leftPanel.hostedView.setFocusHandler {
            workspace.focusPanel(leftPanel.id, trigger: .terminalFirstResponder)
        }
        rightPanel.hostedView.setFocusHandler {
            workspace.focusPanel(rightPanel.id, trigger: .terminalFirstResponder)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            workspace.focusedPanelId,
            rightPanel.id,
            "Expected the clicked split pane to already be selected before simulating stale focus state"
        )

        // Simulate the ghost-terminal race: the right pane is selected in WorkspaceSplit, but stale
        // active state remains on the left and the right pane's AppKit focus callback never fires
        // after split reparent/layout churn.
        leftPanel.surface.setFocus(true)
        leftPanel.hostedView.setActive(true)
        rightPanel.surface.setFocus(false)
        rightPanel.hostedView.setActive(false)
        rightPanel.hostedView.suppressReparentFocus()

        guard let rightSurfaceView = surfaceView(in: rightPanel.hostedView) else {
            XCTFail("Expected right terminal surface view")
            return
        }

        let pointInWindow = rightSurfaceView.convert(NSPoint(x: 24, y: 24), to: nil)
        let event = makeMouseEvent(type: .leftMouseDown, location: pointInWindow, window: window)
        rightSurfaceView.mouseDown(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            leftPanel.hostedView.debugRenderStats().isActive,
            "Expected clicking the selected split pane to clear stale sibling active state even when AppKit focus callbacks are suppressed"
        )
        XCTAssertTrue(
            rightPanel.hostedView.debugRenderStats().isActive,
            "Expected clicking the selected split pane to reactivate terminal input when focus callbacks are suppressed"
        )
        XCTAssertTrue(
            rightPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected the clicked split pane to become first responder"
        )
    }

    func testClearSuppressReparentFocusReassertsGhosttyFocusForCurrentFirstResponder() throws {
#if DEBUG
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.splitTerminalPanel(fromPanelId: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        let window = makeWindow()
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        leftPanel.hostedView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        rightPanel.hostedView.frame = NSRect(x: 180, y: 0, width: 180, height: 220)
        contentView.addSubview(leftPanel.hostedView)
        contentView.addSubview(rightPanel.hostedView)

        leftPanel.hostedView.setVisibleInUI(true)
        rightPanel.hostedView.setVisibleInUI(true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let leftSurfaceView = surfaceView(in: leftPanel.hostedView) else {
            XCTFail("Expected left terminal surface view")
            return
        }

        leftPanel.surface.setFocus(false)
        rightPanel.surface.setFocus(true)
        leftPanel.hostedView.suppressReparentFocus()

        XCTAssertTrue(window.makeFirstResponder(leftSurfaceView))
        XCTAssertTrue(leftPanel.hostedView.isSurfaceViewFirstResponder())

        XCTAssertFalse(
            leftPanel.surface.debugDesiredFocusState(),
            "Suppressed reparent focus should not immediately flip the Ghostty focus bit"
        )

        leftPanel.hostedView.clearSuppressReparentFocus()
        let focusRecovered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                leftPanel.surface.debugDesiredFocusState()
            },
            object: NSObject()
        )
        wait(for: [focusRecovered], timeout: 1.0)
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}


@MainActor
final class WorkspaceTerminalConfigInheritanceSelectionTests: XCTestCase {
    func testPrefersSelectedTerminalInTargetPaneOverFocusedTerminalElsewhere() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.splitTerminalPanel(fromPanelId: leftPanelId, orientation: .horizontal),
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId) else {
            XCTFail("Expected workspace split setup to succeed")
            return
        }

        // Programmatic split focuses the new right panel by default.
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: leftPaneId)
        XCTAssertEqual(
            sourcePanel?.id,
            leftPanelId,
            "Expected inheritance to use the selected terminal in the target pane"
        )
    }

    func testFallsBackToAnotherTerminalInPaneWhenSelectedTabIsBrowser() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId),
              let browserPanel = workspace.createBrowserPanel(inPane: paneId, focus: true) else {
            XCTFail("Expected workspace browser setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: paneId)
        XCTAssertEqual(
            sourcePanel?.id,
            terminalPanelId,
            "Expected inheritance to fall back to a terminal in the pane when browser is selected"
        )
    }

    func testPreferredTerminalPanelWinsWhenProvided() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a terminal panel")
            return
        }

        let sourcePanel = workspace.terminalPanelForConfigInheritance(preferredPanelId: terminalPanelId)
        XCTAssertEqual(sourcePanel?.id, terminalPanelId)
    }

    func testPrefersLastFocusedTerminalWhenBrowserFocusedInDifferentPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftTerminalPanelId = workspace.focusedPanelId,
              let rightTerminalPanel = workspace.splitTerminalPanel(fromPanelId: leftTerminalPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightTerminalPanel.id) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftTerminalPanelId)
        _ = workspace.createBrowserPanel(inPane: rightPaneId, focus: true)
        XCTAssertNotEqual(workspace.focusedPanelId, leftTerminalPanelId)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: rightPaneId)
        XCTAssertEqual(
            sourcePanel?.id,
            leftTerminalPanelId,
            "Expected inheritance to prefer last focused terminal when browser is focused in another pane"
        )
    }
}


@MainActor
final class WorkspaceAttentionFlashTests: XCTestCase {
    func testMoveFocusDoesNotTriggerWholePaneFlashTokenWhenWholePaneModeEnabled() {
        let defaults = UserDefaults.standard
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        defer {
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.workspacePane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.splitTerminalPanel(fromPanelId: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 0)
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)

        workspace.moveFocus(direction: .left)

        XCTAssertEqual(workspace.focusedPanelId, leftPanelId)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            0,
            "Expected moving focus left to avoid any workspace-pane flash"
        )
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)

        workspace.moveFocus(direction: .right)

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            0,
            "Expected moving focus right to avoid any workspace-pane flash"
        )
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)
    }

    func testMoveFocusSuppressesWorkspacePaneFlashWhenAnotherPaneOwnsUnreadAttention() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let notificationStore = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = notificationStore
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.workspacePane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.splitTerminalPanel(fromPanelId: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        workspace.moveFocus(direction: .left)

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: leftPanelId,
            title: "Unread",
            subtitle: "",
            body: "Left pane owns notification attention"
        )

        XCTAssertTrue(
            notificationStore.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: leftPanelId),
            "Expected the left pane to own visible notification attention before moving focus"
        )

        let flashTokenBeforeNavigation = workspace.tmuxWorkspaceFlashToken

        workspace.moveFocus(direction: .right)

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            flashTokenBeforeNavigation,
            "Expected navigation flash to be suppressed while another pane owns notification attention"
        )
    }
}


@MainActor
final class WorkspaceBrowserProfileSelectionTests: XCTestCase {
    private final class RejectingCreateTabDelegate: WorkspaceLayoutDelegate {
        func workspaceSplit(
            shouldCreateTab tabId: TabID,
            inPane pane: PaneID
        ) -> Bool {
            false
        }
    }

    private final class RejectingSplitPaneDelegate: WorkspaceLayoutDelegate {
        func workspaceSplit(
            shouldSplitPane pane: PaneID,
            orientation: SplitOrientation
        ) -> Bool {
            false
        }
    }

    func testNewBrowserSurfacePrefersSelectedBrowserProfileInTargetPane() throws {
        let workspace = Workspace()
        let profileA = try makeTemporaryBrowserProfile(named: "Alpha")
        let profileB = try makeTemporaryBrowserProfile(named: "Beta")
        let paneId = try XCTUnwrap(workspace.focusedPaneId)
        let browserA = try XCTUnwrap(
            workspace.createBrowserPanel(
                inPane: paneId,
                focus: true,
                preferredProfileID: profileA.id
            )
        )
        _ = try XCTUnwrap(
            workspace.splitBrowserPanel(fromPanelId: browserA.id,
                orientation: .horizontal,
                preferredProfileID: profileB.id,
                focus: true
            )
        )

        XCTAssertEqual(
            workspace.preferredBrowserProfileID,
            profileB.id,
            "Expected workspace preference to drift to the most recently created browser profile"
        )

        let leftSurfaceId = try XCTUnwrap(workspace.surfaceIdFromPanelId(browserA.id))
        XCTAssertTrue(workspace.focusPane(paneId))
        XCTAssertTrue(workspace.selectSurface(leftSurfaceId.id))

        let created = try XCTUnwrap(
            workspace.createBrowserPanel(
                inPane: paneId,
                focus: false
            )
        )

        XCTAssertEqual(
            created.profileID,
            profileA.id,
            "Expected new browser creation to inherit the selected browser profile from the target pane"
        )
    }

    func testNewBrowserSurfaceFailureDoesNotMutatePreferredProfile() throws {
        let workspace = Workspace()
        let preferredProfile = try makeTemporaryBrowserProfile(named: "Preferred")
        let unexpectedProfile = try makeTemporaryBrowserProfile(named: "Unexpected")

        let paneId = try XCTUnwrap(workspace.focusedPaneId)
        _ = try XCTUnwrap(
            workspace.createBrowserPanel(
                inPane: paneId,
                focus: false,
                preferredProfileID: preferredProfile.id
            )
        )
        XCTAssertEqual(workspace.preferredBrowserProfileID, preferredProfile.id)

        let rejectingDelegate = RejectingCreateTabDelegate()
        workspace.setLayoutDelegateForTesting(rejectingDelegate)
        let created = workspace.createBrowserPanel(
            inPane: paneId,
            focus: false,
            preferredProfileID: unexpectedProfile.id
        )

        XCTAssertNil(created)
        XCTAssertEqual(
            workspace.preferredBrowserProfileID,
            preferredProfile.id,
            "Expected a failed browser creation to leave the workspace preferred profile unchanged"
        )
    }

    func testNewBrowserSplitFailureDoesNotMutatePreferredProfile() throws {
        let workspace = Workspace()
        let preferredProfile = try makeTemporaryBrowserProfile(named: "Preferred")
        let unexpectedProfile = try makeTemporaryBrowserProfile(named: "Unexpected")

        let paneId = try XCTUnwrap(workspace.focusedPaneId)
        let browser = try XCTUnwrap(
            workspace.createBrowserPanel(
                inPane: paneId,
                focus: true,
                preferredProfileID: preferredProfile.id
            )
        )
        XCTAssertEqual(workspace.preferredBrowserProfileID, preferredProfile.id)

        let rejectingDelegate = RejectingSplitPaneDelegate()
        workspace.setLayoutDelegateForTesting(rejectingDelegate)
        let created = workspace.splitBrowserPanel(fromPanelId: browser.id,
            orientation: .horizontal,
            preferredProfileID: unexpectedProfile.id,
            focus: false
        )

        XCTAssertNil(created)
        XCTAssertEqual(
            workspace.preferredBrowserProfileID,
            preferredProfile.id,
            "Expected a failed browser split to leave the workspace preferred profile unchanged"
        )
    }
}


@MainActor
final class WorkspacePanelGitBranchTests: XCTestCase {
    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    private func temporaryMarkdownFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-panel-git-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("note.md")
        try "# workspace\n".write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func testBrowserSplitWithFocusFalsePreservesOriginalFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let browserSplitPanel = workspace.splitBrowserPanel(fromPanelId: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }

        drainMainQueue()

        XCTAssertNotEqual(browserSplitPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus browser split to preserve pre-split focus"
        )
    }

    func testTerminalSplitWithFocusFalsePreservesOriginalFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let terminalSplitPanel = workspace.splitTerminalPanel(fromPanelId: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected terminal split panel to be created")
            return
        }

        drainMainQueue()

        XCTAssertNotEqual(terminalSplitPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus terminal split to preserve pre-split focus"
        )
    }

    func testDetachLastSurfaceLeavesWorkspaceTemporarilyEmptyForMoveFlow() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: panelId) else {
            XCTFail("Expected initial panel and pane")
            return
        }

        XCTAssertEqual(workspace.panels.count, 1)
#if DEBUG
        let baselineFocusReconcileDuringDetach = workspace.debugFocusReconcileScheduledDuringDetachCount
#endif

        guard let detached = workspace.detachSurface(panelId: panelId) else {
            XCTFail("Expected detach of last surface to succeed")
            return
        }

        XCTAssertEqual(detached.panelId, panelId)
        XCTAssertTrue(
            workspace.panels.isEmpty,
            "Detaching the last surface should not auto-create a replacement panel"
        )
        XCTAssertNil(workspace.surfaceIdFromPanelId(panelId))
        XCTAssertEqual(workspace.surfaceIds(inPane: paneId).count, 0)

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        XCTAssertEqual(
            workspace.debugFocusReconcileScheduledDuringDetachCount,
            baselineFocusReconcileDuringDetach,
            "Detaching during cross-workspace moves should not schedule delayed source focus reconciliation"
        )
#endif

        let restoredPanelId = workspace.attachDetachedSurface(detached, inPane: paneId, focus: false)
        XCTAssertEqual(restoredPanelId, panelId)
        XCTAssertEqual(workspace.panels.count, 1)
    }

    func testDetachSurfaceWithRemainingPanelsSkipsDelayedFocusReconcile() {
        let workspace = Workspace()
        guard let originalPanelId = workspace.focusedPanelId,
              let movedPanel = workspace.splitTerminalPanel(fromPanelId: originalPanelId, orientation: .horizontal) else {
            XCTFail("Expected two panels before detach")
            return
        }

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        let baselineFocusReconcileDuringDetach = workspace.debugFocusReconcileScheduledDuringDetachCount
#endif

        guard let detached = workspace.detachSurface(panelId: movedPanel.id) else {
            XCTFail("Expected detach to succeed")
            return
        }

        XCTAssertEqual(detached.panelId, movedPanel.id)
        XCTAssertEqual(workspace.panels.count, 1, "Expected source workspace to retain only the surviving panel")
        XCTAssertNotNil(workspace.panels[originalPanelId], "Expected the original panel to remain after detach")

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        XCTAssertEqual(
            workspace.debugFocusReconcileScheduledDuringDetachCount,
            baselineFocusReconcileDuringDetach,
            "Detaching into another workspace should not enqueue delayed source focus reconciliation"
        )
#endif
    }

    func testDetachAttachAcrossWorkspacesPreservesNonCustomPanelTitle() {
        let source = Workspace()
        guard let panelId = source.focusedPanelId else {
            XCTFail("Expected source focused panel")
            return
        }

        XCTAssertTrue(source.updatePanelTitle(panelId: panelId, title: "detached-runtime-title"))

        guard let detached = source.detachSurface(panelId: panelId) else {
            XCTFail("Expected detach to succeed")
            return
        }

        XCTAssertEqual(detached.cachedTitle, "detached-runtime-title")
        XCTAssertNil(detached.customTitle)
        XCTAssertEqual(
            detached.title,
            "detached-runtime-title",
            "Detached transfer should carry the cached non-custom title"
        )

        let destination = Workspace()
        guard let destinationPane = destination.paneIds.first else {
            XCTFail("Expected destination pane")
            return
        }

        let attachedPanelId = destination.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        )
        XCTAssertEqual(attachedPanelId, panelId)
        XCTAssertEqual(destination.panelTitle(panelId: panelId), "detached-runtime-title")

        guard destination.surfaceIdFromPanelId(panelId) != nil else {
            XCTFail("Expected attached tab mapping")
            return
        }
        XCTAssertEqual(destination.panelTitle(panelId: panelId), "detached-runtime-title")
        XCTAssertFalse(destination.hasPanelCustomTitle(panelId: panelId))
    }

    func testBrowserSplitWithFocusFalseRecoversFromDelayedStaleSelection() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }
        guard let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected focused pane for initial panel")
            return
        }

        guard let browserSplitPanel = workspace.splitBrowserPanel(fromPanelId: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }
        guard let splitPaneId = workspace.paneId(forPanelId: browserSplitPanel.id),
              let splitTabId = workspace.surfaceIdFromPanelId(browserSplitPanel.id) else {
            XCTFail("Expected split pane/tab mapping")
            return
        }

        // Simulate one delayed stale split-selection callback from WorkspaceSplit.
        DispatchQueue.main.async {
            workspace.workspaceSplit(didSelectTab: splitTabId, inPane: splitPaneId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus split to reassert the pre-split focused panel"
        )
        XCTAssertEqual(
            workspace.focusedPaneId,
            originalPaneId,
            "Expected focused pane to converge back to the pre-split pane"
        )
        XCTAssertEqual(
            workspace.selectedSurfaceId(inPane: originalPaneId),
            workspace.surfaceIdFromPanelId(originalFocusedPanelId)?.id,
            "Expected selected tab to converge back to the pre-split focused panel"
        )
    }

    func testBrowserSplitWithFocusFalseAllowsSubsequentExplicitFocusOnSplitPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let browserSplitPanel = workspace.splitBrowserPanel(fromPanelId: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }

        workspace.focusPanel(browserSplitPanel.id)

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            workspace.focusedPanelId,
            browserSplitPanel.id,
            "Expected explicit focus intent to keep the split panel focused"
        )
    }

    func testNewTerminalSurfaceWithFocusFalsePreservesFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId,
              let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected initial focused panel and pane")
            return
        }

        guard let newPanel = workspace.createTerminalPanel(inPane: originalPaneId, focus: false) else {
            XCTFail("Expected terminal surface to be created")
            return
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertNotEqual(newPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus terminal surface creation to preserve the existing focused panel"
        )
        XCTAssertEqual(
            workspace.selectedSurfaceId(inPane: originalPaneId),
            workspace.surfaceIdFromPanelId(originalFocusedPanelId)?.id,
            "Expected selected tab to stay on the original focused panel"
        )
    }

    func testNewBrowserSurfaceWithFocusFalsePreservesFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId,
              let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected initial focused panel and pane")
            return
        }

        guard let newPanel = workspace.createBrowserPanel(inPane: originalPaneId, focus: false) else {
            XCTFail("Expected browser surface to be created")
            return
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertNotEqual(newPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus browser surface creation to preserve the existing focused panel"
        )
        XCTAssertEqual(
            workspace.selectedSurfaceId(inPane: originalPaneId),
            workspace.surfaceIdFromPanelId(originalFocusedPanelId)?.id,
            "Expected selected tab to stay on the original focused panel"
        )
    }

    func testSplitPaneMovingTabHandlerSelfSplitLastTerminalCreatesReplacementTerminal() {
        let workspace = Workspace()
        guard let sourcePanelId = workspace.focusedPanelId,
              let sourcePaneId = workspace.focusedPaneId else {
            XCTFail("Expected initial focused terminal and pane")
            return
        }

        guard let newPaneId = workspace.layoutInteractionHandlers.splitPaneMovingTabHandler(
            sourcePaneId,
            .vertical,
            TabID(id: sourcePanelId),
            false,
            true
        ) else {
            XCTFail("Expected drag self-split to create a new pane")
            return
        }

        let sourcePaneSurfaces = workspace.surfaceIds(inPane: sourcePaneId)
        XCTAssertEqual(sourcePaneSurfaces.count, 1, "Expected source pane to keep a replacement surface")
        XCTAssertEqual(workspace.surfaceIds(inPane: newPaneId), [sourcePanelId], "Expected moved terminal in the new pane")

        guard let replacementPanelId = sourcePaneSurfaces.first else {
            XCTFail("Expected replacement terminal")
            return
        }

        XCTAssertNotEqual(replacementPanelId, sourcePanelId)
        XCTAssertNotNil(workspace.terminalPanel(for: replacementPanelId))
        XCTAssertEqual(workspace.selectedSurfaceId(inPane: sourcePaneId), replacementPanelId)
    }

    func testSplitPaneMovingTabHandlerSelfSplitLastBrowserCreatesReplacementBrowser() {
        let workspace = Workspace()
        guard let sourcePaneId = workspace.focusedPaneId,
              let originalTerminalId = workspace.focusedPanelId,
              let browserPanel = workspace.createBrowserPanel(inPane: sourcePaneId, focus: true) else {
            XCTFail("Expected initial pane and browser surface")
            return
        }

        XCTAssertTrue(workspace.closePanel(originalTerminalId, force: true), "Expected bootstrap terminal to close")
        drainMainQueue()
        drainMainQueue()

        guard let newPaneId = workspace.layoutInteractionHandlers.splitPaneMovingTabHandler(
            sourcePaneId,
            .vertical,
            TabID(id: browserPanel.id),
            false,
            true
        ) else {
            XCTFail("Expected browser drag self-split to create a new pane")
            return
        }

        let sourcePaneSurfaces = workspace.surfaceIds(inPane: sourcePaneId)
        XCTAssertEqual(sourcePaneSurfaces.count, 1, "Expected source pane to keep a replacement browser")
        XCTAssertEqual(workspace.surfaceIds(inPane: newPaneId), [browserPanel.id], "Expected moved browser in the new pane")

        guard let replacementPanelId = sourcePaneSurfaces.first,
              let replacementBrowser = workspace.browserPanel(for: replacementPanelId) else {
            XCTFail("Expected replacement browser")
            return
        }

        XCTAssertNotEqual(replacementPanelId, browserPanel.id)
        XCTAssertEqual(replacementBrowser.profileID, browserPanel.profileID)
        XCTAssertTrue(replacementBrowser.shouldRenderWebView)
        XCTAssertEqual(workspace.selectedSurfaceId(inPane: sourcePaneId), replacementPanelId)
    }

    func testSplitPaneMovingTabHandlerSelfSplitLastMarkdownCreatesReplacementMarkdown() throws {
        let workspace = Workspace()
        let fileURL = try temporaryMarkdownFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        guard let sourcePaneId = workspace.focusedPaneId,
              let originalTerminalId = workspace.focusedPanelId,
              let markdownPanel = workspace.createMarkdownPanel(
                inPane: sourcePaneId,
                filePath: fileURL.path,
                focus: true
              ) else {
            XCTFail("Expected initial pane and markdown surface")
            return
        }

        XCTAssertTrue(workspace.closePanel(originalTerminalId, force: true), "Expected bootstrap terminal to close")
        drainMainQueue()
        drainMainQueue()

        guard let newPaneId = workspace.layoutInteractionHandlers.splitPaneMovingTabHandler(
            sourcePaneId,
            .vertical,
            TabID(id: markdownPanel.id),
            false,
            true
        ) else {
            XCTFail("Expected markdown drag self-split to create a new pane")
            return
        }

        let sourcePaneSurfaces = workspace.surfaceIds(inPane: sourcePaneId)
        XCTAssertEqual(sourcePaneSurfaces.count, 1, "Expected source pane to keep a replacement markdown panel")
        XCTAssertEqual(workspace.surfaceIds(inPane: newPaneId), [markdownPanel.id], "Expected moved markdown in the new pane")

        guard let replacementPanelId = sourcePaneSurfaces.first,
              let replacementMarkdown = workspace.markdownPanel(for: replacementPanelId) else {
            XCTFail("Expected replacement markdown panel")
            return
        }

        XCTAssertNotEqual(replacementPanelId, markdownPanel.id)
        XCTAssertEqual(replacementMarkdown.filePath, markdownPanel.filePath)
        XCTAssertEqual(workspace.selectedSurfaceId(inPane: sourcePaneId), replacementPanelId)
    }

    func testSplitPaneMovingTabHandlerDoesNotCreateReplacementWhenSourcePaneStillHasOtherTabs() {
        let workspace = Workspace()
        guard let sourcePaneId = workspace.focusedPaneId,
              let sourcePanelId = workspace.focusedPanelId,
              let remainingPanel = workspace.createTerminalPanel(inPane: sourcePaneId, focus: false) else {
            XCTFail("Expected source pane to contain two terminal tabs")
            return
        }

        guard let newPaneId = workspace.layoutInteractionHandlers.splitPaneMovingTabHandler(
            sourcePaneId,
            .vertical,
            TabID(id: sourcePanelId),
            false,
            true
        ) else {
            XCTFail("Expected split to succeed")
            return
        }

        XCTAssertEqual(workspace.surfaceIds(inPane: sourcePaneId), [remainingPanel.id])
        XCTAssertEqual(workspace.surfaceIds(inPane: newPaneId), [sourcePanelId])
    }

    func testSplitSurfaceDoesNotApplyDragReplacementSemantics() {
        let workspace = Workspace()
        guard let sourcePaneId = workspace.focusedPaneId,
              let originalTerminalId = workspace.focusedPanelId,
              let browserPanel = workspace.createBrowserPanel(inPane: sourcePaneId, focus: true) else {
            XCTFail("Expected initial pane and browser surface")
            return
        }

        XCTAssertTrue(workspace.closePanel(originalTerminalId, force: true), "Expected bootstrap terminal to close")
        drainMainQueue()
        drainMainQueue()

        guard let newPaneId = workspace.splitSurface(
            panelId: browserPanel.id,
            inPane: sourcePaneId,
            orientation: .vertical,
            insertFirst: false,
            focusNewPane: true
        ) else {
            XCTFail("Expected direct splitSurface call to succeed")
            return
        }

        XCTAssertEqual(
            workspace.surfaceIds(inPane: sourcePaneId).count,
            0,
            "Expected pure splitSurface to avoid drag-only replacement behavior"
        )
        XCTAssertEqual(workspace.surfaceIds(inPane: newPaneId), [browserPanel.id])
    }

    func testClosingFocusedSplitRestoresBranchForRemainingFocusedPanel() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: firstPanelId, branch: "main", isDirty: false)
        guard let secondPanel = workspace.splitTerminalPanel(fromPanelId: firstPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }

        workspace.updatePanelGitBranch(panelId: secondPanel.id, branch: "feature/bugfix", isDirty: true)
        XCTAssertEqual(workspace.focusedPanelId, secondPanel.id, "Expected split panel to be focused")
        XCTAssertEqual(workspace.gitBranch?.branch, "feature/bugfix")
        XCTAssertEqual(workspace.gitBranch?.isDirty, true)

        XCTAssertTrue(workspace.closePanel(secondPanel.id, force: true), "Expected split panel close to succeed")
        XCTAssertEqual(workspace.focusedPanelId, firstPanelId, "Expected surviving panel to become focused")
        XCTAssertEqual(workspace.gitBranch?.branch, "main")
        XCTAssertEqual(workspace.gitBranch?.isDirty, false)
    }

    func testSidebarGitBranchesFollowLeftToRightSplitOrder() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "main", isDirty: false)
        guard let rightPanel = workspace.splitTerminalPanel(fromPanelId: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "feature/sidebar", isDirty: true)

        let ordered = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(ordered.map(\.branch), ["main", "feature/sidebar"])
        XCTAssertEqual(ordered.map(\.isDirty), [false, true])
    }

    func testUpdatingFocusedPanelGitBranchWithSameStateDoesNotRepublishWorkspace() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        var publishCount = 0
        let cancellable = workspace.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        let baselinePublishCount = publishCount

        XCTAssertGreaterThan(
            baselinePublishCount,
            0,
            "Expected the first focused branch update to publish workspace changes"
        )

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)

        XCTAssertEqual(
            publishCount,
            baselinePublishCount,
            "Expected identical focused branch refreshes to avoid extra workspace publishes"
        )
    }

    func testUpdatingFocusedPanelPullRequestWithSameStateDoesNotRepublishWorkspace() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/sidebar-pr", isDirty: false)

        var publishCount = 0
        let cancellable = workspace.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let pullRequestURL = URL(string: "https://github.com/manaflow-ai/cmux/pull/2388")!
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2388,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: "feature/sidebar-pr"
        )
        let baselinePublishCount = publishCount

        XCTAssertGreaterThan(
            baselinePublishCount,
            0,
            "Expected the first focused pull request update to publish workspace changes"
        )

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2388,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: "feature/sidebar-pr"
        )

        XCTAssertEqual(
            publishCount,
            baselinePublishCount,
            "Expected identical focused pull request refreshes to avoid extra workspace publishes"
        )
    }

    func testSidebarObservationPublisherEmitsForFocusedGitBranchChangesOnlyOncePerState() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        let baselinePublishCount = publishCount
        XCTAssertGreaterThan(
            baselinePublishCount,
            0,
            "Expected focused git branch updates to invalidate sidebar rows"
        )

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        XCTAssertEqual(
            publishCount,
            baselinePublishCount,
            "Expected identical git metadata refreshes to be ignored by sidebar rows"
        )
    }

    func testSidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        XCTAssertEqual(
            publishCount,
            0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }

    @MainActor
    func testSidebarPullRequestsTrackFocusedPanelOnly() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: firstPanelId),
              let secondPanel = workspace.createTerminalPanel(inPane: paneId, focus: false) else {
            XCTFail("Expected focused panel and a second panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: firstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: secondPanel.id, branch: "feature/sidebar-pr", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: secondPanel.id,
            number: 1629,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/1629")!,
            status: .open
        )

        XCTAssertNil(workspace.pullRequest)
        XCTAssertTrue(
            workspace.sidebarPullRequestsInDisplayOrder().isEmpty,
            "Expected background panel PRs to stay hidden while the focused panel has no PR"
        )

        workspace.focusPanel(secondPanel.id)

        XCTAssertEqual(
            workspace.sidebarPullRequestsInDisplayOrder().map(\.number),
            [1629]
        )
    }

    func testSidebarOrderingUsesPaneOrderThenTabOrderWithBranchDeduping() {
        let workspace = Workspace()
        guard let leftFirstPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftFirstPanelId),
              let rightFirstPanel = workspace.splitTerminalPanel(fromPanelId: leftFirstPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightFirstPanel.id),
              let leftSecondPanel = workspace.createTerminalPanel(inPane: leftPaneId, focus: false),
              let rightSecondPanel = workspace.createTerminalPanel(inPane: rightPaneId, focus: false) else {
            XCTFail("Expected panes and panels for ordering test")
            return
        }

        XCTAssertTrue(workspace.reorderSurface(panelId: leftFirstPanelId, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: leftSecondPanel.id, toIndex: 1))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightFirstPanel.id, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightSecondPanel.id, toIndex: 1))

        workspace.updatePanelGitBranch(panelId: leftFirstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: leftSecondPanel.id, branch: "feature/left", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightFirstPanel.id, branch: "main", isDirty: true)
        workspace.updatePanelGitBranch(panelId: rightSecondPanel.id, branch: "feature/right", isDirty: false)

        XCTAssertEqual(
            workspace.sidebarOrderedPanelIds(),
            [leftFirstPanelId, leftSecondPanel.id, rightFirstPanel.id, rightSecondPanel.id]
        )

        let branches = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(branches.map(\.branch), ["main", "feature/left", "feature/right"])
        XCTAssertEqual(branches.map(\.isDirty), [true, false, false])
    }

    func testSidebarBranchDirectoryEntriesStayStableAcrossFocusedSplitChanges() {
        let workspace = Workspace()
        let leftLiveDirectory = "/repo/left/live"
        let rightFocusedDirectory = "/repo/right/focused"
        let leftFocusedDirectory = "/repo/left/focused"
        let rightRequestedDirectory = "/repo/right/requested"

        guard let leftPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelDirectory(panelId: leftPanelId, directory: leftLiveDirectory)

        guard let rightSplitPanel = workspace.splitTerminalPanel(fromPanelId: leftPanelId,
            orientation: .horizontal,
            focus: false
        ),
        let rightPaneId = workspace.paneId(forPanelId: rightSplitPanel.id),
        let rightRequestedPanel = workspace.createTerminalPanel(
            inPane: rightPaneId,
            focus: false,
            workingDirectory: rightRequestedDirectory
        ) else {
            XCTFail("Expected right split panes for sidebar directory ordering test")
            return
        }

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        XCTAssertEqual(orderedPanelIds, [leftPanelId, rightSplitPanel.id, rightRequestedPanel.id])

        workspace.currentDirectory = rightFocusedDirectory
        let entriesWhenRightLooksFocused = workspace.sidebarBranchDirectoryEntriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds
        )

        workspace.currentDirectory = leftFocusedDirectory
        let entriesWhenLeftLooksFocused = workspace.sidebarBranchDirectoryEntriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds
        )

        XCTAssertEqual(
            entriesWhenRightLooksFocused,
            entriesWhenLeftLooksFocused,
            "Expected sidebar directory ordering to ignore focused-workspace cwd churn when panel-specific directories are available"
        )
        XCTAssertEqual(
            entriesWhenRightLooksFocused.map(\.directory),
            [leftLiveDirectory, rightRequestedDirectory]
        )
    }

    func testRemoteSidebarDirectoryCanonicalizationDedupesTildeAndAbsoluteHomePaths() {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )

        let liveDirectory = "/home/remoteuser/project"
        let requestedDirectory = "~/project"

        guard let firstPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: firstPanelId),
              let requestedPanel = workspace.createTerminalPanel(
                  inPane: paneId,
                  focus: false,
                  workingDirectory: requestedDirectory
              ) else {
            XCTFail("Expected remote panels for sidebar directory canonicalization test")
            return
        }

        workspace.updatePanelDirectory(panelId: firstPanelId, directory: liveDirectory)

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        XCTAssertEqual(orderedPanelIds, [firstPanelId, requestedPanel.id])

        XCTAssertEqual(
            workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds),
            [liveDirectory]
        )
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds).map(\.directory),
            [liveDirectory]
        )
    }

    func testSidebarDerivedCollectionsMatchWhenUsingPrecomputedPanelOrder() {
        let workspace = Workspace()
        guard let leftFirstPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftFirstPanelId),
              let rightFirstPanel = workspace.splitTerminalPanel(fromPanelId: leftFirstPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightFirstPanel.id),
              let leftSecondPanel = workspace.createTerminalPanel(inPane: leftPaneId, focus: false),
              let rightSecondPanel = workspace.createTerminalPanel(inPane: rightPaneId, focus: false) else {
            XCTFail("Expected panes and panels for precomputed ordering test")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftFirstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: leftSecondPanel.id, branch: "feature/left", isDirty: true)
        workspace.updatePanelGitBranch(panelId: rightFirstPanel.id, branch: "release/right", isDirty: false)

        workspace.updatePanelDirectory(panelId: leftFirstPanelId, directory: "/repo/left/root")
        workspace.updatePanelDirectory(panelId: leftSecondPanel.id, directory: "/repo/left/feature")
        workspace.updatePanelDirectory(panelId: rightFirstPanel.id, directory: "/repo/right/root")
        workspace.updatePanelDirectory(panelId: rightSecondPanel.id, directory: "/repo/right/extra")

        workspace.updatePanelPullRequest(
            panelId: leftFirstPanelId,
            number: 101,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/101")!,
            status: .open
        )
        workspace.updatePanelPullRequest(
            panelId: rightFirstPanel.id,
            number: 18,
            label: "MR",
            url: URL(string: "https://gitlab.com/manaflow/cmux/-/merge_requests/18")!,
            status: .merged
        )

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()

        XCTAssertEqual(
            workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { "\($0.branch)|\($0.isDirty)" },
            workspace.sidebarGitBranchesInDisplayOrder().map { "\($0.branch)|\($0.isDirty)" }
        )
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds),
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder()
        )
        XCTAssertEqual(
            workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds),
            workspace.sidebarPullRequestsInDisplayOrder()
        )
    }

    func testClosingPaneDropsBranchesFromClosedSide() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId),
              let rightPanel = workspace.splitTerminalPanel(fromPanelId: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected left/right split panes")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "branch1", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "branch2", isDirty: false)

        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch1", "branch2"])
        XCTAssertTrue(workspace.closePane(leftPaneId))
        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch2"])
    }
}


@MainActor
final class SidebarWorkspaceShortcutHintMetricsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SidebarWorkspaceShortcutHintMetrics.resetCacheForTesting()
    }

    override func tearDown() {
        SidebarWorkspaceShortcutHintMetrics.resetCacheForTesting()
        super.tearDown()
    }

    func testHintWidthCachesRepeatedMeasurements() {
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 0)

        let first = SidebarWorkspaceShortcutHintMetrics.hintWidth(for: "⌘1")
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 1)

        let second = SidebarWorkspaceShortcutHintMetrics.hintWidth(for: "⌘1")
        XCTAssertEqual(second, first)
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 1)

        _ = SidebarWorkspaceShortcutHintMetrics.hintWidth(for: "⌘2")
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 2)
    }

    func testSlotWidthAppliesMinimumAndDebugInset() {
        let nilLabelWidth = SidebarWorkspaceShortcutHintMetrics.slotWidth(label: nil, debugXOffset: 999)
        XCTAssertEqual(nilLabelWidth, 28)

        let base = SidebarWorkspaceShortcutHintMetrics.slotWidth(label: "⌘1", debugXOffset: 0)
        let widened = SidebarWorkspaceShortcutHintMetrics.slotWidth(label: "⌘1", debugXOffset: 10)
        XCTAssertGreaterThan(widened, base)
    }
}
