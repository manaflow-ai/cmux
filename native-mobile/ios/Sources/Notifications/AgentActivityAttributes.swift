import ActivityKit
import Foundation

/// One agent's Live Activity (lock screen and Dynamic Island). Shared by the
/// app and the LiveActivity widget extension. The Worker starts it with
/// push-to-start (`attributes-type: AgentActivityAttributes`) and updates it
/// through the activity's push token; field names are the wire keys.
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum State: String, Codable, Hashable, Sendable {
            case working
            case needsInput = "needs_input"
            case done
        }

        var state: State
        /// Unix seconds when the agent started this run.
        var startedAt: Double
        var detail: String

        var startDate: Date { Date(timeIntervalSince1970: startedAt) }
    }

    var hostID: String
    var surface: Int
    var agent: String
    var workspace: String

    /// Opens the agent's terminal (`cmux-next://terminal?host=…&surface=…`).
    var deepLink: URL {
        var c = URLComponents()
        c.scheme = "cmux-next"
        c.host = "terminal"
        c.queryItems = [URLQueryItem(name: "host", value: hostID), URLQueryItem(name: "surface", value: String(surface))]
        return c.url!
    }
}
