import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/8380.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorRenameTests {
    @Test func everyMultiPaneSurfaceRenamesItsOwningTmuxWindow() throws {
        let harness = try RemoteTmuxMirrorRenameHarness()
        defer { harness.tearDown() }

        let initialSurfaces = try harness.surfaces()
        #expect(initialSurfaces.map(\.title) == ["main", "main [1]"])
        let focusedSurface = try #require(initialSurfaces.first(where: { $0.isFocused }))
        let containerIDs = try initialSurfaces.map {
            try #require(harness.workspace.remoteTmuxControlPane(surfaceID: $0.surfaceID)?.containerPanelID)
        }
        let containerID = try #require(containerIDs.first)
        #expect(containerIDs.allSatisfy { $0 == containerID })

        for action in ["clear_name", "mark_unread"] {
            let unrelatedAction = TerminalController.shared.controlTabAction(
                routing: ControlRoutingSelectors(
                    hasWindowIDParam: false,
                    windowID: nil,
                    groupID: nil,
                    workspaceID: harness.workspace.id,
                    surfaceID: focusedSurface.surfaceID,
                    paneID: nil
                ),
                actionKey: action,
                title: nil,
                rawURL: nil,
                surfaceID: focusedSurface.surfaceID,
                requestedFocus: false,
                moveParams: [:]
            )
            #expect(unrelatedAction == .tabNotFound(surfaceID: focusedSurface.surfaceID))
        }

        for (index, surface) in initialSurfaces.enumerated() {
            let title = "dogfood-multi-renamed-\(index)"
            let routing = ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: index == 0 ? nil : harness.workspace.id,
                surfaceID: surface.surfaceID,
                paneID: nil
            )
            let resolution = TerminalController.shared.controlTabAction(
                routing: routing,
                actionKey: "rename",
                title: title,
                rawURL: nil,
                surfaceID: surface.surfaceID,
                requestedFocus: false,
                moveParams: [:]
            )

            guard case .completed(let outcome) = resolution else {
                Issue.record("Expected a completed rename, got \(resolution)")
                continue
            }
            #expect(outcome.workspaceID == harness.workspace.id)
            #expect(outcome.surfaceID == surface.surfaceID)
            #expect(outcome.paneID == surface.paneID)
            #expect(outcome.extras == .title(title))
            #expect(harness.workspace.panelCustomTitles[containerID] == title)

            harness.connection.handleMessageForTesting(
                .windowRenamed(windowId: 2, name: title)
            )
            #expect(try harness.surfaces().map(\.title) == [title, "\(title) [1]"])
        }

        let focusedTitle = "dogfood-multi-renamed-focused"
        let focusedResolution = TerminalController.shared.controlTabAction(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: harness.workspace.id,
                surfaceID: nil,
                paneID: nil
            ),
            actionKey: "rename",
            title: focusedTitle,
            rawURL: nil,
            surfaceID: nil,
            requestedFocus: false,
            moveParams: [:]
        )
        guard case .completed(let focusedOutcome) = focusedResolution else {
            Issue.record("Expected a completed focused rename, got \(focusedResolution)")
            return
        }
        #expect(focusedOutcome.surfaceID == focusedSurface.surfaceID)
        #expect(focusedOutcome.paneID == focusedSurface.paneID)
        #expect(harness.workspace.panelCustomTitles[containerID] == focusedTitle)

        let renameCommands = try harness.finishCommands().filter {
            $0.hasPrefix("rename-window ")
        }
        #expect(renameCommands == [
            "rename-window -t @2 'dogfood-multi-renamed-0'",
            "rename-window -t @2 'dogfood-multi-renamed-1'",
            "rename-window -t @2 'dogfood-multi-renamed-focused'",
        ])
    }

    @Test func routedRemotePaneRenamesItsWindowInsteadOfTheFocusedWindow() throws {
        let harness = try RemoteTmuxMirrorRenameHarness(includeSecondWindow: true)
        defer { harness.tearDown() }

        let surfaces = try harness.surfaces()
        #expect(surfaces.map(\.title) == ["main", "main [1]", "logs"])
        let logs = try #require(surfaces.first(where: { $0.title == "logs" }))
        let logsPaneID = try #require(logs.paneID)
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: nil,
            surfaceID: nil,
            paneID: logsPaneID
        )
        let resolution = TerminalController.shared.controlTabAction(
            routing: routing,
            actionKey: "rename",
            title: "dogfood-pane-routed",
            rawURL: nil,
            surfaceID: nil,
            requestedFocus: false,
            moveParams: [:]
        )

        guard case .completed(let outcome) = resolution else {
            Issue.record("Expected a completed pane-routed rename, got \(resolution)")
            return
        }
        #expect(outcome.surfaceID == logs.surfaceID)
        #expect(outcome.paneID == logsPaneID)
        let renameCommands = try harness.finishCommands().filter {
            $0.hasPrefix("rename-window ")
        }
        #expect(renameCommands == ["rename-window -t @3 'dogfood-pane-routed'"])
    }
}
