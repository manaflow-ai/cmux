import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct FileExplorerStateModePersistenceTests {
    private let modeKey = "rightSidebar.mode"
    private let customSidebarNameKey = "rightSidebar.customSidebarName"
    private let feedEnabledKey = RightSidebarBetaFeatureSettings.feedEnabledKey
    private let dockEnabledKey = RightSidebarBetaFeatureSettings.dockEnabledKey
    private let sourceControlEnabledKey = RightSidebarBetaFeatureSettings.sourceControlEnabledKey

    @Test
    func disabledFeedStoredModeFallsBackToFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.feed.rawValue, forKey: modeKey)
            defaults.set(false, forKey: feedEnabledKey)

            let state = FileExplorerState()

            #expect(state.mode == .files)
            #expect(defaults.string(forKey: modeKey) == RightSidebarMode.files.rawValue)
        }
    }

    @Test
    func enabledFeedStoredModeSurvives() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.feed.rawValue, forKey: modeKey)
            defaults.set(true, forKey: feedEnabledKey)

            let state = FileExplorerState()

            #expect(state.mode == .feed)
            #expect(defaults.string(forKey: modeKey) == RightSidebarMode.feed.rawValue)
        }
    }

    @Test
    func modeSetterClampsUnavailableBetaModes() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: feedEnabledKey)
            defaults.set(false, forKey: dockEnabledKey)
            let state = FileExplorerState()

            state.mode = .feed
            #expect(state.mode == .files)
            #expect(defaults.string(forKey: modeKey) == RightSidebarMode.files.rawValue)

            defaults.set(true, forKey: dockEnabledKey)
            state.mode = .dock
            #expect(state.mode == .dock)
            #expect(defaults.string(forKey: modeKey) == RightSidebarMode.dock.rawValue)

            defaults.set(false, forKey: dockEnabledKey)
            state.refreshModeAvailability()
            #expect(state.mode == .files)
            #expect(defaults.string(forKey: modeKey) == RightSidebarMode.files.rawValue)
        }
    }

    @Test
    func storedCustomSidebarModeFallsBackToFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set("custom-sidebar", forKey: modeKey)
            defaults.set("status-board", forKey: customSidebarNameKey)

            let state = FileExplorerState()

            #expect(state.mode == .files)
            #expect(defaults.string(forKey: modeKey) == RightSidebarMode.files.rawValue)
        }
    }

    @Test
    func disabledSourceControlStoredModeFallsBackToFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.sourceControl.rawValue, forKey: modeKey)
            defaults.set(false, forKey: sourceControlEnabledKey)

            let state = FileExplorerState()

            #expect(state.mode == .files)
            #expect(defaults.string(forKey: modeKey) == RightSidebarMode.files.rawValue)
        }
    }

    @Test
    func missingSourceControlFlagFallsBackToFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: sourceControlEnabledKey)
            defaults.set(RightSidebarMode.sourceControl.rawValue, forKey: modeKey)

            let state = FileExplorerState()

            #expect(state.mode == .files)
            #expect(defaults.string(forKey: modeKey) == RightSidebarMode.files.rawValue)
        }
    }

    @Test
    func enabledSourceControlStoredModeSurvives() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.sourceControl.rawValue, forKey: modeKey)
            defaults.set(true, forKey: sourceControlEnabledKey)

            let state = FileExplorerState()

            #expect(state.mode == .sourceControl)
            #expect(defaults.string(forKey: modeKey) == RightSidebarMode.sourceControl.rawValue)
        }
    }

    @Test
    func cliArgumentNormalizerMapsVaultAndSessionsToSessions() {
        #expect(RightSidebarMode.from(cliArgument: "files") == .files)
        #expect(RightSidebarMode.from(cliArgument: "find") == .find)
        #expect(RightSidebarMode.from(cliArgument: "vault") == .sessions)
        #expect(RightSidebarMode.from(cliArgument: "sessions") == .sessions)
        #expect(RightSidebarMode.from(cliArgument: "feed") == .feed)
        #expect(RightSidebarMode.from(cliArgument: "dock") == .dock)
        #expect(RightSidebarMode.from(cliArgument: " Vault ") == .sessions)
        #expect(RightSidebarMode.from(cliArgument: "custom-sidebar") == nil)
        #expect(RightSidebarMode.from(cliArgument: "custom") == nil)
        #expect(RightSidebarMode.from(cliArgument: "unknown") == nil)
    }

    private func withSavedRightSidebarModeDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: modeKey)
        let previousCustomSidebarName = defaults.object(forKey: customSidebarNameKey)
        let previousFeedEnabled = defaults.object(forKey: feedEnabledKey)
        let previousDockEnabled = defaults.object(forKey: dockEnabledKey)
        let previousSourceControlEnabled = defaults.object(forKey: sourceControlEnabledKey)
        defer {
            restore(previousMode, forKey: modeKey)
            restore(previousCustomSidebarName, forKey: customSidebarNameKey)
            restore(previousFeedEnabled, forKey: feedEnabledKey)
            restore(previousDockEnabled, forKey: dockEnabledKey)
            restore(previousSourceControlEnabled, forKey: sourceControlEnabledKey)
        }
        body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
