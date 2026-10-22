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
    @Test func everyMultiPaneSurfaceRenamesOnlyItsTmuxPane() throws {
        let harness = try RemoteTmuxMirrorRenameHarness()
        defer { harness.tearDown() }

        let initialSurfaces = try harness.surfaces()
        #expect(initialSurfaces.map(\.title) == ["main", "main [1]"])
        let focusedSurface = try #require(initialSurfaces.first(where: { $0.isFocused }))
        for (index, surface) in initialSurfaces.enumerated() {
            let title = "multi-pane-renamed-\(index)"
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
            #expect(harness.workspace.panelCustomTitles[surface.surfaceID] == title)
        }

        let focusedTitle = "multi-pane-renamed-focused"
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
        let containerID = try #require(harness.workspace.controlTabTarget(for: focusedSurface.surfaceID)?.panelID)
        #expect(harness.workspace.panelCustomTitles[containerID] == focusedTitle)

        let commands = try harness.finishCommands()
        #expect(commands.filter { $0.hasPrefix("rename-window ") } == [
            "rename-window -t @2 'multi-pane-renamed-focused'",
        ])
        #expect(commands.filter { $0.hasPrefix("select-pane ") } == [
            "select-pane -t %4 -T 'multi-pane-renamed-0'",
            "select-pane -t %5 -T 'multi-pane-renamed-1'",
        ])
    }

    @Test func clearNameOnProjectedPaneClearsOnlyThatTmuxPane() throws {
        let harness = try RemoteTmuxMirrorRenameHarness()
        defer { harness.tearDown() }

        let surface = try #require(harness.surfaces().first)
        let resolution = TerminalController.shared.controlTabAction(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: harness.workspace.id,
                surfaceID: surface.surfaceID,
                paneID: nil
            ),
            actionKey: "clear_name",
            title: nil,
            rawURL: nil,
            surfaceID: surface.surfaceID,
            requestedFocus: false,
            moveParams: [:]
        )

        guard case .completed = resolution else {
            Issue.record("Expected a completed clear_name, got \(resolution)")
            return
        }
        let commands = try harness.finishCommands()
        #expect(commands.filter { $0.hasPrefix("rename-window ") }.isEmpty)
        #expect(commands.filter { $0.hasPrefix("select-pane ") } == [
            "select-pane -t %4 -T ''",
        ])
    }

    @Test func routedRemotePaneRenamesItsAddressedPaneInsteadOfTheFocusedWindow() throws {
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
            title: "pane-routed",
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
        let commands = try harness.finishCommands()
        #expect(commands.filter { $0.hasPrefix("rename-window ") }.isEmpty)
        #expect(commands.filter { $0.hasPrefix("select-pane ") } == [
            "select-pane -t %6 -T 'pane-routed'",
        ])
    }

    @Test func workspaceRenameKeepsTmuxFormatsLiteral() throws {
        let harness = try RemoteTmuxMirrorRenameHarness()
        defer { harness.tearDown() }

        harness.controller.handleMirrorWorkspaceRenamed(
            workspaceId: harness.workspace.id,
            title: "#S's workspace"
        )

        let commands = try harness.finishCommands()
        #expect(commands.filter { $0.hasPrefix("rename-session ") } == [
            "rename-session -t 'test-issue-8380' '##S'\\''s workspace'",
        ])
    }

    @Test func windowRenameKeepsTmuxFormatsLiteral() throws {
        let harness = try RemoteTmuxMirrorRenameHarness(includeSecondWindow: true)
        defer { harness.tearDown() }

        let logsPanelID = try #require(
            harness.workspace.remoteTmuxWindowMirrors.first(where: { $0.value.windowId == 3 })?.key
        )
        harness.controller.handleMirrorWindowRenamed(
            workspaceId: harness.workspace.id,
            panelId: logsPanelID,
            title: "#W's window"
        )

        let commands = try harness.finishCommands()
        #expect(commands.filter { $0.hasPrefix("rename-window ") } == [
            "rename-window -t @3 '##W'\\''s window'",
        ])
    }
}
