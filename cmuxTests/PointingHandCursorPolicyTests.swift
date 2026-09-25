import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct PointingHandCursorPolicyTests {
    @Test func enabledControlsUsePointingHandCursor() {
        #expect(PointingHandCursorPolicy.pointerStyle(isEnabled: true, requested: .link) == .link)
    }

    @Test func disabledControlsKeepTheArrowCursor() {
        #expect(PointingHandCursorPolicy.pointerStyle(isEnabled: false, requested: .link) == .default)
    }

    @Test func enabledControlsPreserveAnUnspecifiedCursorStyle() {
        #expect(PointingHandCursorPolicy.pointerStyle(isEnabled: true, requested: nil) == nil)
    }
}
