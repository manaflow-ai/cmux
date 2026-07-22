import CMUXMobileCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct MobileSurfaceKindMappingTests {
    @Test func mobileAndWorkspaceMappingsStayExhaustivelyInParity() {
        let controller = TerminalController.shared
        for panelType in PanelType.allCases {
            #expect(
                controller.mobileSurfaceKind(for: panelType).rawValue == Workspace.surfaceKind(for: panelType),
                "mapping differs for \(panelType.rawValue)"
            )
        }
    }
}
