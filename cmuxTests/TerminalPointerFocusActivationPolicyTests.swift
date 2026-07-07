import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminalPointerFocusActivationPolicyTests {
    @Test
    func unfocusedPaneFocusClickDoesNotForwardToTerminal() {
        let policy = TerminalPointerFocusActivationPolicy()

        #expect(!policy.shouldForwardToTerminal(wasFocusedBeforePointerDown: false))
    }

    @Test
    func focusedPaneClickStillForwardsToTerminal() {
        let policy = TerminalPointerFocusActivationPolicy()

        #expect(policy.shouldForwardToTerminal(wasFocusedBeforePointerDown: true))
    }
}
