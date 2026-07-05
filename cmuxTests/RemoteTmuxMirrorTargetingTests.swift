import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for remote-tmux mirror targeting and lifecycle decisions. These
/// exercise pure seams and cached unstarted control connections; no ssh/tmux
/// process is launched.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorTargetingTests {
    private func session(_ name: String, id: String? = nil) -> RemoteTmuxSession {
        RemoteTmuxSession(
            id: id ?? "$\(name)",
            name: name,
            windowCount: 1,
            attached: false,
            createdUnix: nil
        )
    }

    private func cacheConnection(
        controller: RemoteTmuxController,
        host: RemoteTmuxHost,
        sessionName: String
    ) {
        controller.cacheConnection(RemoteTmuxControlConnection(host: host, sessionName: sessionName))
    }

    @Test func unmirroredSessionsFiltersAlreadyMirroredNamesForHost() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        cacheConnection(controller: controller, host: host, sessionName: "old")
        try controller.mirrorSession(host: host, sessionName: "old", into: manager)

        let sessions = [session("old"), session("new")]
        #expect(controller.unmirroredSessions(sessions, host: host).map(\.name) == ["new"])
    }

    @Test func mirrorSessionsMirrorsOnlyNewSessionsAndIsIdempotent() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        cacheConnection(controller: controller, host: host, sessionName: "old")
        cacheConnection(controller: controller, host: host, sessionName: "new")
        try controller.mirrorSession(host: host, sessionName: "old", into: manager)

        controller.mirrorSessions([session("old"), session("new")], host: host, into: manager)
        controller.mirrorSessions([session("old"), session("new")], host: host, into: manager)

        let mirrorTitles = manager.tabs
            .filter(\.isRemoteTmuxMirror)
            .map(\.title)
            .sorted()
        #expect(mirrorTitles == ["new", "old"])
    }

    @Test func mirrorTargetTabManagerPrefersDedicatedWindowWhenResolvable() {
        let dedicatedId = UUID()
        let dedicated = TabManager()
        let fallback = TabManager()

        let resolved = RemoteTmuxController.mirrorTargetTabManager(
            dedicatedWindowId: dedicatedId,
            tabManagerForWindow: { $0 == dedicatedId ? dedicated : nil },
            fallbackTabManager: { fallback }
        )

        #expect(resolved === dedicated)
    }

    @Test func mirrorTargetTabManagerFallsBackWhenDedicatedMissingOrUnresolved() {
        let dedicatedId = UUID()
        let fallback = TabManager()

        let missing = RemoteTmuxController.mirrorTargetTabManager(
            dedicatedWindowId: nil,
            tabManagerForWindow: { _ in nil },
            fallbackTabManager: { fallback }
        )
        let unresolved = RemoteTmuxController.mirrorTargetTabManager(
            dedicatedWindowId: dedicatedId,
            tabManagerForWindow: { _ in nil },
            fallbackTabManager: { fallback }
        )

        #expect(missing === fallback)
        #expect(unresolved === fallback)
    }

    @Test func workspaceCloseKillTargetSkipsEndedConnections() {
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: true,
            sessionId: 5,
            sessionName: "dev"
        ) == nil)
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: false,
            sessionId: 5,
            sessionName: "dev"
        ) == "$5")
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: false,
            sessionId: nil,
            sessionName: "dev"
        ) == "dev")
    }

    @Test func shouldRefreshTitleChromeDistinguishesDirectAndSurfaceSourcedNotifications() throws {
        let suiteName = "RemoteTmuxMirrorTargeting.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let manager = TabManager(settings: settings)
        let selected = try #require(manager.selectedWorkspace)
        manager.selectedTabId = selected.id
        let otherId = UUID()
        let directSelected = Notification(
            name: .workspaceTitleDidChange,
            object: manager,
            userInfo: [GhosttyNotificationKey.tabId: selected.id]
        )
        let directOther = Notification(
            name: .workspaceTitleDidChange,
            object: manager,
            userInfo: [GhosttyNotificationKey.tabId: otherId]
        )
        let surfaceSelected = Notification(
            name: .workspaceTitleDidChange,
            object: manager,
            userInfo: [
                GhosttyNotificationKey.tabId: selected.id,
                GhosttyNotificationKey.surfaceId: UUID(),
            ]
        )

        settings.set(false, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(!manager.shouldRefreshTitleChrome(for: directOther))
        #expect(manager.shouldRefreshTitleChrome(for: directSelected))
        #expect(!manager.shouldRefreshTitleChrome(for: surfaceSelected))

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(manager.shouldRefreshTitleChrome(for: directSelected))
        #expect(manager.shouldRefreshTitleChrome(for: surfaceSelected))
    }
}
