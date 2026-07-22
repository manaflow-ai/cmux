import CMUXMobileCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct MobileSurfaceKindMappingTests {
    /// The canonical PanelType -> wire-kind vocabulary. Both mapping
    /// functions must produce these exact strings; asserting only parity
    /// would pass when both drift to the same wrong value.
    private static let canonicalKinds: [PanelType: String] = [
        .terminal: "terminal",
        .browser: "browser",
        .markdown: "markdown",
        .filePreview: "filePreview",
        .rightSidebarTool: "rightSidebarTool",
        .customSidebar: "customSidebar",
        .agentSession: "agentSession",
        .project: "project",
        .extensionBrowser: "extensionBrowser",
        .workspaceTodo: "todo",
        .cloudVMLoading: "cloudVMLoading",
    ]

    @Test func everyPanelTypeMapsToItsCanonicalWireKind() throws {
        #expect(Self.canonicalKinds.count == PanelType.allCases.count)
        let controller = TerminalController.shared
        for panelType in PanelType.allCases {
            let canonical = try #require(
                Self.canonicalKinds[panelType],
                "no canonical kind declared for \(panelType.rawValue)"
            )
            #expect(controller.mobileSurfaceKind(for: panelType).rawValue == canonical)
            #expect(Workspace.surfaceKind(for: panelType) == canonical)
        }
    }
}
