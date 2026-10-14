import Foundation

// PROTOCOL §4 "layout" (capability `layout.v1`): the Mac's workspaces and
// their panes, each pane placed by a normalized rect within its workspace.
// Mirrors host/src/protocol.ts (`Layout`, `LayoutWorkspace`, `LayoutPane`,
// `LayoutTab`). `layout.get {}` -> `{layout}`; event `layout.changed {layout}`;
// `layout.focusTab {paneId, tabId}` -> `{}`.

public struct MacLayout: Codable, Sendable, Hashable {
    public var workspaces: [LayoutWorkspace]
    public init(workspaces: [LayoutWorkspace]) { self.workspaces = workspaces }
}

/// A rect in 0...1 units of its workspace.
public struct LayoutRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct LayoutWorkspace: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var color: String?
    public var active: Bool
    public var activePaneId: String?
    public var panes: [LayoutPane]
    public init(id: String, title: String, color: String? = nil, active: Bool = false, activePaneId: String? = nil, panes: [LayoutPane]) {
        self.id = id; self.title = title; self.color = color; self.active = active; self.activePaneId = activePaneId; self.panes = panes
    }
}

public struct LayoutPane: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var rect: LayoutRect
    public var tabs: [LayoutTab]
    public var focusedTabId: String?
    public var active: Bool
    public init(id: String, rect: LayoutRect, tabs: [LayoutTab], focusedTabId: String?, active: Bool = false) {
        self.id = id; self.rect = rect; self.tabs = tabs; self.focusedTabId = focusedTabId; self.active = active
    }

    public var focusedTab: LayoutTab? { tabs.first { $0.id == focusedTabId } ?? tabs.first { $0.focused } ?? tabs.first }
}

public enum LayoutTabKind: String, OpenStringEnum {
    case terminal, browser, agent, conversation, other
    public static var unknownFallback: Self { .other }
}

public struct LayoutTab: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: LayoutTabKind
    public var title: String
    /// `Terminal.id` (terminal), `BrowserTab.id` (browser), agent session id (agent).
    public var refId: String?
    /// False when the phone cannot open a live view of this tab (placeholder).
    public var streamable: Bool
    public var url: String?
    public var focused: Bool
    /// Browser tabs: the Mac shows this tab right now. A hidden tab sends no
    /// frames until it is shown (`layout.focusTab`). Nil: not reported.
    public var visibleOnMac: Bool?
    /// Why the tab is not streamable, for the placeholder.
    public var reason: String?
    public init(id: String, kind: LayoutTabKind, title: String, refId: String?, streamable: Bool = true, url: String? = nil,
                focused: Bool = false, visibleOnMac: Bool? = nil, reason: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.refId = refId; self.streamable = streamable; self.url = url
        self.focused = focused; self.visibleOnMac = visibleOnMac; self.reason = reason
    }
}

/// `layout.get` result and `layout.changed` event payload.
public struct LayoutResult: Codable, Sendable, Hashable {
    public var layout: MacLayout
    public init(layout: MacLayout) { self.layout = layout }
}

/// `layout.focusTab {paneId, tabId}` -> `{}`.
public struct LayoutFocusParams: Codable, Sendable, Hashable {
    public var paneId: String
    public var tabId: String
    public init(paneId: String, tabId: String) { self.paneId = paneId; self.tabId = tabId }
}
