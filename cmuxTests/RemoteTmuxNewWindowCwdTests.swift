import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for remote-tmux (`cmux ssh-tmux`) new-tab cwd inheritance.
///
/// In local cmux a new tab inherits the active tab's working directory; the
/// remote mirror routes a new tab to a tmux `new-window`, which — without an
/// explicit `-c <path>` — starts in tmux's default-path (`~`) instead of the
/// focused tab's directory. cmux appends that directory onto the placement
/// command built by ``RemoteTmuxController/newWindowCommand(afterWindowId:workingDirectory:)``.
///
/// These assert the produced control-mode command: a known directory adds a
/// single-quoted `-c` after the placement target, and absent/blank/unsafe
/// directories leave the placement-only command so a missing cwd can never break
/// the control stream.
@Suite struct RemoteTmuxNewWindowCwdTests {
    @Test func seedsStartingDirectoryAfterSelectedWindow() {
        #expect(
            RemoteTmuxController.newWindowCommand(afterWindowId: 7, workingDirectory: "/Users/me/proj")
                == "new-window -a -t @7 -c '/Users/me/proj'"
        )
    }

    @Test func seedsStartingDirectoryForEndPlacement() {
        #expect(
            RemoteTmuxController.newWindowCommand(afterWindowId: nil, workingDirectory: "/Users/me/proj")
                == "new-window -a -t '{end}' -c '/Users/me/proj'"
        )
    }

    @Test func singleQuotesPathsWithSpaces() {
        #expect(
            RemoteTmuxController.newWindowCommand(afterWindowId: 7, workingDirectory: "/Users/me/My Project")
                == "new-window -a -t @7 -c '/Users/me/My Project'"
        )
    }

    @Test func escapesEmbeddedSingleQuote() {
        // shell single-quote escaping: ' -> '\'' so the path survives tmux's parser.
        #expect(
            RemoteTmuxController.newWindowCommand(afterWindowId: 7, workingDirectory: "/Users/me/o'brien")
                == "new-window -a -t @7 -c '/Users/me/o'\\''brien'"
        )
    }

    @Test(arguments: [
        nil,
        "",
        "   ",
        "\t",
    ])
    func omitsDirectoryWhenUnusable(_ directory: String?) {
        #expect(
            RemoteTmuxController.newWindowCommand(afterWindowId: 7, workingDirectory: directory)
                == "new-window -a -t @7"
        )
    }

    @Test(arguments: [
        "/Users/me/pro\nject",
        "/Users/me/pro\rject",
        "/Users/me/pro\u{0}ject",
    ])
    func dropsDirectoriesThatCouldBreakTheControlStream(_ directory: String) {
        // CR/LF/control bytes could terminate the command line before tmux parses
        // the quoted argument, so an unsafe path leaves the placement-only command.
        #expect(
            RemoteTmuxController.newWindowCommand(afterWindowId: 7, workingDirectory: directory)
                == "new-window -a -t @7"
        )
    }

    @Test func keepsDirectoryWhenSourcePanelHasLiveMirrorWindow() {
        let sourcePanelId = UUID()

        #expect(
            RemoteTmuxController.liveMirrorWindowWorkingDirectory(
                "/srv/remote/project",
                sourcePanelId: sourcePanelId,
                windowIdForPanel: { panelId in panelId == sourcePanelId ? 7 : nil }
            ) == "/srv/remote/project"
        )
    }

    @Test func dropsDirectoryWhenSourcePanelHasNoLiveMirrorWindow() {
        let sourcePanelId = UUID()

        #expect(
            RemoteTmuxController.liveMirrorWindowWorkingDirectory(
                "/Users/local/project",
                sourcePanelId: sourcePanelId,
                windowIdForPanel: { _ in nil }
            ) == nil
        )
    }

    @Test func dropsDirectoryWhenSourcePanelIsUnknown() {
        #expect(
            RemoteTmuxController.liveMirrorWindowWorkingDirectory(
                "/Users/local/project",
                sourcePanelId: nil,
                windowIdForPanel: { _ in 7 }
            ) == nil
        )
    }
}

