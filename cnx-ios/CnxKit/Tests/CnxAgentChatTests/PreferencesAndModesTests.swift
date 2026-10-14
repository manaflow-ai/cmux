@testable import CnxAgentChat
import CnxDesign
import CnxModel
import Foundation
import Testing

@Suite struct PlanModeSwitchTests {
    @Test func claudeModesGetASwitchBackToDefault() throws {
        let modes = [ACPMode(id: "default", name: "Default"), ACPMode(id: "acceptEdits", name: "Accept Edits"),
                     ACPMode(id: "plan", name: "Plan Mode"), ACPMode(id: "bypassPermissions", name: "Bypass")]
        let plan = try #require(PlanModeSwitch(modes: modes))
        #expect(plan.mode(on: true) == "plan")
        #expect(plan.mode(on: false) == "default")
        #expect(plan.isOn(currentModeID: "plan"))
        #expect(!plan.isOn(currentModeID: "acceptEdits"))
    }

    @Test func noPlanModeOrNoModesHidesTheSwitch() {
        #expect(PlanModeSwitch(modes: []) == nil)
        #expect(PlanModeSwitch(modes: [ACPMode(id: "read-only", name: "Read Only"), ACPMode(id: "auto", name: "Auto")]) == nil)
        #expect(PlanModeSwitch(modes: [ACPMode(id: "plan", name: "Plan")]) == nil)
    }

    @Test func leavesPlanForTheFirstOtherModeWithoutADefault() throws {
        let plan = try #require(PlanModeSwitch(modes: [ACPMode(id: "plan", name: "Plan"), ACPMode(id: "auto", name: "Auto")]))
        #expect(plan.mode(on: false) == "auto")
    }
}

@MainActor
@Suite struct ComposerPreferenceTests {
    /// Settings writes through `SettingsStore`; the terminal, code cards and
    /// the composer read `CnxPreferences`: the keys and defaults must agree.
    @Test func settingsStoreAndPreferencesShareKeys() throws {
        let suite = "cnx.prefs.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(CnxPreferences.terminalFontSize(defaults) == settings.terminalFontSize)
        #expect(CnxPreferences.wrapCode(defaults) == settings.wrapCode)
        #expect(CnxPreferences.keyClicks(defaults) == settings.keyClicks)
        #expect(CnxPreferences.dismissKeyboardAfterSend(defaults) == settings.dismissKeyboardAfterSend)
        #expect(!CnxPreferences.steersFollowUps(defaults))

        settings.terminalFontSize = 17
        settings.wrapCode = true
        settings.keyClicks = false
        settings.dismissKeyboardAfterSend = false
        settings.followUp = .steer
        #expect(CnxPreferences.terminalFontSize(defaults) == 17)
        #expect(CnxPreferences.wrapCode(defaults))
        #expect(!CnxPreferences.keyClicks(defaults))
        #expect(!CnxPreferences.dismissKeyboardAfterSend(defaults))
        #expect(CnxPreferences.steersFollowUps(defaults))

        settings.terminalFontSize = 99
        #expect(CnxPreferences.terminalFontSize(defaults) == CnxPreferences.terminalFontSizes.upperBound)
    }

    @Test func liveSessionsHideCheckpoints() {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "/tmp",
                                          workspaceTitle: "w", macName: "Mac")
        #expect(!DisconnectedAgentSource(summary: summary).supportsCheckpoints)
        #if DEBUG
        #expect(MockAgentSession(summary: summary, sleep: { _ in }).supportsCheckpoints)
        #endif
    }
}
