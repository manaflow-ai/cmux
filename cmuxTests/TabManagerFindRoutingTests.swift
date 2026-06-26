import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for routing the global Cmd+F find command to non-terminal,
/// non-browser panels (issue #6247, consolidating #6049 and #6050).
///
/// Before find routing was generalized, ``TabManager/startSearch()`` only
/// consulted the focused terminal and browser panels. Any other focused panel
/// type — file preview, markdown, agent session, project — silently swallowed
/// Cmd+F and `startSearch()` returned `false`.
@MainActor
@Suite(.serialized)
struct TabManagerFindRoutingTests {
    /// A focused ``ProjectPanel`` must handle Cmd+F: ``TabManager/startSearch()``
    /// returns `true` because the panel routes find into its filter field.
    ///
    /// ``ProjectPanel`` is used as the representative findable panel because its
    /// ``ProjectPanel/startFind()`` result is deterministic and does not depend
    /// on an attached AppKit text view or first-responder state, making it
    /// reliable in a headless test. The terminal- and browser-only routing this
    /// guards against returns `false` here, so the assertion is red without the
    /// find-routing fix and green with it.
    @Test
    func startSearchIsHandledByFocusedProjectPanel() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-find-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let projectPanel = try #require(workspace.newProjectSurface(
            inPane: paneId,
            projectPath: projectDirectory.path,
            focus: true
        ))

        // The project panel — not a terminal or browser — is now focused.
        #expect(workspace.focusedPanelId == projectPanel.id)
        #expect(workspace.focusedTerminalPanel == nil)

        // Cmd+F must be handled by the focused findable panel.
        #expect(manager.startSearch())
    }
}
