import Foundation

/// A core cmux-lite action produced by the shared shortcut table.
public enum CmuxShortcutAction: Sendable, Equatable {
    /// Split the locally active pane on an axis.
    case split(CmuxSplitDirection)

    /// Create a tab in the locally active pane.
    case newTab

    /// Close the active tab, collapsing its pane when it was last.
    case closeTab

    /// Create and locally follow a workspace.
    case newWorkspace

    /// Select a zero-based tab index in the locally active pane.
    case selectTab(Int)

    /// Select a zero-based screen index in the local workspace.
    case selectScreen(Int)

    /// Focus a pane using local geometry only.
    case focusPane(CmuxPaneDirection)

    /// Nudge the active pane's deepest matching split ratio.
    case resizePane(CmuxPaneDirection)
}
