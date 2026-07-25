import AppKit
import Bonsplit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Move selected surface between panes", .serialized)
struct MoveSurfaceBetweenPanesTests {
    @Test func movesOnlyTheSelectedSurfaceIntoTheAdjacentPaneAndKeepsItFocused() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let selectedPanelId = try #require(workspace.focusedPanelId)
        let selectedPanel = try #require(workspace.terminalPanel(for: selectedPanelId))
        let sourcePaneId = try #require(workspace.paneId(forPanelId: selectedPanelId))
        let remainingPanel = try #require(workspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        let destinationPanel = try #require(
            workspace.newTerminalSplit(from: selectedPanelId, orientation: .horizontal)
        )
        let destinationPaneId = try #require(workspace.paneId(forPanelId: destinationPanel.id))
        let trailingPanel = try #require(
            workspace.newTerminalSurface(inPane: destinationPaneId, focus: false)
        )
        workspace.focusPanel(selectedPanelId)

        #expect(manager.moveSelectedSurfaceToAdjacentPane(.right))
        #expect(workspace.paneId(forPanelId: selectedPanelId) == destinationPaneId)
        #expect(workspace.terminalPanel(for: selectedPanelId) === selectedPanel)
        #expect(workspace.paneId(forPanelId: remainingPanel.id) == sourcePaneId)
        #expect(workspace.focusedPanelId == selectedPanelId)
        #expect(workspace.bonsplitController.focusedPaneId == destinationPaneId)
        let destinationPanelOrder = workspace.bonsplitController.tabs(inPane: destinationPaneId).compactMap {
            workspace.panelIdFromSurfaceId($0.id)
        }
        #expect(destinationPanelOrder == [destinationPanel.id, selectedPanelId, trailingPanel.id])
    }

    @Test func movingTheOnlySurfaceOutOfAPaneCollapsesTheEmptySourcePane() throws {
        let workspace = Workspace()
        let selectedPanelId = try #require(workspace.focusedPanelId)
        let destinationPanel = try #require(
            workspace.newTerminalSplit(from: selectedPanelId, orientation: .horizontal)
        )
        let destinationPaneId = try #require(workspace.paneId(forPanelId: destinationPanel.id))
        workspace.focusPanel(selectedPanelId)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)

        #expect(workspace.moveSelectedSurfaceToAdjacentPane(.right))
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        #expect(workspace.paneId(forPanelId: selectedPanelId) == destinationPaneId)
        #expect(workspace.paneId(forPanelId: destinationPanel.id) == destinationPaneId)
        #expect(workspace.focusedPanelId == selectedPanelId)
    }

    @Test func movesBrowserSurfacesThroughTheSameTransferPath() throws {
        let workspace = Workspace()
        let terminalPanelId = try #require(workspace.focusedPanelId)
        let browserPanel = try #require(
            workspace.newBrowserSplit(from: terminalPanelId, orientation: .horizontal)
        )
        let terminalPaneId = try #require(workspace.paneId(forPanelId: terminalPanelId))
        workspace.focusPanel(browserPanel.id)

        #expect(workspace.moveSelectedSurfaceToAdjacentPane(.left))
        #expect(workspace.paneId(forPanelId: browserPanel.id) == terminalPaneId)
        #expect(workspace.browserPanel(for: browserPanel.id) === browserPanel)
        #expect(workspace.focusedPanelId == browserPanel.id)
    }

    @Test func movesVerticallyThroughTheDirectionalAdjacencyResolver() throws {
        let workspace = Workspace()
        let upperPanelId = try #require(workspace.focusedPanelId)
        let lowerPanel = try #require(
            workspace.newTerminalSplit(from: upperPanelId, orientation: .vertical)
        )
        let lowerPaneId = try #require(workspace.paneId(forPanelId: lowerPanel.id))
        _ = try #require(workspace.newTerminalSurface(inPane: lowerPaneId, focus: false))
        let upperPaneId = try #require(workspace.paneId(forPanelId: upperPanelId))
        workspace.focusPanel(lowerPanel.id)

        #expect(workspace.moveSelectedSurfaceToAdjacentPane(.up))
        #expect(workspace.paneId(forPanelId: lowerPanel.id) == upperPaneId)
        #expect(workspace.moveSelectedSurfaceToAdjacentPane(.down))
        #expect(workspace.paneId(forPanelId: lowerPanel.id) == lowerPaneId)
    }

    @Test func previousAndNextFollowTheSpatialPaneOrder() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let firstPaneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        _ = try #require(workspace.newTerminalSurface(inPane: firstPaneId, focus: false))
        let secondPanel = try #require(workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal))
        let secondPaneId = try #require(workspace.paneId(forPanelId: secondPanel.id))
        _ = try #require(workspace.newTerminalSurface(inPane: secondPaneId, focus: false))
        _ = try #require(workspace.newTerminalSplit(from: secondPanel.id, orientation: .vertical))
        let orderedPaneIds = workspace.spatiallyOrderedPaneIds
        #expect(orderedPaneIds.count == 3)

        workspace.focusPanel(secondPanel.id)
        #expect(workspace.moveSelectedSurfaceToPane(offset: 1))
        #expect(workspace.paneId(forPanelId: secondPanel.id)?.id == orderedPaneIds[2])
        #expect(workspace.focusedPanelId == secondPanel.id)

        #expect(workspace.moveSelectedSurfaceToPane(offset: -1))
        #expect(workspace.paneId(forPanelId: secondPanel.id)?.id == orderedPaneIds[1])
        #expect(workspace.focusedPanelId == secondPanel.id)

        workspace.focusPanel(firstPanelId)
        #expect(workspace.moveSelectedSurfaceToPane(offset: -1))
        #expect(workspace.paneId(forPanelId: firstPanelId)?.id == orderedPaneIds[2])
        #expect(workspace.moveSelectedSurfaceToPane(offset: 1))
        #expect(workspace.paneId(forPanelId: firstPanelId)?.id == orderedPaneIds[0])
    }

    @Test func missingDirectionalDestinationCreatesAnEqualSplitInEveryDirection() throws {
        let scenarios: [(direction: NavigationDirection, orientation: String, insertFirst: Bool)] = [
            (.left, "horizontal", true),
            (.right, "horizontal", false),
            (.up, "vertical", true),
            (.down, "vertical", false),
        ]

        for scenario in scenarios {
            let workspace = Workspace()
            let panelId = try #require(workspace.focusedPanelId)
            let panel = try #require(workspace.terminalPanel(for: panelId))
            let sourcePaneId = try #require(workspace.paneId(forPanelId: panelId))

            #expect(workspace.moveSelectedSurfaceToAdjacentPane(scenario.direction))
            #expect(workspace.bonsplitController.allPaneIds.count == 2)

            let destinationPaneId = try #require(workspace.paneId(forPanelId: panelId))
            #expect(destinationPaneId != sourcePaneId)
            #expect(workspace.terminalPanel(for: panelId) === panel)
            #expect(workspace.focusedPanelId == panelId)
            #expect(workspace.bonsplitController.focusedPaneId == destinationPaneId)

            let sourcePanelIds = workspace.bonsplitController.tabs(inPane: sourcePaneId).compactMap {
                workspace.panelIdFromSurfaceId($0.id)
            }
            #expect(sourcePanelIds.count == 1)
            #expect(sourcePanelIds.first != panelId)

            guard case .split(let split) = workspace.bonsplitController.treeSnapshot() else {
                Issue.record("Expected a split root for \(scenario.direction)")
                continue
            }
            #expect(split.orientation == scenario.orientation)
            #expect(abs(split.dividerPosition - 0.5) < 0.0001)

            let firstPaneId: UUID?
            if case .pane(let pane) = split.first {
                firstPaneId = UUID(uuidString: pane.id)
            } else {
                firstPaneId = nil
            }
            let secondPaneId: UUID?
            if case .pane(let pane) = split.second {
                secondPaneId = UUID(uuidString: pane.id)
            } else {
                secondPaneId = nil
            }
            #expect(firstPaneId == (scenario.insertFirst ? destinationPaneId.id : sourcePaneId.id))
            #expect(secondPaneId == (scenario.insertFirst ? sourcePaneId.id : destinationPaneId.id))
        }
    }

    @Test func missingDirectionalDestinationPreservesAsymmetricParentExtent() throws {
        let scenarios: [(
            direction: NavigationDirection,
            parentOrientation: SplitOrientation,
            parentOrientationName: String,
            childOrientationName: String,
            insertFirst: Bool
        )] = [
            (.left, .vertical, "vertical", "horizontal", true),
            (.right, .vertical, "vertical", "horizontal", false),
            (.up, .horizontal, "horizontal", "vertical", true),
            (.down, .horizontal, "horizontal", "vertical", false),
        ]

        for scenario in scenarios {
            let workspace = Workspace()
            let panelId = try #require(workspace.focusedPanelId)
            let sourcePaneId = try #require(workspace.paneId(forPanelId: panelId))
            let untouchedPanel = try #require(
                workspace.newTerminalSplit(
                    from: panelId,
                    orientation: scenario.parentOrientation,
                    focus: false,
                    initialDividerPosition: 0.3
                )
            )
            let untouchedPaneId = try #require(workspace.paneId(forPanelId: untouchedPanel.id))
            workspace.focusPanel(panelId)

            #expect(workspace.moveSelectedSurfaceToAdjacentPane(scenario.direction))
            let destinationPaneId = try #require(workspace.paneId(forPanelId: panelId))

            guard case .split(let root) = workspace.bonsplitController.treeSnapshot() else {
                Issue.record("Expected the asymmetric parent split for \(scenario.direction)")
                continue
            }
            #expect(root.orientation == scenario.parentOrientationName)
            #expect(abs(root.dividerPosition - 0.3) < 0.0001)

            guard case .split(let sourceRegion) = root.first,
                  case .pane(let untouchedPane) = root.second else {
                Issue.record("Expected only the source parent region to be split for \(scenario.direction)")
                continue
            }
            #expect(sourceRegion.orientation == scenario.childOrientationName)
            #expect(abs(sourceRegion.dividerPosition - 0.5) < 0.0001)
            #expect(UUID(uuidString: untouchedPane.id) == untouchedPaneId.id)

            let firstPaneId: UUID?
            if case .pane(let pane) = sourceRegion.first {
                firstPaneId = UUID(uuidString: pane.id)
            } else {
                firstPaneId = nil
            }
            let secondPaneId: UUID?
            if case .pane(let pane) = sourceRegion.second {
                secondPaneId = UUID(uuidString: pane.id)
            } else {
                secondPaneId = nil
            }
            #expect(firstPaneId == (scenario.insertFirst ? destinationPaneId.id : sourcePaneId.id))
            #expect(secondPaneId == (scenario.insertFirst ? sourcePaneId.id : destinationPaneId.id))
        }
    }

    @Test func missingDestinationMovesTheSameBrowserAndRepairsTheSourceWithATerminal() throws {
        let workspace = Workspace()
        let terminal = try #require(workspace.focusedTerminalPanel)
        let sourcePaneId = try #require(workspace.paneId(forPanelId: terminal.id))
        let browser = try #require(
            workspace.newBrowserSurface(
                inPane: sourcePaneId,
                url: URL(string: "about:blank"),
                focus: true,
                creationPolicy: .restoration
            )
        )
        #expect(workspace.closePanel(terminal.id, force: true))
        #expect(workspace.bonsplitController.tabs(inPane: sourcePaneId).count == 1)

        #expect(workspace.moveSelectedSurfaceToAdjacentPane(.right))
        let destinationPaneId = try #require(workspace.paneId(forPanelId: browser.id))

        #expect(destinationPaneId != sourcePaneId)
        #expect(workspace.browserPanel(for: browser.id) === browser)
        #expect(workspace.focusedPanelId == browser.id)
        #expect(workspace.bonsplitController.focusedPaneId == destinationPaneId)

        let sourcePanelIds = workspace.bonsplitController.tabs(inPane: sourcePaneId).compactMap {
            workspace.panelIdFromSurfaceId($0.id)
        }
        #expect(sourcePanelIds.count == 1)
        let replacementPanelId = try #require(sourcePanelIds.first)
        #expect(replacementPanelId != browser.id)
        #expect(workspace.terminalPanel(for: replacementPanelId) != nil)
    }

    @Test func previousAndNextRemainNoOpsWhenOnlyOnePaneExists() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: panelId))

        #expect(!workspace.moveSelectedSurfaceToPane(offset: -1))
        #expect(!workspace.moveSelectedSurfaceToPane(offset: 1))
        #expect(workspace.paneId(forPanelId: panelId) == paneId)
        #expect(workspace.focusedPanelId == panelId)
    }

    @Test func canvasLayoutDoesNotMutateTheBonsplitTree() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let destinationPanel = try #require(workspace.newTerminalSplit(from: panelId, orientation: .horizontal))
        let originalPaneId = try #require(workspace.paneId(forPanelId: panelId))
        workspace.focusPanel(panelId)
        workspace.setLayoutMode(.canvas)

        #expect(!workspace.moveSelectedSurfaceToAdjacentPane(.right))
        #expect(workspace.paneId(forPanelId: panelId) == originalPaneId)
        #expect(workspace.paneId(forPanelId: destinationPanel.id) != originalPaneId)
    }

    @Test func remoteTmuxMirrorDoesNotMutateTheLocalPaneTree() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        _ = try #require(workspace.newTerminalSplit(from: panelId, orientation: .horizontal))
        let originalPaneId = try #require(workspace.paneId(forPanelId: panelId))
        workspace.focusPanel(panelId)
        workspace.isRemoteTmuxMirror = true

        #expect(!workspace.moveSelectedSurfaceToAdjacentPane(.right))
        #expect(!workspace.moveSelectedSurfaceToPane(offset: 1))
        #expect(workspace.paneId(forPanelId: panelId) == originalPaneId)
    }

    @Test func shortcutAndCommandPaletteMetadataIsCompleteAndUnambiguous() throws {
        let paneMoveActions: [KeyboardShortcutSettings.Action] = [
            .moveSurfaceToPreviousPane,
            .moveSurfaceToNextPane,
            .moveSurfaceToPaneLeft,
            .moveSurfaceToPaneRight,
            .moveSurfaceToPaneUp,
            .moveSurfaceToPaneDown,
        ]

        for action in paneMoveActions {
            #expect(KeyboardShortcutSettings.publicShortcutActions.contains(action))
            #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(action))
            let settingsAction = try #require(ShortcutAction(rawValue: action.rawValue))
            #expect(settingsAction.displayName == action.label)
            #expect(settingsAction.defaultStroke == nil)
            #expect(action.defaultShortcut == .unbound)
        }

        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.moveSurfaceToPreviousPane") == .moveSurfaceToPreviousPane)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.moveSurfaceToNextPane") == .moveSurfaceToNextPane)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.moveSurfaceToPaneLeft") == .moveSurfaceToPaneLeft)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.moveSurfaceToPaneRight") == .moveSurfaceToPaneRight)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.moveSurfaceToPaneUp") == .moveSurfaceToPaneUp)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.moveSurfaceToPaneDown") == .moveSurfaceToPaneDown)
    }

    @Test func optionArrowMovementUsesPhysicalDirectionalRouting() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let action = KeyboardShortcutSettings.Action.moveSurfaceToPaneLeft
        let defaults = UserDefaults.standard
        let originalShortcutValue = defaults.object(forKey: action.defaultsKey)
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-move-surface-pane-shortcut"
        )
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            if let originalShortcutValue {
                defaults.set(originalShortcutValue, forKey: action.defaultsKey)
            } else {
                defaults.removeObject(forKey: action.defaultsKey)
            }
            appDelegate.debugResetShortcutRoutingStateForTesting()
        }
        let shortcut = StoredShortcut(
            key: "←",
            command: false,
            shift: false,
            option: true,
            control: false
        )
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
        appDelegate.debugResetShortcutRoutingStateForTesting()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 123
        ))

        #expect(appDelegate.handleAdjacentNavigationShortcut(event: event))
    }
}
