import Foundation

/// A pane as `workspace:<host>` carries it (common.schema.json `Pane`).
struct WirePane: Codable, Hashable, Sendable {
    var id: String
    var tabs: [WireTab]
}