/// Coverage for the workspace-side resolution that feeds the command above. A
/// remote-tmux mirror new tab must inherit ONLY a directory the remote actually
/// reported for the source tab (`panelDirectories`, sourced from
/// `#{pane_current_path}`) — never the generic resolver's `currentDirectory`
/// fallback, which for a mirror is seeded from the LOCAL workspace it was
/// created from. A local path is meaningless on the remote and would open the
/// new tab in the wrong directory.
@MainActor
@Suite(.serialized) struct RemoteTmuxNewWindowWorkingDirectoryResolutionTests {
    @Test func inheritsSourceTabsReportedRemoteDirectory() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.workspace.panelDirectories[harness.sourcePanelId] = "/srv/remote/project"

        #expect(
            harness.workspace.remoteTmuxNewWindowWorkingDirectory(forSourcePanelId: harness.sourcePanelId)
                == "/srv/remote/project"
        )
    }

    @Test func ignoresLocalCurrentDirectoryWhenSourceTabHasNoRemoteReport() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        // The mirror workspace's currentDirectory is seeded from the local
        // workspace — it must NOT leak into a remote `new-window -c`.
        harness.workspace.currentDirectory = "/Users/local/home"
        harness.workspace.panelDirectories.removeValue(forKey: harness.sourcePanelId)

        #expect(
            harness.workspace.remoteTmuxNewWindowWorkingDirectory(forSourcePanelId: harness.sourcePanelId) == nil
        )
    }

    @Test func returnsNilForUnknownSourcePanel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        #expect(harness.workspace.remoteTmuxNewWindowWorkingDirectory(forSourcePanelId: nil) == nil)
        #expect(harness.workspace.remoteTmuxNewWindowWorkingDirectory(forSourcePanelId: UUID()) == nil)
    }

    @Test func treatsBlankReportedDirectoryAsUnknown() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.workspace.panelDirectories[harness.sourcePanelId] = "   "

        #expect(
            harness.workspace.remoteTmuxNewWindowWorkingDirectory(forSourcePanelId: harness.sourcePanelId) == nil
        )
    }

    @Test func targetedAnchorOverridesEndPlacement() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let anchorPanelId = try harness.makeAdditionalTerminalPanel()
        var configuration = harness.workspace.bonsplitController.configuration
        configuration.newTabPosition = .end
        harness.workspace.bonsplitController.configuration = configuration

        #expect(
            harness.workspace.remoteTmuxNewTabPlacement(
                inPane: harness.paneId,
                anchorPanelId: anchorPanelId
            ) == .afterPanel(anchorPanelId)
        )
    }

    @Test func plainCurrentPlacementUsesSelectedPanel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        var configuration = harness.workspace.bonsplitController.configuration
        configuration.newTabPosition = .current
        harness.workspace.bonsplitController.configuration = configuration

        #expect(
            harness.workspace.remoteTmuxNewTabPlacement(
                inPane: harness.paneId,
                anchorPanelId: nil
            ) == .afterPanel(harness.sourcePanelId)
        )
    }

    @Test func plainEndPlacementAppendsWhenNoAnchorIsRequested() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        var configuration = harness.workspace.bonsplitController.configuration
        configuration.newTabPosition = .end
        harness.workspace.bonsplitController.configuration = configuration

        #expect(
            harness.workspace.remoteTmuxNewTabPlacement(
                inPane: harness.paneId,
                anchorPanelId: nil
            ) == .end
        )
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let workspace: Workspace
        let paneId: PaneID
        let sourcePanelId: UUID

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
            workspace.isRemoteTmuxMirror = true
            sourcePanelId = try #require(workspace.focusedPanelId)
            paneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        }

        func makeAdditionalTerminalPanel() throws -> UUID {
            let wasRemoteTmuxMirror = workspace.isRemoteTmuxMirror
            workspace.isRemoteTmuxMirror = false
            defer { workspace.isRemoteTmuxMirror = wasRemoteTmuxMirror }
            return try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)?.id)
        }

        func tearDown() {
            workspace.isRemoteTmuxMirror = false
            let identifier = "cmux.main.\(windowId.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}
