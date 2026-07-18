import Foundation

/// A normalized key accepted by the platform-independent shortcut table.
public enum CmuxShortcutKey: Sendable, Equatable, Hashable {
    /// A case-normalized character key.
    case character(Character)

    /// A directional arrow key.
    case arrow(CmuxPaneDirection)
}
