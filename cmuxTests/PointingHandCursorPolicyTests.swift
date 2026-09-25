import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct PointingHandCursorPolicyTests {
    @Test func enabledButtonRoleUsesPointingHandCursor() {
        #expect(PointingHandCursorPolicy.shouldUsePointingHand(forRole: .button, isEnabled: true))
    }

    @Test func disabledButtonRoleKeepsTheArrowCursor() {
        #expect(!PointingHandCursorPolicy.shouldUsePointingHand(forRole: .button, isEnabled: false))
    }

    @Test func textRoleKeepsTheArrowCursor() {
        #expect(!PointingHandCursorPolicy.shouldUsePointingHand(forRole: .textField, isEnabled: true))
    }
}
