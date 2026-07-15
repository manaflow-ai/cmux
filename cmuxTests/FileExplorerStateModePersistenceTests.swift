import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Right sidebar mode persistence", .serialized)
struct FileExplorerStateModePersistenceTests {
    private let modeKey = "rightSidebar.mode"
    private let customSidebarNameKey = "rightSidebar.customSidebarName"
    private let dockEnabledKey = RightSidebarBetaFeatureSettings.dockEnabledKey

    @Test("Remote-disabled Feed falls back to Files")
    func remoteDisabledFeedStoredModeFallsBackToFiles() throws {
        try withSavedRightSidebarModeDefaults {
            try withFeedFlag(false) {
                UserDefaults.standard.set(RightSidebarMode.feed.rawValue, forKey: modeKey)
                let state = FileExplorerState()
                #expect(state.mode == .files)
                #expect(UserDefaults.standard.string(forKey: modeKey) == RightSidebarMode.files.rawValue)
            }
        }
    }

    @Test("Default-on Feed stored mode survives")
    func defaultOnFeedStoredModeSurvives() throws {
        try withSavedRightSidebarModeDefaults {
            try withFeedFlag(true) {
                UserDefaults.standard.set(RightSidebarMode.feed.rawValue, forKey: modeKey)
                let state = FileExplorerState()
                #expect(state.mode == .feed)
                #expect(UserDefaults.standard.string(forKey: modeKey) == RightSidebarMode.feed.rawValue)
            }
        }
    }

    @Test("Mode setter clamps unavailable modes")
    func modeSetterClampsUnavailableModes() throws {
        try withSavedRightSidebarModeDefaults {
            try withFeedFlag(false) {
                let defaults = UserDefaults.standard
                defaults.set(false, forKey: dockEnabledKey)
                let state = FileExplorerState()

                state.mode = .feed
                #expect(state.mode == .files)

                defaults.set(true, forKey: dockEnabledKey)
                state.mode = .dock
                #expect(state.mode == .dock)

                defaults.set(false, forKey: dockEnabledKey)
                state.refreshModeAvailability()
                #expect(state.mode == .files)
            }
        }
    }

    @Test("Stored custom sidebar mode falls back to Files")
    func storedCustomSidebarModeFallsBackToFiles() throws {
        try withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.customSidebar.rawValue, forKey: modeKey)
            defaults.set("status-board", forKey: customSidebarNameKey)
            let state = FileExplorerState()
            #expect(state.mode == .files)
            #expect(defaults.string(forKey: modeKey) == RightSidebarMode.files.rawValue)
        }
    }

    @Test("CLI aliases normalize to sidebar modes")
    func cliAliasesNormalizeToSidebarModes() {
        #expect(RightSidebarMode.from(cliArgument: "files") == .files)
        #expect(RightSidebarMode.from(cliArgument: "find") == .find)
        #expect(RightSidebarMode.from(cliArgument: "vault") == .sessions)
        #expect(RightSidebarMode.from(cliArgument: "sessions") == .sessions)
        #expect(RightSidebarMode.from(cliArgument: "feed") == .feed)
        #expect(RightSidebarMode.from(cliArgument: "dock") == .dock)
        #expect(RightSidebarMode.from(cliArgument: " Vault ") == .sessions)
        #expect(RightSidebarMode.from(cliArgument: "custom-sidebar") == nil)
        #expect(RightSidebarMode.from(cliArgument: "unknown") == nil)
    }

    private func withFeedFlag<T>(_ enabled: Bool, _ body: () throws -> T) throws -> T {
        let flags = CmuxFeatureFlags.shared
        let definition = try #require(CmuxFeatureFlags.allFlags.first { $0.key == "feed-ui-enabled-release" })
        let previous = flags.overrideValue(for: definition)
        flags.setOverride(enabled, for: definition)
        defer { flags.setOverride(previous, for: definition) }
        return try body()
    }

    private func withSavedRightSidebarModeDefaults<T>(_ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: modeKey)
        let previousCustomSidebarName = defaults.object(forKey: customSidebarNameKey)
        let previousDockEnabled = defaults.object(forKey: dockEnabledKey)
        defer {
            restore(previousMode, forKey: modeKey)
            restore(previousCustomSidebarName, forKey: customSidebarNameKey)
            restore(previousDockEnabled, forKey: dockEnabledKey)
        }
        return try body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
