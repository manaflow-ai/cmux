import Foundation

/// `task.schema.json` `TaskStreamState`: the `task:<host>` snapshot.
struct WireTaskStreamState: Hashable, Sendable, Decodable {
    var agents: [WireAgent]
    var tasks: [WireTask]
}
