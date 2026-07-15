import Foundation
import CmuxFoundation
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

    @Test func parameterizedTicketLayoutResolvesEveryLaunchStringLeaf() throws {
        let definition = CmuxWorkspaceDefinition(
            name: "{{ticket}} Dev",
            cwd: "~/code/app/wt/{{ticket}}",
            env: [
                "API_PORT": "{{apiPort}}",
                "TICKET": "{{ticket}}",
                "VITE_PORT": "{{vitePort}}",
            ],
            setup: "echo preparing {{ticket}}",
            params: ["vitePort": "5100"],
            layout: .split(CmuxSplitDefinition(
                direction: .horizontal,
                children: [
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(
                            type: .terminal,
                            name: "API {{ticket}}",
                            command: "uvicorn app:api --port {{apiPort}}",
                            cwd: "services/{{ticket}}",
                            env: ["SERVICE_PORT": "{{apiPort}}"],
                            url: nil,
                            focus: true
                        ),
                    ])),
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(
                            type: .browser,
                            name: "Vite {{ticket}}",
                            command: nil,
                            cwd: nil,
                            env: nil,
                            url: "http://localhost:{{vitePort}}/browse/{{ticket}}/",
                            focus: nil
                        ),
                    ])),
                ]
            ))
        )

        let resolved = try definition.resolvingTemplateParameters(
            ["ticket": "BERKS-87", "apiPort": "8087"],
            processEnvironment: [:]
        )

        #expect(resolved.name == "BERKS-87 Dev")
        #expect(resolved.cwd == "~/code/app/wt/BERKS-87")
        #expect(resolved.env == [
            "API_PORT": "8087",
            "TICKET": "BERKS-87",
            "VITE_PORT": "5100",
        ])
        #expect(resolved.setup == "echo preparing BERKS-87")
        #expect(resolved.params == nil)
        guard case .split(let split) = try #require(resolved.layout),
              case .pane(let terminalPane) = split.children[0],
              case .pane(let browserPane) = split.children[1] else {
            Issue.record("Expected resolved split layout")
            return
        }
        #expect(terminalPane.surfaces[0].name == "API BERKS-87")
        #expect(terminalPane.surfaces[0].command == "uvicorn app:api --port 8087")
        #expect(terminalPane.surfaces[0].cwd == "services/BERKS-87")
        #expect(terminalPane.surfaces[0].env == ["SERVICE_PORT": "8087"])
        #expect(browserPane.surfaces[0].name == "Vite BERKS-87")
        #expect(browserPane.surfaces[0].url == "http://localhost:5100/browse/BERKS-87/")
    }

    @Test func parameterizedWorkspaceReportsEveryMissingVariableBeforeLaunch() {
        let definition = CmuxWorkspaceDefinition(
            name: "{{ticket}}",
            env: ["API_PORT": "{{apiPort}}"],
            params: [:],
            layout: .pane(CmuxPaneDefinition(surfaces: [
                CmuxSurfaceDefinition(type: .browser, url: "http://localhost:{{vitePort}}"),
            ]))
        )

        #expect(throws: CmuxTemplateResolutionError.missingVariables(["ticket", "apiPort", "vitePort"])) {
            try definition.resolvingTemplateParameters([:], processEnvironment: [:])
        }
    }

    @Test func launchResolutionPreservesLiteralPlaceholdersUntilParameterizationIsEnabled() throws {
        let literal = CmuxWorkspaceDefinition(name: "Literal {{upstream}}")
        let enabled = CmuxWorkspaceDefinition(
            name: "Ticket {{ticket}}",
            params: ["ticket": "CMUX-8059"]
        )

        let preserved = try literal.resolvingTemplateParametersForLaunch(
            [:],
            processEnvironment: [:]
        )
        let resolved = try enabled.resolvingTemplateParametersForLaunch(
            [:],
            processEnvironment: [:]
        )

        #expect(preserved.name == "Literal {{upstream}}")
        #expect(resolved.name == "Ticket CMUX-8059")
        #expect(resolved.params == nil)
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
