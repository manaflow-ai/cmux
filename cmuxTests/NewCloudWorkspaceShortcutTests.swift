import AppKit
import CmuxSettings
import Foundation
import XCTest
import CmuxCloudMachines

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// New Cloud Workspace (Cmd+Y): the shortcut catalog entry, the plus-menu
/// rows with their live shortcut hints, and the shared action every
/// entrypoint routes through.
@MainActor
final class NewCloudWorkspaceShortcutTests: XCTestCase {
    private final class RecordingSheetPresenter: NewMachineSheetPresenting {
        private(set) var presentCount = 0
        private(set) var lastWindow: NSWindow?
        func presentNewMachineFetchingPlan(preferredWindow: NSWindow?) async -> UUID? {
            presentCount += 1
            lastWindow = preferredWindow
            return nil
        }
    }

    private func installDependencies(on appDelegate: AppDelegate, presenter: RecordingSheetPresenter, signedIn: Bool = true) {
        let defaults = UserDefaults(suiteName: "CloudShortcutTests.\(UUID().uuidString)")!
        let store = DefaultCloudMachineStore(defaults: defaults)
        appDelegate.cloudWorkspaceCoordinator = CloudWorkspaceCoordinator(
            defaultMachineStore: store,
            allowsOperation: { CloudMachinesFeature.isEnabled && signedIn },
            loadMachines: { [CloudMachineDescriptor(id: "starred", isDesktop: true)] },
            createWorkspace: { _, _ in UUID() }
        )
        appDelegate.newMachineSheetPresenter = presenter
        appDelegate.cloudWorkspaceOperationController = CloudWorkspaceOperationController(
            isAvailable: { CloudMachinesFeature.isEnabled && signedIn }
        )
    }

    private var originalFileStore: KeyboardShortcutSettingsFileStore?
    private var originalCloudOptIn: Any?
    private var originalCloudRemoteOverride: Bool?
    private var originalBrowserDisabled: Any?

