import Foundation

/// `workspace.tab.upsert` params: the tab at `index` of `pane`.
struct TabUpsertParams: Codable, Sendable {
    var workspace: String
    var pane: String
    var index: Int
    var tab: WireTab
}
