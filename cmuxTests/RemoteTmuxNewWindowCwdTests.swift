import AppKit
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
/// focused tab's directory. cmux seeds that directory via
/// ``RemoteTmuxHost/newWindowCommand(workingDirectory:)``.
///
/// These assert the produced control-mode command: a known directory must carry
/// a single-quoted `-c`, and absent/blank/unsafe directories must fall back to a
/// bare `new-window` so a missing cwd can never break the control stream.
@Suite struct RemoteTmuxNewWindowCwdTests {

    @Test func seedsStartingDirectoryWhenKnown() {
        #expect(
            RemoteTmuxHost.newWindowCommand(workingDirectory: "/Users/me/proj")
                == "new-window -c '/Users/me/proj'"
        )
    }

    @Test func singleQuotesPathsWithSpaces() {
        #expect(
            RemoteTmuxHost.newWindowCommand(workingDirectory: "/Users/me/My Project")
                == "new-window -c '/Users/me/My Project'"
        )
    }

    @Test func escapesEmbeddedSingleQuote() {
        // shell single-quote escaping: ' -> '\'' so the path survives tmux's parser.
        #expect(
            RemoteTmuxHost.newWindowCommand(workingDirectory: "/Users/me/o'brien")
                == "new-window -c '/Users/me/o'\\''brien'"
        )
    }

    @Test(arguments: [
        nil,
        "",
        "   ",
        "\t",
    ])
    func fallsBackToBareNewWindowWhenDirectoryUnusable(_ directory: String?) {
        #expect(RemoteTmuxHost.newWindowCommand(workingDirectory: directory) == "new-window")
    }

    @Test(arguments: [
        "/Users/me/pro\nject",
        "/Users/me/pro\rject",
        "/Users/me/pro\u{0}ject",
    ])
    func rejectsDirectoriesThatCouldBreakTheControlStream(_ directory: String) {
        // CR/LF/control bytes could terminate the command line before tmux parses
        // the quoted argument, so an unsafe path must degrade to a bare command.
        #expect(RemoteTmuxHost.newWindowCommand(workingDirectory: directory) == "new-window")
    }
}

/// Coverage for the workspace-side resolution that feeds the command above. A
/// remote-tmux mirror new tab must inherit ONLY a directory the remote actually
/// reported for the source tab (`panelDirectories`, sourced from
/// `#{pane_current_path}`) — never the generic resolver's `currentDirectory`
/// fallback, which for a mirror is seeded from the LOCAL workspace it was
/// created from. Sending that local path as `new-window -c` would point the
/// remote at a nonexistent directory and tmux could reject the command,
/// silently producing no tab.
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

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let workspace: Workspace
        let sourcePanelId: UUID

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
            workspace.isRemoteTmuxMirror = true
            sourcePanelId = try #require(workspace.focusedPanelId)
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