    override func setUp() {
        super.setUp()
        originalFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "new-cloud-workspace")
        let defaults = UserDefaults.standard
        originalCloudOptIn = defaults.object(forKey: Self.cloudOptInKey)
        originalBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
        if let definition = Self.cloudRemoteFlag {
            originalCloudRemoteOverride = CmuxFeatureFlags.shared.overrideValue(for: definition)
            CmuxFeatureFlags.shared.setOverride(false, for: definition)
        }
    }

    override func tearDown() {
        KeyboardShortcutSettings.resetShortcut(for: .newCloudWorkspace)
        if let originalFileStore {
            KeyboardShortcutSettings.settingsFileStore = originalFileStore
        }
        let defaults = UserDefaults.standard
        if let originalCloudOptIn {
            defaults.set(originalCloudOptIn, forKey: Self.cloudOptInKey)
        } else {
            defaults.removeObject(forKey: Self.cloudOptInKey)
        }
        if let originalBrowserDisabled {
            defaults.set(originalBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey)
        } else {
            defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
        }
        if let definition = Self.cloudRemoteFlag {
            CmuxFeatureFlags.shared.setOverride(originalCloudRemoteOverride, for: definition)
        }
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
        super.tearDown()
    }

    private static let cloudOptInKey = BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey
    private static var cloudRemoteFlag: CmuxFeatureFlagDefinition? {
        CmuxFeatureFlags.allFlags.first { $0.key == "cloud-vm-ui-enabled-release" }
    }

    private func setCloudMachinesEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.cloudOptInKey)
        XCTAssertEqual(CloudMachinesFeature.isEnabled, enabled)
    }

    // MARK: Shortcut catalog

    func testDefaultShortcutIsCommandYAndDoesNotCollide() {
        let action = KeyboardShortcutSettings.Action.newCloudWorkspace
        XCTAssertEqual(action.label, "New Cloud Workspace")
        XCTAssertEqual(action.defaultsKey, "shortcut.newCloudWorkspace")
        XCTAssertTrue(KeyboardShortcutSettings.publicShortcutActions.contains(action))
        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(action))

        let shortcut = action.defaultShortcut
        XCTAssertEqual(shortcut.key, "y")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
        XCTAssertEqual(shortcut.displayString, "⌘Y")

        for other in KeyboardShortcutSettings.Action.allCases where other != action {
            let otherDefault = other.defaultShortcut
            guard !otherDefault.isUnbound else { continue }
            XCTAssertNotEqual(otherDefault, shortcut, "\(other) also defaults to ⌘Y")
        }
    }

    func testNewCloudMachineUsesCommandShiftY() {
        let action = KeyboardShortcutSettings.Action.newCloudMachine
        XCTAssertEqual(action.defaultShortcut, StoredShortcut(key: "y", command: true, shift: true, option: false, control: false))
        XCTAssertEqual(action.label, "New Cloud Machine")
    }

    func testSettingsPackageActionStaysAligned() throws {
        let settingsAction = try XCTUnwrap(
            ShortcutAction(rawValue: KeyboardShortcutSettings.Action.newCloudWorkspace.rawValue)
        )
        XCTAssertEqual(settingsAction.defaultStroke, ShortcutStroke(key: "y", command: true))
        XCTAssertEqual(settingsAction.displayName, KeyboardShortcutSettings.Action.newCloudWorkspace.label)
        XCTAssertEqual(settingsAction.group, .workspace)
        XCTAssertTrue(ShortcutAction.settingsVisibleActions.contains(settingsAction))
    }

    func testRebindPersistsThroughSettingsAPI() {
        let rebound = StoredShortcut(key: "k", command: true, shift: true, option: false, control: false)
        KeyboardShortcutSettings.setShortcut(rebound, for: .newCloudWorkspace)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newCloudWorkspace), rebound)
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .newCloudWorkspace), rebound)

        KeyboardShortcutSettings.setShortcut(.unbound, for: .newCloudWorkspace)
        XCTAssertTrue(KeyboardShortcutSettings.shortcut(for: .newCloudWorkspace).isUnbound)

        KeyboardShortcutSettings.resetShortcut(for: .newCloudWorkspace)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newCloudWorkspace).key, "y")
    }

    func testBuiltInActionResolvesFromConfigAndMapsToShortcut() {
        XCTAssertEqual(CmuxSurfaceTabBarBuiltInAction(configID: "cmux.newCloudWorkspace"), .newCloudWorkspace)
        XCTAssertEqual(CmuxSurfaceTabBarBuiltInAction(configID: "newCloudWorkspace"), .newCloudWorkspace)
        XCTAssertEqual(CmuxSurfaceTabBarBuiltInAction(configID: "cmux.newCloudMachine"), .newCloudMachine)
        XCTAssertEqual(CmuxSurfaceTabBarBuiltInAction.newCloudWorkspace.shortcutAction, .newCloudWorkspace)
        XCTAssertEqual(CmuxSurfaceTabBarBuiltInAction.newCloudMachine.shortcutAction, .newCloudMachine)
        XCTAssertEqual(CmuxSurfaceTabBarBuiltInAction.newWorkspace.shortcutAction, .newTab)
        XCTAssertEqual(CmuxSurfaceTabBarBuiltInAction.newTerminal.shortcutAction, .newSurface)
        XCTAssertEqual(CmuxSurfaceTabBarBuiltInAction.newBrowser.shortcutAction, .openBrowser)
        XCTAssertNil(CmuxSurfaceTabBarBuiltInAction.cloudVM.shortcutAction)
    }

    // MARK: Plus menu

    private func loadStore(globalJSON: String) throws -> (store: CmuxConfigStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-new-cloud-workspace-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let globalConfigURL = root.appendingPathComponent("cmux.json")
        try globalJSON.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        store.loadAll()
        return (store, root)
    }

    private func builtInMenuRows(_ menu: NSMenu) -> [(action: CmuxSurfaceTabBarBuiltInAction, item: NSMenuItem)] {
        menu.items.compactMap { item in
            guard let box = item.representedObject as? NewWorkspaceContextMenuActionBox,
                  case .builtIn(let builtIn) = box.action.action else { return nil }
            return (builtIn, item)
        }
    }

    private func withDefaultPlusMenu<T>(_ body: (NSMenu) throws -> T) throws -> T {
        let (store, root) = try loadStore(globalJSON: "{}")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(store.newWorkspaceContextMenuIsConfigured)
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            cmuxConfigStore: store
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let context = try XCTUnwrap(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })
        let menu = try XCTUnwrap(appDelegate.makeNewWorkspaceContextMenu(context: context, cmuxConfigStore: store))
        return try body(menu)
    }

    func testDefaultPlusMenuListsStandardRowsWithShortcutHints() throws {
        setCloudMachinesEnabled(true)
        try withDefaultPlusMenu { menu in
            let rows = builtInMenuRows(menu)
            let leading = rows.prefix(5).map(\.action)
            XCTAssertEqual(leading, [.newWorkspace, .newCloudWorkspace, .newCloudMachine, .newTerminal, .newBrowser])

            let hints = Dictionary(uniqueKeysWithValues: rows.map { ($0.action, $0.item) })
            XCTAssertEqual(hints[.newWorkspace]?.keyEquivalent, "n")
            XCTAssertEqual(hints[.newWorkspace]?.keyEquivalentModifierMask, [.command])
            XCTAssertEqual(hints[.newCloudWorkspace]?.keyEquivalent, "y")
            XCTAssertEqual(hints[.newCloudWorkspace]?.keyEquivalentModifierMask, [.command])
            XCTAssertEqual(hints[.newCloudMachine]?.keyEquivalent, "y")
            XCTAssertEqual(hints[.newCloudMachine]?.keyEquivalentModifierMask, [.command, .shift])
            XCTAssertEqual(hints[.newTerminal]?.keyEquivalent, "t")
            XCTAssertEqual(hints[.newTerminal]?.keyEquivalentModifierMask, [.command])
            XCTAssertEqual(hints[.newBrowser]?.keyEquivalent, "l")
            XCTAssertEqual(hints[.newBrowser]?.keyEquivalentModifierMask, [.command, .shift])
            XCTAssertEqual(
                hints[.newCloudWorkspace]?.title,
                String(localized: "command.newCloudWorkspace.title", defaultValue: "New Cloud Workspace")
            )
        }
    }

    func testPlusMenuHintFollowsRebindAndUnbind() throws {
        setCloudMachinesEnabled(true)
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: true, option: false, control: false),
            for: .newCloudWorkspace
        )
        try withDefaultPlusMenu { menu in
            let item = try XCTUnwrap(builtInMenuRows(menu).first { $0.action == .newCloudWorkspace }?.item)
            XCTAssertEqual(item.keyEquivalent, "k")
            XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        }

        KeyboardShortcutSettings.setShortcut(.unbound, for: .newCloudWorkspace)
        try withDefaultPlusMenu { menu in
            let item = try XCTUnwrap(builtInMenuRows(menu).first { $0.action == .newCloudWorkspace }?.item)
            XCTAssertEqual(item.keyEquivalent, "")
            XCTAssertEqual(item.keyEquivalentModifierMask, [])
        }
    }

    func testPlusMenuHidesCloudRowWhenFeatureIsOff() throws {
        setCloudMachinesEnabled(false)
        try withDefaultPlusMenu { menu in
            let actions = builtInMenuRows(menu).map(\.action)
            XCTAssertFalse(actions.contains(.newCloudWorkspace))
            XCTAssertEqual(actions.prefix(3).map { $0 }, [.newWorkspace, .newTerminal, .newBrowser])
        }
    }

    func testPlusMenuHidesBrowserRowWhenBrowserIsDisabled() throws {
        setCloudMachinesEnabled(true)
        UserDefaults.standard.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
        try withDefaultPlusMenu { menu in
            let actions = builtInMenuRows(menu).map(\.action)
            XCTAssertFalse(actions.contains(.newBrowser))
            XCTAssertTrue(actions.contains(.newCloudWorkspace))
        }
    }

    func testConfiguredMenuKeepsUserOrderAndStillShowsHints() throws {
        setCloudMachinesEnabled(true)
        let (store, root) = try loadStore(globalJSON: """
        {
          "ui": { "newWorkspace": { "contextMenu": ["cmux.newTerminal", "newCloudWorkspace"] } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(store.configurationIssues.isEmpty)
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager, cmuxConfigStore: store)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let context = try XCTUnwrap(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })
        let menu = try XCTUnwrap(appDelegate.makeNewWorkspaceContextMenu(context: context, cmuxConfigStore: store))
        let rows = builtInMenuRows(menu)
        XCTAssertEqual(rows.prefix(2).map(\.action), [.newTerminal, .newCloudWorkspace])
        XCTAssertEqual(rows[1].item.keyEquivalent, "y")
    }

    // MARK: Shared action path

    func testPlusMenuMachineRowExecutesSharedAction() async throws {
        setCloudMachinesEnabled(true)
        let presenter = RecordingSheetPresenter()

        let (store, root) = try loadStore(globalJSON: "{}")
        defer { try? FileManager.default.removeItem(at: root) }
        let appDelegate = AppDelegate()
        installDependencies(on: appDelegate, presenter: presenter)
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager, cmuxConfigStore: store)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let context = try XCTUnwrap(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })

        XCTAssertTrue(appDelegate.executeConfiguredCmuxAction(.builtIn(.newCloudMachine), context: context))
        await appDelegate.cloudWorkspaceOperationController?.waitForPendingOperations()
        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testSharedActionDoesNotPresentSheetWhenFeatureIsOff() {
        setCloudMachinesEnabled(false)
        let presenter = RecordingSheetPresenter()
        let appDelegate = AppDelegate()
        installDependencies(on: appDelegate, presenter: presenter)
        XCTAssertFalse(appDelegate.performNewCloudWorkspaceAction(debugSource: "test.featureOff"))
        XCTAssertEqual(presenter.presentCount, 0)
    }

    func testSharedActionDoesNotPresentSheetWhenSignedOut() {
        setCloudMachinesEnabled(true)
        let presenter = RecordingSheetPresenter()
        let appDelegate = AppDelegate()
        installDependencies(on: appDelegate, presenter: presenter, signedIn: false)
        XCTAssertFalse(appDelegate.performNewCloudWorkspaceAction(debugSource: "test.signedOut"))
        XCTAssertEqual(presenter.presentCount, 0)
    }

    func testCommandYRoutesThroughSharedAction() async throws {
#if DEBUG
        let appDelegate = AppDelegate()
        setCloudMachinesEnabled(true)
        let presenter = RecordingSheetPresenter()
        installDependencies(on: appDelegate, presenter: presenter)
        KeyboardShortcutSettings.resetShortcut(for: .newCloudWorkspace)
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
            context: nil,
            characters: "y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: 16 // kVK_ANSI_Y
        ))
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
        await appDelegate.cloudWorkspaceOperationController?.waitForPendingOperations()
        XCTAssertEqual(presenter.presentCount, 0)
#else
        throw XCTSkip("Shortcut routing seam is DEBUG-only")
#endif
    }

    func testCommandYCoalescesOneCreateAndOpenIntentUntilItFinishes() async throws {
#if DEBUG
        let appDelegate = AppDelegate()
        setCloudMachinesEnabled(true)
        let presenter = RecordingSheetPresenter()
        let defaults = UserDefaults(suiteName: "CloudShortcutCoalescingTests.\(UUID().uuidString)")!
        let store = DefaultCloudMachineStore(defaults: defaults)
        var createCount = 0
        var releaseCreate: CheckedContinuation<Void, Never>?
        appDelegate.cloudWorkspaceCoordinator = CloudWorkspaceCoordinator(
            defaultMachineStore: store,
            allowsOperation: { true },
            loadMachines: { [CloudMachineDescriptor(id: "starred", isDesktop: true)] },
            createWorkspace: { _, _ in
                createCount += 1
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseCreate = continuation
                }
                return UUID()
            }
        )
        appDelegate.newMachineSheetPresenter = presenter
        appDelegate.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { true })

        XCTAssertTrue(appDelegate.performNewCloudWorkspaceOnDefaultMachineAction(debugSource: "test.first"))
        XCTAssertFalse(
            appDelegate.performNewCloudWorkspaceOnDefaultMachineAction(debugSource: "test.duplicate"),
            "a second Cmd+Y must not create another remote workspace while the first is attaching"
        )
        for _ in 0..<20 where releaseCreate == nil {
            await Task.yield()
        }
        XCTAssertEqual(createCount, 1)
        guard let releaseCreate else {
            appDelegate.cloudWorkspaceOperationController?.cancelAll()
            XCTFail("the first create operation did not reach its receipt gate")
            return
        }
        releaseCreate.resume()
        await appDelegate.cloudWorkspaceOperationController?.waitForPendingOperations()
        XCTAssertEqual(presenter.presentCount, 0)
#else
        throw XCTSkip("Shortcut routing seam is DEBUG-only")
#endif
    }

    func testReboundKeyRoutesAndOldKeyDoesNot() async throws {
#if DEBUG
        let appDelegate = AppDelegate()
        setCloudMachinesEnabled(true)
        let presenter = RecordingSheetPresenter()
        installDependencies(on: appDelegate, presenter: presenter)
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: true, option: false, control: false),
            for: .newCloudWorkspace
        )
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        func keyEvent(_ characters: String, _ modifiers: NSEvent.ModifierFlags, _ keyCode: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
        }

        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: try keyEvent("y", [.command], 16)))
        XCTAssertEqual(presenter.presentCount, 0, "the old ⌘Y binding must not fire after a rebind")

        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: try keyEvent("K", [.command, .shift], 40)))
        await appDelegate.cloudWorkspaceOperationController?.waitForPendingOperations()
        XCTAssertEqual(presenter.presentCount, 0)
#else
        throw XCTSkip("Shortcut routing seam is DEBUG-only")
#endif
    }

    func testCommandPaletteNewMachineAdvertisesShortcut() {
        XCTAssertEqual(
            ContentView.commandPaletteShortcutAction(forCommandID: ContentView.commandPaletteCloudNewMachineCommandId),
            .newCloudMachine
        )
    }

}
