import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Context and switcher fingerprints
extension CommandPaletteSearchEngineTests {
    func testCommandContextFingerprintTracksExactContextValues() {
        let base = ContentView.commandPaletteContextFingerprint(
            boolValues: [
                "workspace.hasPullRequests": true,
                "panel.hasUnread": false,
                "panel.isTerminal": true,
            ],
            stringValues: [
                "workspace.name": "Alpha",
                "panel.name": "Main",
            ]
        )
        let unreadChanged = ContentView.commandPaletteContextFingerprint(
            boolValues: [
                "workspace.hasPullRequests": true,
                "panel.hasUnread": true,
                "panel.isTerminal": true,
            ],
            stringValues: [
                "workspace.name": "Alpha",
                "panel.name": "Main",
            ]
        )
        let renamed = ContentView.commandPaletteContextFingerprint(
            boolValues: [
                "workspace.hasPullRequests": true,
                "panel.hasUnread": false,
                "panel.isTerminal": true,
            ],
            stringValues: [
                "workspace.name": "Alpha",
                "panel.name": "Logs",
            ]
        )

        XCTAssertNotEqual(base, unreadChanged)
        XCTAssertNotEqual(base, renamed)
    }

    func testSwitcherFingerprintTracksMetadataValuesAtSameCardinality() {
        let windowID = UUID()
        let workspaceID = UUID()
        let base = ContentView.commandPaletteSwitcherFingerprint(
            windowContexts: [
                ContentView.CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: "Window 2",
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        ContentView.CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(
                                directories: ["/Users/example/dev/cmuxterm"],
                                branches: ["feature/search-speed"],
                                ports: [3000]
                            ),
                            surfaces: []
                        )
                    ]
                )
            ]
        )
        let changedMetadata = ContentView.commandPaletteSwitcherFingerprint(
            windowContexts: [
                ContentView.CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: "Window 2",
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        ContentView.CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(
                                directories: ["/Users/example/dev/other"],
                                branches: ["feature/search-speed"],
                                ports: [4000]
                            ),
                            surfaces: []
                        )
                    ]
                )
            ]
        )
        let changedDisplayName = ContentView.commandPaletteSwitcherFingerprint(
            windowContexts: [
                ContentView.CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: "Window 2",
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        ContentView.CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Beta",
                            metadata: CommandPaletteSwitcherSearchMetadata(
                                directories: ["/Users/example/dev/cmuxterm"],
                                branches: ["feature/search-speed"],
                                ports: [3000]
                            ),
                            surfaces: []
                        )
                    ]
                )
            ]
        )

        XCTAssertNotEqual(base, changedMetadata)
        XCTAssertNotEqual(base, changedDisplayName)
    }

    func testSwitcherFingerprintTracksSurfaceValuesAtSameCardinality() {
        let windowID = UUID()
        let workspaceID = UUID()
        let surfaceID = UUID()

        let base = ContentView.commandPaletteSwitcherFingerprint(
            windowContexts: [
                ContentView.CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: nil,
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        ContentView.CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(),
                            surfaces: [
                                ContentView.CommandPaletteSwitcherFingerprintSurface(
                                    id: surfaceID,
                                    displayName: "Terminal",
                                    kindLabel: "Terminal",
                                    metadata: CommandPaletteSwitcherSearchMetadata(
                                        directories: ["/tmp/search-alpha"],
                                        branches: ["feature/a"],
                                        ports: [3000]
                                    )
                                )
                            ]
                        )
                    ]
                )
            ]
        )
        let changedSurfaceMetadata = ContentView.commandPaletteSwitcherFingerprint(
            windowContexts: [
                ContentView.CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: nil,
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        ContentView.CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(),
                            surfaces: [
                                ContentView.CommandPaletteSwitcherFingerprintSurface(
                                    id: surfaceID,
                                    displayName: "Terminal",
                                    kindLabel: "Terminal",
                                    metadata: CommandPaletteSwitcherSearchMetadata(
                                        directories: ["/tmp/search-beta"],
                                        branches: ["feature/a"],
                                        ports: [3000]
                                    )
                                )
                            ]
                        )
                    ]
                )
            ]
        )
        let changedSurfaceKind = ContentView.commandPaletteSwitcherFingerprint(
            windowContexts: [
                ContentView.CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: nil,
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        ContentView.CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(),
                            surfaces: [
                                ContentView.CommandPaletteSwitcherFingerprintSurface(
                                    id: surfaceID,
                                    displayName: "Terminal",
                                    kindLabel: "Browser",
                                    metadata: CommandPaletteSwitcherSearchMetadata(
                                        directories: ["/tmp/search-alpha"],
                                        branches: ["feature/a"],
                                        ports: [3000]
                                    )
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        XCTAssertNotEqual(base, changedSurfaceMetadata)
        XCTAssertNotEqual(base, changedSurfaceKind)
    }

}
