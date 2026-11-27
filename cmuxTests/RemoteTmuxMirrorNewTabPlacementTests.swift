import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for remote-tmux mirror new-tab placement: a new tab in a
/// mirror must honor cmux's tab-strip `BonsplitConfiguration.newTabPosition`
/// instead of tmux's bare `new-window`, which fills the lowest free window index
/// and lands the tab mid-list when the session has gaps from closed windows.
///
/// `RemoteTmuxController.newWindowCommand(afterWindowId:workingDirectory:focus:)` is the
/// pure command builder behind `handleMirrorNewTabRequested`:
/// - no target window (`.end`, or an unresolved `.current` selection) → append at
///   the end (`-a -t '{end}'`).
/// - a target window id (`.current` → the selected tab's window) → insert right
///   after it (`-a -t @id`).
@Suite struct RemoteTmuxMirrorNewTabPlacementTests {
    /// No target window (newTabPosition `.end`, or an unresolved `.current`
    /// selection) appends after the last window.
    @Test func appendsAtEndWhenNoTargetWindow() {
        #expect(
            RemoteTmuxController.newWindowCommand(afterWindowId: nil, workingDirectory: nil)
                == "new-window -d -a -t '{end}'"
        )
    }

    /// A target window (newTabPosition `.current` → the selected tab's window)
    /// inserts right after that window.
    @Test func insertsAfterSelectedWindow() {
        #expect(
            RemoteTmuxController.newWindowCommand(afterWindowId: 7, workingDirectory: nil)
                == "new-window -d -a -t @7"
        )
    }

    /// A background surface request must create the remote tmux window detached,
    /// otherwise tmux changes its active window before the mirror can reconcile.
    @Test func backgroundCreationKeepsTmuxSelectionDetached() {
        let command = RemoteTmuxController.newWindowCommand(
            afterWindowId: nil,
            workingDirectory: nil
        )

        #expect(command.split(separator: " ").contains("-d"))
    }

    @Test func focusedCreationReturnsStableWindowIdWithoutDetaching() {
        #expect(
            RemoteTmuxController.newWindowCommand(
                afterWindowId: 7,
                workingDirectory: nil,
                focus: true
            ) == "new-window -P -F '#{window_id}' -a -t @7"
        )
    }
}
