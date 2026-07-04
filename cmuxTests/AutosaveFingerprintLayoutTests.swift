import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #6184: the 8-second session autosave only writes
/// when `TabManager.sessionAutosaveFingerprint()` changes, so that fingerprint
/// must react to split-layout mutations. The persisted snapshot records the
/// full pane/surface order, but the fingerprint historically hashed panel ids
/// in UUID-sorted order and ignored the layout — a pure reorder left it
/// unchanged, the autosave skipped the write, and a non-graceful exit
/// (OOM-suspend, Ghostty crash, force-quit, or a Sparkle update relaunch that
/// does not cleanly save) restored a *stale* pane order. Updates are the common
/// restart for a daily user, so the scramble surfaced "after an update".
@MainActor
@Suite(.serialized)
struct AutosaveFingerprintLayoutTests {
    @Test
    func fingerprintChangesWhenSurfacesReorderedWithinPane() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let firstPanelId = try #require(workspace.focusedPanelId)
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        // Sanity: both surfaces live in the same pane in [first, second] order.
        #expect(workspace.sidebarOrderedPanelIds() == [firstPanelId, secondPanelId])
        #expect(workspace.focusedPanelId == secondPanelId)

        let fingerprintBeforeReorder = manager.sessionAutosaveFingerprint()

        // Reorder the surfaces so the pane now holds [second, first]. The panel
        // *set* and the selected surface are unchanged — only the order differs,
        // which the old UUID-sorted hash could not see.
        #expect(workspace.reorderSurface(panelId: secondPanelId, toIndex: 0, focus: false))
        #expect(workspace.sidebarOrderedPanelIds() == [secondPanelId, firstPanelId])
        #expect(workspace.focusedPanelId == secondPanelId)

        let fingerprintAfterReorder = manager.sessionAutosaveFingerprint()

        #expect(fingerprintBeforeReorder != fingerprintAfterReorder)
    }
}
