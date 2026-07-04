import CmuxFoundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarWorkspaceStateColorTests {
    @Test func disabledStateColorsPreserveManualColor() {
        let resolver = WorkspaceStateColorResolver(
            isEnabled: false,
            mode: .replace,
            colorHexByState: ["running": "#FF0000"]
        )

        #expect(
            resolver.resolvedColorHex(
                manualColorHex: "#0011aa",
                agentLifecycleState: .running
            ) == "#0011AA"
        )
    }

    @Test func replaceModeUsesStateColorAndAllowsNoTintStates() {
        let resolver = WorkspaceStateColorResolver(
            isEnabled: true,
            mode: .replace,
            colorHexByState: ["running": "#ff6600"]
        )

        #expect(
            resolver.resolvedColorHex(
                manualColorHex: "#0011AA",
                agentLifecycleState: .running
            ) == "#FF6600"
        )
        #expect(
            resolver.resolvedColorHex(
                manualColorHex: "#0011AA",
                agentLifecycleState: .idle
            ) == nil
        )
    }

    @Test func blendModeMixesManualAndStateColors() {
        let resolver = WorkspaceStateColorResolver(
            isEnabled: true,
            mode: .blend,
            colorHexByState: ["needsInput": "#FF0000"]
        )

        #expect(
            resolver.resolvedColorHex(
                manualColorHex: "#0000FF",
                agentLifecycleState: .needsInput
            ) == "#7F007F"
        )
    }

    @Test func blendModeFallsBackToManualColorWhenStateHasNoTint() {
        let resolver = WorkspaceStateColorResolver(
            isEnabled: true,
            mode: .blend,
            colorHexByState: [:]
        )

        #expect(
            resolver.resolvedColorHex(
                manualColorHex: "#00aa11",
                agentLifecycleState: .idle
            ) == "#00AA11"
        )
    }
}
