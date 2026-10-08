import Bonsplit
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorZoomTests {
    typealias Harness = RemoteTmuxMirrorCLIObservabilityTests.Harness

    @Test func headerZoomTargetsTheClickedRemotePaneWithoutLocalZoom() throws {
        let harness = try Harness(connectedTransport: true)
        defer { harness.tearDown() }
        let layoutBefore = harness.mirror.renderedLayout

        for tmuxPaneID in [11, 22] {
            let tabID = try #require(harness.mirror.tabIdByPaneId[tmuxPaneID])
            let paneID = try #require(harness.mirror.paneIdByPaneId[tmuxPaneID])
            #expect(harness.mirror.bonsplitController.requestTabZoomToggle(
                for: tabID, inPane: paneID
            ))
            #expect(!harness.mirror.bonsplitController.isSplitZoomed)
            #expect(harness.mirror.renderedLayout == layoutBefore)
            #expect(!harness.workspace.bonsplitController.isSplitZoomed)
        }

        #expect(try resizeCommands(harness) == [
            "resize-pane -Z -t @3.%11",
            "resize-pane -Z -t @3.%22",
        ])
    }

    @Test func workspaceZoomRoutesExplicitAndFocusedPaneTargets() throws {
        let harness = try Harness(connectedTransport: true)
        defer { harness.tearDown() }
        let surfaceID = try #require(harness.mirror.panel(forPane: 11)?.id)

        #expect(harness.workspace.toggleSplitZoom(panelId: surfaceID))
        // The outer container follows the active inner pane for shortcuts.
        #expect(harness.workspace.toggleSplitZoom(panelId: harness.outerPanelID))
        #expect(!harness.workspace.bonsplitController.isSplitZoomed)
        #expect(!harness.mirror.bonsplitController.isSplitZoomed)
        #expect(try resizeCommands(harness) == [
            "resize-pane -Z -t @3.%11",
            "resize-pane -Z -t @3.%22",
        ])
    }

    @Test func disconnectedZoomRejectsWithoutExpandingLocalPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tabID = try #require(harness.mirror.tabIdByPaneId[11])
        let paneID = try #require(harness.mirror.paneIdByPaneId[11])
        let surfaceID = try #require(harness.mirror.panel(forPane: 11)?.id)

        #expect(!harness.mirror.bonsplitController.requestTabZoomToggle(
            for: tabID, inPane: paneID
        ))
        #expect(!harness.workspace.toggleSplitZoom(panelId: surfaceID))
        #expect(!harness.workspace.toggleSplitZoom(panelId: harness.outerPanelID))
        #expect(!harness.mirror.bonsplitController.isSplitZoomed)
        #expect(!harness.workspace.bonsplitController.isSplitZoomed)
    }

    @Test func containerWithoutActivePaneRejectsZoom() throws {
        let harness = try Harness(activeTmuxPaneID: nil, connectedTransport: true)
        defer { harness.tearDown() }

        #expect(!harness.workspace.toggleSplitZoom(panelId: harness.outerPanelID))
        #expect(!harness.workspace.toggleSplitZoom(panelId: UUID()))
        #expect(!harness.workspace.bonsplitController.isSplitZoomed)
        #expect(try resizeCommands(harness).isEmpty)
    }

    @Test func remoteZoomPublicationFillsWindowAndPreservesHiddenPanels() throws {
        let harness = try Harness(connectedTransport: true)
        defer { harness.tearDown() }
        let mirror = harness.mirror
        let baseLayout = mirror.layout
        let surfacesBefore = mirror.controlPanes().map(\.panel.id)
        let visibleLayout = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0, content: .pane(22)
        )

        mirror.apply(window: RemoteTmuxWindow(
            id: 3, width: 80, height: 24, layout: baseLayout,
            visibleLayout: visibleLayout, zoomed: true
        ))

        #expect(mirror.zoomed)
        #expect(mirror.renderedLayout == visibleLayout)
        #expect(mirror.bonsplitController.allPaneIds.count == 1)
        #expect(mirror.controlPanes().map(\.panel.id) == surfacesBefore)
        let tabID = try #require(mirror.tabIdByPaneId[22])
        let paneID = try #require(mirror.paneIdByPaneId[22])
        // There is only one native pane while tmux is zoomed. The same
        // header gesture must still send the remote unzoom command.
        #expect(mirror.bonsplitController.requestTabZoomToggle(for: tabID, inPane: paneID))

        mirror.apply(window: RemoteTmuxWindow(
            id: 3, width: 80, height: 24, layout: baseLayout,
            visibleLayout: baseLayout, zoomed: false
        ))

        #expect(!mirror.zoomed)
        #expect(mirror.renderedLayout == baseLayout)
        #expect(mirror.bonsplitController.allPaneIds.count == 2)
        #expect(mirror.controlPanes().map(\.panel.id) == surfacesBefore)
        #expect(try resizeCommands(harness) == ["resize-pane -Z -t @3.%22"])
    }

    @Test func sessionOwnedPaneZoomUsesItsOwningWindow() throws {
        let harness = try RemoteTmuxMirrorRenameHarness(includeSecondWindow: true)
        defer { harness.tearDown() }
        let surfaces = try harness.surfaces()
        let main = try #require(surfaces.first(where: { $0.title == "main [1]" }))
        let logs = try #require(surfaces.first(where: { $0.title == "logs" }))

        #expect(harness.workspace.toggleSplitZoom(panelId: main.surfaceID))
        #expect(harness.workspace.toggleSplitZoom(panelId: logs.surfaceID))
        #expect(!harness.workspace.bonsplitController.isSplitZoomed)
        #expect(try harness.finishCommands().filter { $0.hasPrefix("resize-pane ") } == [
            "resize-pane -Z -t @2.%5",
            "resize-pane -Z -t @3.%6",
        ])
    }

    private func resizeCommands(_ harness: Harness) throws -> [String] {
        let writer = try #require(harness.controlWriter)
        let pipe = try #require(harness.controlPipe)
        writer.close()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("resize-pane ") }
    }
}
