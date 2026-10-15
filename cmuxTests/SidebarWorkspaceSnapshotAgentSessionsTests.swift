import Foundation
import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SidebarWorkspaceSnapshotRefreshPolicyTests {
    private static func sessionSnapshot(state: SidebarAgentSessionSnapshot.State) -> SidebarAgentSessionSnapshot {
        SidebarAgentSessionSnapshot(
            panelId: UUID(),
            sessionID: "s-1",
            agentName: "Claude",
            title: "Fix the login bug",
            lastPrompt: "fix it",
            lastPromptAt: Date(timeIntervalSince1970: 60),
            state: state,
            lastActivityMinute: Date(timeIntervalSince1970: 60)
        )
    }

    @Test func presentationKeyChangesWhenAgentSessionsVisibilityChanges() {
        let hidden = Self.presentationKey(showsAgentSessions: false)
        let visible = Self.presentationKey(showsAgentSessions: true)

        #expect(hidden != visible)
        #expect(!hidden.showsAgentSessions)
        #expect(visible.showsAgentSessions)
    }

    @Test func agentSessionsSettingDefaultsOnAndHonorsHideAllDetails() throws {
        let suiteName = "cmux.sidebar.agent-sessions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SidebarTabItemSettingsSnapshot(defaults: defaults).showsAgentSessions)

        defaults.set(false, forKey: "sidebarShowAgentSessions")
        #expect(!SidebarTabItemSettingsSnapshot(defaults: defaults).showsAgentSessions)

        defaults.set(true, forKey: "sidebarShowAgentSessions")
        defaults.set(true, forKey: "sidebarHideAllDetails")
        #expect(!SidebarTabItemSettingsSnapshot(defaults: defaults).showsAgentSessions)
    }

    @Test func contextMenuAgentSessionChangeShowsImmediately() {
        let current = Self.snapshot(
            latestConversationMessage: "old message",
            agentSessions: [Self.sessionSnapshot(state: .running)]
        )
        let next = Self.snapshot(
            latestConversationMessage: "new message",
            agentSessions: [Self.sessionSnapshot(state: .needsInput)]
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage?.agentSessions.map(\.state) == [.needsInput])
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
    }
}
