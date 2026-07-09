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
        try controller.mirrorSessionForTesting(host: host, sessionName: "old", into: manager)

        let sessions = [session("old"), session("new")]
        #expect(controller.unmirroredSessions(sessions, host: host).map(\.name) == ["new"])
    }

    @Test func tmuxSessionNumericIdParsesOnlyDollarPrefixedDecimalIds() {
        #expect(RemoteTmuxController.tmuxSessionNumericId("$0") == 0)
        #expect(RemoteTmuxController.tmuxSessionNumericId("$42") == 42)
        #expect(RemoteTmuxController.tmuxSessionNumericId("0") == nil)
        #expect(RemoteTmuxController.tmuxSessionNumericId("") == nil)
        #expect(RemoteTmuxController.tmuxSessionNumericId("$x") == nil)
        #expect(RemoteTmuxController.tmuxSessionNumericId("$-1") == nil)
    }

    @Test func unmirroredSessionsUsesStableSessionIdsBeforeNames() {
        // Rename race: the mirrored session's %session-renamed has not re-keyed
        // yet, so its stable id must prevent a duplicate mirror under the new name.
        let renameRace = RemoteTmuxController.unmirroredSessions(
            [session("zeromain", id: "$0")],
            mirroredSessionIds: [0],
            mirroredNames: ["0"]
        )
        #expect(renameRace.isEmpty)

        // A NEW session reusing a mirrored session's stale pre-rename name stays
        // undiscovered until the rename event re-keys the mirror (deliberate: the
        // name-keyed attach pipeline would drop it anyway; see the helper's doc).
        let reusedOldName = RemoteTmuxController.unmirroredSessions(
            [session("0", id: "$5")],
            mirroredSessionIds: [0],
            mirroredNames: ["0"]
        )
        #expect(reusedOldName.isEmpty)

        // Mid-attach mirrors have no sessionId yet; the name fallback covers them.
        let midAttach = RemoteTmuxController.unmirroredSessions(
            [session("dev", id: "$5")],
            mirroredSessionIds: [],
            mirroredNames: ["dev"]
        )
        #expect(midAttach.isEmpty)

        let fresh = RemoteTmuxController.unmirroredSessions(
            [session("fresh", id: "$7")],
            mirroredSessionIds: [0],
            mirroredNames: ["old"]
        )
        #expect(fresh.map(\.name) == ["fresh"])
    }

    @Test func unmirroredSessionsSeesSeededSessionIdBeforeStreamReportsIt() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        cacheConnection(controller: controller, host: host, sessionName: "old")
        try controller.mirrorSessionForTesting(host: host, sessionName: "old", sessionId: 3, into: manager)

        // Renamed remotely before %session-changed re-keys: same $3, new name —
        // the discovery-seeded id must prevent a duplicate mirror.
        #expect(controller.unmirroredSessions([session("renamed", id: "$3")], host: host).isEmpty)
        // A genuinely new session is still discovered.
        #expect(controller.unmirroredSessions([session("fresh", id: "$4")], host: host).map(\.name) == ["fresh"])
    }

    @Test func mirrorSessionsMirrorsOnlyNewSessionsAndIsIdempotent() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        cacheConnection(controller: controller, host: host, sessionName: "old")
        cacheConnection(controller: controller, host: host, sessionName: "new")
        try controller.mirrorSessionForTesting(host: host, sessionName: "old", into: manager)

        controller.mirrorSessionsForTesting([session("old"), session("new")], host: host, into: manager)
        controller.mirrorSessionsForTesting([session("old"), session("new")], host: host, into: manager)

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
