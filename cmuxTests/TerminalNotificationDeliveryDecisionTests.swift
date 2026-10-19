import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal notification delivery decision")
struct TerminalNotificationDeliveryDecisionTests {
    /// The workspace the user is typing in must not jump in the sidebar when
    /// a notification arrives for the pane they are already looking at.
    @Test func focusedPaneKeepsWorkspaceInPlace() {
        let decision = TerminalNotificationDeliveryDecision.resolve(
            isAppFocused: true,
            isActiveTab: true,
            isFocusedSurface: true,
            isMuted: false,
            soundWhenFocused: false,
            effects: TerminalNotificationPolicyEffects()
        )
        #expect(decision.disposition == .focusedInline)
        #expect(!decision.effects.reorderWorkspace)
        #expect(!decision.effects.desktop)
        #expect(!decision.effects.sound)
        #expect(!decision.effects.paneFlash)
        #expect(decision.effects.record)
        #expect(decision.effects.markUnread)
        #expect(decision.effects.command)
    }

    /// `notifications.soundWhenFocused` restores the sound for the focused
    /// pane only; banners and pane flash stay off.
    @Test func focusedPaneSoundFollowsOptIn() {
        let decision = TerminalNotificationDeliveryDecision.resolve(
            isAppFocused: true,
            isActiveTab: true,
            isFocusedSurface: true,
            isMuted: false,
            soundWhenFocused: true,
            effects: TerminalNotificationPolicyEffects()
        )
        #expect(decision.disposition == .focusedInline)
        #expect(decision.effects.sound)
        #expect(!decision.effects.desktop)
        #expect(!decision.effects.paneFlash)

        var silent = TerminalNotificationPolicyEffects()
        silent.sound = false
        #expect(!silent.keepingFocusedPaneQuiet(soundWhenFocused: true).sound)
    }

    @Test(arguments: [
        (false, true, true),
        (true, false, true),
        (true, true, false),
    ])
    func unfocusedPaneStillReorders(appFocused: Bool, activeTab: Bool, focusedSurface: Bool) {
        let decision = TerminalNotificationDeliveryDecision.resolve(
            isAppFocused: appFocused,
            isActiveTab: activeTab,
            isFocusedSurface: focusedSurface,
            isMuted: false,
            soundWhenFocused: false,
            effects: TerminalNotificationPolicyEffects()
        )
        #expect(decision.disposition == .externalDelivery)
        #expect(decision.effects.reorderWorkspace)
    }

    /// The terminal notification store applies the same rule once it knows the
    /// target pane is focused; other effects pass through unchanged.
    @Test func storeOrderingEffectsDropReorderOnlyForFocusedPane() {
        let effects = TerminalNotificationPolicyEffects()
        #expect(effects.keepingFocusedWorkspaceInPlace(isFocusedPane: false) == effects)
        var expected = effects
        expected.reorderWorkspace = false
        #expect(effects.keepingFocusedWorkspaceInPlace(isFocusedPane: true) == expected)
    }
}
