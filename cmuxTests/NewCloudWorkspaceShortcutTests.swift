import AppKit
import CmuxCloudMachines
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// New Cloud Workspace (Cmd+Shift+Y): the shortcut catalog entry, the plus-menu
/// rows with their live shortcut hints, and the shared action every
/// entrypoint routes through.
@MainActor
@Suite(.serialized)
final class NewCloudWorkspaceShortcutTests {
    private final class RecordingSheetPresenter: NewMachineSheetPresenting {
        private(set) var presentCount = 0
        private(set) var lastWindow: NSWindow?
        func presentNewMachineFetchingPlan(preferredWindow: NSWindow?, onReservation: @escaping @MainActor (UUID) -> Void) async -> UUID? {
            presentCount += 1
            lastWindow = preferredWindow
            return nil
        }
    }

    private var preferenceSuites: [String] = []
    private func pinStore(signedIn: Bool = true) -> CloudMachinePinStore {
        let suite = "cloud-shortcut-\(UUID().uuidString)"
        preferenceSuites.append(suite)
        return CloudMachinePinStore(defaults: UserDefaults(suiteName: suite)!, scopeProvider: { signedIn ? "scope" : nil })
    }

    private func installDependencies(on appDelegate: AppDelegate, presenter: RecordingSheetPresenter, signedIn: Bool = true) {
        appDelegate.cloudWorkspaceCoordinator = CloudWorkspaceCoordinator(
            machinePinStore: pinStore(signedIn: signedIn),
            allowsOperation: { CloudMachinesFeature.isEnabled && signedIn },
            loadMachines: { ["machine-a"] }, createWorkspace: { _ in UUID() }
        )
        appDelegate.newMachineSheetPresenter = presenter
        appDelegate.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { CloudMachinesFeature.isEnabled && signedIn })
    }

    private var originalFileStore: KeyboardShortcutSettingsFileStore?
    private var originalCloudOptIn: Any?
    private var originalCloudRemoteOverride: Bool?
    private var originalBrowserDisabled: Any?

    init() {
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

    // Explicit cleanup keeps shared settings restored before the serialized test finishes.
    private func restoreState() {
        for suite in preferenceSuites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
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
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
    }

    private static let cloudOptInKey = BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey
    private static var cloudRemoteFlag: CmuxFeatureFlagDefinition? {
        CmuxFeatureFlags.allFlags.first { $0.key == "cloud-machines-enabled-release" }
    }

    private func setCloudMachinesEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.cloudOptInKey)
        if let definition = Self.cloudRemoteFlag {
            CmuxFeatureFlags.shared.setOverride(enabled, for: definition)
        }
        #expect(CloudMachinesFeature.isEnabled == enabled)
    }

    // MARK: Shortcut catalog

    @Test func testDefaultShortcutIsShiftCommandYAndDoesNotCollide() {
        defer { restoreState() }
        let action = KeyboardShortcutSettings.Action.newCloudWorkspace
        #expect(action.label == "New Cloud Workspace")
        #expect(action.defaultsKey == "shortcut.newCloudWorkspace")
        #expect(KeyboardShortcutSettings.publicShortcutActions.contains(action))
        #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(action))

        let shortcut = action.defaultShortcut
        #expect(shortcut.key == "y")
        #expect(shortcut.command)
        #expect(shortcut.shift)
        #expect(!shortcut.option)
        #expect(!shortcut.control)
        #expect(shortcut.displayString == "⇧⌘Y")

        for other in KeyboardShortcutSettings.Action.allCases where other != action {
            let otherDefault = other.defaultShortcut
            guard !otherDefault.isUnbound else { continue }
            #expect(otherDefault != shortcut, "\(other) also defaults to ⌘Y")
        }
    }

    @Test func testNewCloudMachineUsesCommandY() {
        defer { restoreState() }
        let action = KeyboardShortcutSettings.Action.newCloudMachine
        #expect(action.defaultShortcut == StoredShortcut(key: "y", command: true, shift: false, option: false, control: false))
        #expect(action.label == "New Cloud Machine")
    }

    @Test func testSettingsPackageActionStaysAligned() throws {
        defer { restoreState() }
        let settingsAction = try #require(
            ShortcutAction(rawValue: KeyboardShortcutSettings.Action.newCloudWorkspace.rawValue)
        )
        #expect(settingsAction.defaultStroke == ShortcutStroke(key: "y", command: true, shift: true))
        #expect(settingsAction.displayName == KeyboardShortcutSettings.Action.newCloudWorkspace.label)
        #expect(settingsAction.group == .workspace)
        #expect(ShortcutAction.settingsVisibleActions.contains(settingsAction))
    }

    @Test func testRebindPersistsThroughSettingsAPI() {
        defer { restoreState() }
        let rebound = StoredShortcut(key: "k", command: true, shift: true, option: false, control: false)
        KeyboardShortcutSettings.setShortcut(rebound, for: .newCloudWorkspace)
        #expect(KeyboardShortcutSettings.shortcut(for: .newCloudWorkspace) == rebound)
        #expect(KeyboardShortcutSettings.menuShortcut(for: .newCloudWorkspace) == rebound)

        KeyboardShortcutSettings.setShortcut(.unbound, for: .newCloudWorkspace)
        #expect(KeyboardShortcutSettings.shortcut(for: .newCloudWorkspace).isUnbound)

        KeyboardShortcutSettings.resetShortcut(for: .newCloudWorkspace)
        #expect(KeyboardShortcutSettings.shortcut(for: .newCloudWorkspace).key == "y")
    }

    @Test func testBuiltInActionResolvesFromConfigAndMapsToShortcut() {
        defer { restoreState() }
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "cmux.newCloudWorkspace") == .newCloudWorkspace)
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "newCloudWorkspace") == .newCloudWorkspace)
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "cmux.newCloudMachine") == .newCloudMachine)
        #expect(CmuxSurfaceTabBarBuiltInAction.newCloudWorkspace.shortcutAction == .newCloudWorkspace)
        #expect(CmuxSurfaceTabBarBuiltInAction.newCloudMachine.shortcutAction == .newCloudMachine)
        #expect(CmuxSurfaceTabBarBuiltInAction.newWorkspace.shortcutAction == .newTab)
        #expect(CmuxSurfaceTabBarBuiltInAction.newTerminal.shortcutAction == .newSurface)
        #expect(CmuxSurfaceTabBarBuiltInAction.newBrowser.shortcutAction == .openBrowser)
        #expect(CmuxSurfaceTabBarBuiltInAction.cloudVM.shortcutAction == nil)
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
        #expect(!store.newWorkspaceContextMenuIsConfigured)
        let appDelegate = AppDelegate()
        appDelegate.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { CloudMachinesFeature.isEnabled })
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            cmuxConfigStore: store
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let context = try #require(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })
        let menu = try #require(appDelegate.makeNewWorkspaceContextMenu(context: context, cmuxConfigStore: store))
        return try body(menu)
    }

    @Test func testDefaultPlusMenuListsStandardRowsWithShortcutHints() throws {
        defer { restoreState() }
        setCloudMachinesEnabled(true)
        try withDefaultPlusMenu { menu in
            let rows = builtInMenuRows(menu)
            let leading = rows.prefix(5).map(\.action)
            #expect(leading == [.newWorkspace, .newCloudWorkspace, .newCloudMachine, .newTerminal, .newBrowser])

            let hints = Dictionary(uniqueKeysWithValues: rows.map { ($0.action, $0.item) })
            #expect(hints[.newWorkspace]?.keyEquivalent == "n")
            #expect(hints[.newWorkspace]?.keyEquivalentModifierMask == [.command])
            #expect(hints[.newCloudWorkspace]?.keyEquivalent == "y")
            #expect(hints[.newCloudWorkspace]?.keyEquivalentModifierMask == [.command, .shift])
            #expect(hints[.newCloudMachine]?.keyEquivalent == "y")
            #expect(hints[.newCloudMachine]?.keyEquivalentModifierMask == [.command])
            #expect(hints[.newTerminal]?.keyEquivalent == "t")
            #expect(hints[.newTerminal]?.keyEquivalentModifierMask == [.command])
            #expect(hints[.newBrowser]?.keyEquivalent == "l")
            #expect(hints[.newBrowser]?.keyEquivalentModifierMask == [.command, .shift])
            #expect(hints[.newCloudWorkspace]?.title == String(localized: "command.newCloudWorkspace.title", defaultValue: "New Cloud Workspace"))
        }
    }

    @Test func testPlusMenuHintFollowsRebindAndUnbind() throws {
        defer { restoreState() }
        setCloudMachinesEnabled(true)
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: true, option: false, control: false),
            for: .newCloudWorkspace
        )
        try withDefaultPlusMenu { menu in
            let item = try #require(builtInMenuRows(menu).first { $0.action == .newCloudWorkspace }?.item)
            #expect(item.keyEquivalent == "k")
            #expect(item.keyEquivalentModifierMask == [.command, .shift])
        }

        KeyboardShortcutSettings.setShortcut(.unbound, for: .newCloudWorkspace)
        try withDefaultPlusMenu { menu in
            let item = try #require(builtInMenuRows(menu).first { $0.action == .newCloudWorkspace }?.item)
            #expect(item.keyEquivalent == "")
            #expect(item.keyEquivalentModifierMask == [])
        }
    }

    @Test func testPlusMenuHidesCloudRowWhenFeatureIsOff() throws {
        defer { restoreState() }
        setCloudMachinesEnabled(false)
        try withDefaultPlusMenu { menu in
            let actions = builtInMenuRows(menu).map(\.action)
            #expect(!actions.contains(.newCloudWorkspace))
            #expect(actions.prefix(3).map { $0 } == [.newWorkspace, .newTerminal, .newBrowser])
        }
    }

    @Test func testPlusMenuHidesBrowserRowWhenBrowserIsDisabled() throws {
        defer { restoreState() }
        setCloudMachinesEnabled(true)
        UserDefaults.standard.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
        try withDefaultPlusMenu { menu in
            let actions = builtInMenuRows(menu).map(\.action)
            #expect(!actions.contains(.newBrowser))
            #expect(actions.contains(.newCloudWorkspace))
        }
    }

    @Test func testConfiguredMenuKeepsUserOrderAndStillShowsHints() throws {
        defer { restoreState() }
        setCloudMachinesEnabled(true)
        let (store, root) = try loadStore(globalJSON: """
        {
          "ui": { "newWorkspace": { "contextMenu": ["cmux.newTerminal", "newCloudWorkspace"] } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.configurationIssues.isEmpty)
        let appDelegate = AppDelegate()
        appDelegate.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { CloudMachinesFeature.isEnabled })
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager, cmuxConfigStore: store)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let context = try #require(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })
        let menu = try #require(appDelegate.makeNewWorkspaceContextMenu(context: context, cmuxConfigStore: store))
        let rows = builtInMenuRows(menu)
        #expect(rows.prefix(2).map(\.action) == [.newTerminal, .newCloudWorkspace])
        #expect(rows[1].item.keyEquivalent == "y")
    }

    // MARK: Shared action path

    @Test func testPlusMenuMachineRowExecutesSharedAction() async throws {
        defer { restoreState() }
        setCloudMachinesEnabled(true)
        let presenter = RecordingSheetPresenter()

        let (store, root) = try loadStore(globalJSON: "{}")
        defer { try? FileManager.default.removeItem(at: root) }
        let appDelegate = AppDelegate()
        installDependencies(on: appDelegate, presenter: presenter)
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager, cmuxConfigStore: store)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let context = try #require(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })

        #expect(appDelegate.executeConfiguredCmuxAction(.builtIn(.newCloudMachine), context: context))
        await appDelegate.cloudWorkspaceOperationController?.waitForPendingOperations()
        #expect(presenter.presentCount == 1)
    }

    @Test func testSharedActionDoesNotPresentSheetWhenFeatureIsOff() {
        defer { restoreState() }
        setCloudMachinesEnabled(false)
        let presenter = RecordingSheetPresenter()
        let appDelegate = AppDelegate()
        installDependencies(on: appDelegate, presenter: presenter)
        #expect(!appDelegate.performNewCloudMachineAction(debugSource: "test.featureOff"))
        #expect(presenter.presentCount == 0)
    }

    @Test func testSharedActionDoesNotPresentSheetWhenSignedOut() {
        defer { restoreState() }
        setCloudMachinesEnabled(true)
        let presenter = RecordingSheetPresenter()
        let appDelegate = AppDelegate()
        installDependencies(on: appDelegate, presenter: presenter, signedIn: false)
        #expect(!appDelegate.performNewCloudMachineAction(debugSource: "test.signedOut"))
        #expect(presenter.presentCount == 0)
    }

#if DEBUG
    @Test func testCommandYRoutesThroughSharedMachineAction() async throws {
        defer { restoreState() }
        let appDelegate = AppDelegate()
        setCloudMachinesEnabled(true)
        let presenter = RecordingSheetPresenter()
        installDependencies(on: appDelegate, presenter: presenter)
        KeyboardShortcutSettings.resetShortcut(for: .newCloudWorkspace)
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        let event = try #require(NSEvent.keyEvent(
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
        #expect(appDelegate.debugHandleCustomShortcut(event: event))
        await appDelegate.cloudWorkspaceOperationController?.waitForPendingOperations()
        #expect(presenter.presentCount == 1)
    }
#endif

#if DEBUG
    @Test func testResolvedCloudWorkspaceCoalescesOneCreateAndOpenIntentUntilItFinishes() async throws {
        defer { restoreState() }
        let appDelegate = AppDelegate()
        setCloudMachinesEnabled(true)
        let presenter = RecordingSheetPresenter()
        var createCount = 0
        var releaseCreate: CheckedContinuation<Void, Never>?
        appDelegate.cloudWorkspaceCoordinator = CloudWorkspaceCoordinator(
            machinePinStore: pinStore(),
            allowsOperation: { true },
            loadMachines: { ["machine-a"] },
            createWorkspace: { _ in
                createCount += 1
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseCreate = continuation
                }
                return UUID()
            }
        )
        appDelegate.newMachineSheetPresenter = presenter
        appDelegate.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { true })
        let manager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowID) }

        #expect(appDelegate.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: manager, debugSource: "test.first"))
        #expect(!appDelegate.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: manager, debugSource: "test.duplicate"), "a second Cmd+Shift+Y must not create another remote workspace while the first is attaching")
        for _ in 0..<20 where releaseCreate == nil {
            await Task.yield()
        }
        #expect(createCount == 1)
        guard let releaseCreate else {
            appDelegate.cloudWorkspaceOperationController?.cancelAll()
            Issue.record("the first create operation did not reach its receipt gate")
            return
        }
        releaseCreate.resume()
        await appDelegate.cloudWorkspaceOperationController?.waitForPendingOperations()
        #expect(presenter.presentCount == 0)
    }
#endif

#if DEBUG
    @Test func testReboundKeyRoutesAndOldKeyDoesNot() async throws {
        defer { restoreState() }
        let appDelegate = AppDelegate()
        setCloudMachinesEnabled(true)
        let presenter = RecordingSheetPresenter()
        installDependencies(on: appDelegate, presenter: presenter)
        let manager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        appDelegate.mainWindowContexts.values.first { $0.windowId == windowID }?.window = window
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowID); withExtendedLifetime(window) {} }
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: true, option: false, control: false),
            for: .newCloudWorkspace
        )
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        func keyEvent(_ characters: String, _ modifiers: NSEvent.ModifierFlags, _ keyCode: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
        }

        #expect(!appDelegate.debugHandleCustomShortcut(event: try keyEvent("y", [.command, .shift], 16)))
        #expect(presenter.presentCount == 0, "the old ⇧⌘Y binding must not fire after a rebind")

        #expect(appDelegate.debugHandleCustomShortcut(event: try keyEvent("K", [.command, .shift], 40)))
        await appDelegate.cloudWorkspaceOperationController?.waitForPendingOperations()
        #expect(presenter.presentCount == 0)
    }
#endif

    @Test func testCommandPaletteNewMachineAdvertisesShortcut() {
        defer { restoreState() }
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: ContentView.commandPaletteCloudNewMachineCommandId) == .newCloudMachine)
    }

    @Test func testNewWorkspaceCapturesSelectedMachineAndDoesNotFallBackToLocalOnRepeat() async throws {
        defer { restoreState() }
        let app = AppDelegate()
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "selected-machine", isBase: false)
        let originalIDs = manager.tabs.map(\.id)
        var targets: [String] = []
        app.cloudWorkspaceCoordinator = CloudWorkspaceCoordinator(
            machinePinStore: pinStore(),
            allowsOperation: { true },
            loadMachines: { Issue.record("Cmd-N must not resolve a fleet target"); return [] },
            createWorkspace: { request in
                targets.append(request.machineID)
                return UUID()
            }
        )
        app.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { true })
        let windowID = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowID) }
        #expect(app.performNewWorkspaceAction(tabManager: manager))
        #expect(!app.performNewWorkspaceAction(tabManager: manager))
        await app.cloudWorkspaceOperationController?.waitForPendingOperations()
        #expect(targets == ["selected-machine"])
        #expect(manager.tabs.map(\.id) == originalIDs)
    }

    @Test func testUnavailableCloudDoesNotCreateLocalWorkspace() throws {
        defer { restoreState() }
        let app = AppDelegate()
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "selected-machine", isBase: false)
        let originalIDs = manager.tabs.map(\.id)
        #expect(!app.performNewWorkspaceAction(tabManager: manager))
        #expect(manager.tabs.map(\.id) == originalIDs)
    }
}
