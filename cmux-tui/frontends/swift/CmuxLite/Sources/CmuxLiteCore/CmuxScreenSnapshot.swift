import Foundation

/// An immutable screen entry rendered by the cmux-lite status bar.
public struct CmuxScreenSnapshot: Sendable, Equatable {
    /// The server-owned screen identifier.
    public let id: UInt64

    /// The active pane whose tabs are rendered by the minimal frontend.
    public let pane: UInt64?

    /// The active tab index reported by the shared server tree.
    public let activeTab: Int?

    /// Tabs in the active pane, in server order.
    public let tabs: [CmuxTabSnapshot]

    /// Creates a screen snapshot.
    /// - Parameters:
    ///   - id: The server-owned screen identifier.
    ///   - pane: The active pane identifier, when the screen has one.
    ///   - activeTab: The shared active tab index, when valid.
    ///   - tabs: Tabs in the active pane.
    public init(id: UInt64, pane: UInt64?, activeTab: Int?, tabs: [CmuxTabSnapshot]) {
        self.id = id
        self.pane = pane
        self.activeTab = activeTab
        self.tabs = tabs
    }
}
