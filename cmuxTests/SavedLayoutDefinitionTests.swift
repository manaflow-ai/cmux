import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct SavedLayoutDefinitionTests {
    @Test func savedLayoutCodableRoundTripsNestedSplitTree() throws {
        let layout = CmuxSavedLayout(
            name: "Nested",
            description: "Round trip",
            workspace: CmuxWorkspaceDefinition(
                name: "Workspace",
                cwd: "/tmp/project",
                color: "#123456",
                env: ["A": "B"],
                layout: Self.nestedLayout
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(layout)
        let decoded = try JSONDecoder().decode(CmuxSavedLayout.self, from: data)

        #expect(decoded.name == "Nested")
        #expect(decoded.description == "Round trip")
        #expect(decoded.workspace.cwd == "/tmp/project")
        let root = try #require(decoded.workspace.layout)
        guard case .split(let split) = root else {
            Issue.record("Expected split root")
            return
        }
        #expect(split.direction == .horizontal)
        #expect(split.split == 0.33)
        guard case .pane(let firstPane) = split.children[0] else {
            Issue.record("Expected first pane")
            return
        }
        #expect(firstPane.surfaces[0].type == .terminal)
        #expect(firstPane.surfaces[0].cwd == "server")
        #expect(firstPane.surfaces[0].name == "Server")
        #expect(firstPane.surfaces[0].focus == true)
    }

    @Test func splitDefinitionClampsDividerPosition() {
        #expect(CmuxSplitDefinition(direction: .horizontal, split: -1, children: Self.twoPanes).clampedSplitPosition == 0.1)
        #expect(CmuxSplitDefinition(direction: .horizontal, split: 2, children: Self.twoPanes).clampedSplitPosition == 0.9)
        #expect(CmuxSplitDefinition(direction: .horizontal, split: 0.42, children: Self.twoPanes).clampedSplitPosition == 0.42)
        #expect(CmuxSplitDefinition(direction: .horizontal, children: Self.twoPanes).clampedSplitPosition == 0.5)
    }

    @Test func storeJSONLayoutDecodesThroughWorkspaceCreateLayoutDecoder() throws {
        let context = try TemporarySavedLayoutContext()
        defer { context.cleanup() }
        let store = SavedLayoutStore(fileURL: context.fileURL)
        try store.save(
            CmuxSavedLayout(
                name: "Nested",
                description: nil,
                workspace: CmuxWorkspaceDefinition(cwd: "/tmp/project", layout: Self.nestedLayout)
            ),
            overwrite: false
        )

        let data = try Data(contentsOf: context.fileURL)
        let decoded = try JSONDecoder().decode(SavedLayoutStore.LayoutsFile.self, from: data)
        let layoutNode = try #require(decoded.layouts.first?.workspace.layout)
        let layoutData = try JSONEncoder().encode(layoutNode)
        _ = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)
    }

    private static var nestedLayout: CmuxLayoutNode {
        .split(
            CmuxSplitDefinition(
                direction: .horizontal,
                split: 0.33,
                children: [
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .terminal, name: "Server", command: nil, cwd: "server", env: nil, url: nil, focus: true),
                    ])),
                    .split(CmuxSplitDefinition(
                        direction: .vertical,
                        split: 0.66,
                        children: [
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .browser, name: "Docs", command: nil, cwd: nil, env: nil, url: "https://example.com", focus: nil),
                            ])),
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .terminal, name: nil, command: nil, cwd: nil, env: nil, url: nil, focus: nil),
                            ])),
                        ]
                    )),
                ]
            )
        )
    }

    private static var twoPanes: [CmuxLayoutNode] {
        [
            .pane(CmuxPaneDefinition(surfaces: [CmuxSurfaceDefinition(type: .terminal)])),
            .pane(CmuxPaneDefinition(surfaces: [CmuxSurfaceDefinition(type: .terminal)])),
        ]
    }
}
