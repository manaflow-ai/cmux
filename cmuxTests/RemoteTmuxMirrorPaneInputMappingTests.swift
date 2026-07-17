import AppKit
import Foundation
import Testing
import CmuxTerminal
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for per-pane input routing in a mirrored multi-pane tmux
/// window: the pane that a click SELECTS must be the same pane that typed input
/// REACHES. See ``RemoteTmuxWindowMirror`` + ``RemoteTmuxSessionMirror``.
///
/// These assertions run against the REAL closures the mirror installs. A mirror
/// pane's typed input is delivered by `TerminalSurface.manualInputHandler`, which
/// the mirror wires per pane in `makeRemoteTmuxPanePanel(onInput:)` — the handler
/// for pane %N calls `connection.sendKeys(paneId: N, ...)`. The click/select path
/// resolves a clicked bonsplit pane to a tmux id through
/// `paneIdByBonsplitPane`, while the rendered surface (whose handler fires on a
/// keystroke) is chosen by `tmuxPaneId(forTab:)`. If those two maps disagree for
/// the same visual pane, you select one pane and type into another.
///
/// The manual-input handler itself is `internal` to CmuxTerminal and cannot be
/// invoked from this target without a live libghostty surface (unavailable in the
/// unit host), so these tests assert the equivalent structural invariant on the
/// mirror's own maps: select-target == render/input-target, per pane. That is the
/// exact identity the handler closes over, so a divergence here is a divergence in
/// where keys land.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorPaneInputMappingTests {

    // MARK: - Harness (mirrors MirrorTitleHarness in RemoteTmuxMirrorTargetingTests)

    @MainActor
    private final class Harness {
        let windowId: UUID
        let controller: RemoteTmuxController
        let host: RemoteTmuxHost
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
        let workspace: Workspace

        init() throws {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let controller = RemoteTmuxController()
            let host = RemoteTmuxHost(destination: "user@paneinput")
            let connection = RemoteTmuxControlConnection(host: host, sessionName: "input-map")
            let pipe = Pipe()
            let writer = RemoteTmuxControlPipeWriter(
                handle: pipe.fileHandleForWriting,
                label: "remote-tmux-pane-input-map-test",
                maxPendingBytes: 1 << 16,
                onFailure: {}
            )
            connection.installStdinWriterForTesting(writer)
            connection.handleMessageForTesting(.enter)
            connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
            controller.cacheConnection(connection)
            try controller.mirrorSession(host: host, sessionName: "input-map", into: manager)
            self.workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
            self.windowId = windowId
            self.controller = controller
            self.host = host
            self.connection = connection
            self.writer = writer
            self.pipe = pipe
        }

        func publishListWindows(_ lines: [String]) {
            connection.handleMessageForTesting(.commandResult(commandNumber: 1, lines: lines, isError: false))
        }

        func drainThroughPaneRects(_ linesByWindow: [Int: [String]]) throws {
            while let kind = connection.pendingCommandKindsForTesting.first {
                let lines: [String]
                if case let .paneRects(windowId, _) = kind {
                    lines = try #require(linesByWindow[windowId])
                } else {
                    lines = []
                }
                connection.handleMessageForTesting(.commandResult(commandNumber: 2, lines: lines, isError: false))
            }
        }

        func mirror() throws -> RemoteTmuxWindowMirror {
            let panelId = try #require(
                workspace.remoteTmuxSessionMirror?.panelIdByWindow.values.first,
                "Expected a mirrored window tab"
            )
            return try #require(
                workspace.remoteTmuxWindowMirror(forPanelId: panelId),
                "Expected a multi-pane window mirror"
            )
        }

        func tearDown() {
            controller.detach(host: host, sessionName: "input-map")
            writer.close()
            try? pipe.fileHandleForReading.close()
            let identifier = "cmux.main.\(windowId.uuidString)"
            NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    /// For every bonsplit pane in the mirror, the tmux id that the SELECT path
    /// resolves (`paneIdByBonsplitPane`, used by `didFocusPane` → `select-pane`)
    /// must equal the tmux id whose surface is RENDERED there and whose input
    /// handler therefore fires (`tmuxPaneId(forTab:)` of the pane's selected tab).
    private func expectSelectTargetMatchesInputTarget(
        _ mirror: RemoteTmuxWindowMirror
    ) throws {
        let paneIds = mirror.bonsplitController.allPaneIds
        #expect(paneIds.count >= 2, "Expected a multi-pane bonsplit tree")
        for bonsplitPane in paneIds {
            let selectTarget = try #require(
                mirror.paneIdByBonsplitPane[bonsplitPane],
                "Every rendered bonsplit pane must resolve a tmux select target"
            )
            let selectedTab = try #require(
                mirror.bonsplitController.selectedTab(inPane: bonsplitPane),
                "Every bonsplit pane renders a selected tab"
            )
            let inputTarget = try #require(
                mirror.tmuxPaneId(forTab: selectedTab.id),
                "The rendered tab must resolve to the tmux pane whose input handler fires"
            )
            #expect(
                selectTarget == inputTarget,
                "Pane selection routes to %\(selectTarget) but typed input reaches %\(inputTarget)"
            )
        }
    }

    /// Distinct panes render distinct surfaces, so a keystroke into one pane can
    /// never be swallowed by another pane's handler.
    private func expectDistinctSurfacesPerPane(_ mirror: RemoteTmuxWindowMirror) throws {
        let paneIds = mirror.paneIDsInOrder
        var surfaceIds: Set<UUID> = []
        for tmuxPaneId in paneIds {
            let panel = try #require(mirror.panel(forPane: tmuxPaneId), "Every live pane owns a panel")
            #expect(surfaceIds.insert(panel.surface.id).inserted, "Each pane must own a distinct surface")
        }
        #expect(surfaceIds.count == paneIds.count)
    }

    @Test
    func multiPaneWindowSelectTargetEqualsInputTargetForEveryPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.publishListWindows([
            "@2 abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} [] work",
        ])
        try harness.drainThroughPaneRects([2: [
            "%4 0 0 60 40 1 off :0 \"host\"",
            "%5 61 0 59 40 0 off :1 \"host\"",
        ]])

        let mirror = try harness.mirror()
        try expectSelectTargetMatchesInputTarget(mirror)
        try expectDistinctSurfacesPerPane(mirror)
    }

    /// The reported repro: a window cmux first saw as a single pane, then split.
    /// The original display pane is adopted as pane one; the new split pane gets a
    /// freshly wired handler. After the split + the `%window-pane-changed` event
    /// tmux emits (the new pane becomes active), select-target and input-target
    /// must still agree for both panes, and the new pane must be the active/input
    /// target — with no intervening manual click.
    @Test
    func singlePaneToSplitKeepsSelectAndInputTargetsAlignedForNewPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.publishListWindows([
            "@2 f92f,80x24,0,0,4 f92f,80x24,0,0,4 [] zsh",
        ])
        try harness.drainThroughPaneRects([2: ["%4 0 0 80 24 1 off :0 \"host\""]])

        // tmux splits window @2: pane %5 is created and becomes the active pane.
        harness.connection.handleMessageForTesting(.layoutChange(
            windowId: 2,
            layout: "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5}",
            visibleLayout: nil,
            zoomed: false
        ))
        try harness.drainThroughPaneRects([2: [
            "%4 0 0 60 40 0 off :0 \"host\"",
            "%5 61 0 59 40 1 off :1 \"host\"",
        ]])
        // The active-pane notification the app receives for the newly split pane.
        harness.connection.handleMessageForTesting(.windowPaneChanged(windowId: 2, paneId: 5))

        let mirror = try harness.mirror()
        try expectSelectTargetMatchesInputTarget(mirror)
        try expectDistinctSurfacesPerPane(mirror)

        // The freshly split pane is the one the user is looking at; it must be the
        // mirror's active/input target immediately, not the original pane.
        #expect(
            mirror.activePaneId == 5,
            "The newly split pane must be the active input target without a click; got \(String(describing: mirror.activePaneId))"
        )
    }
}
