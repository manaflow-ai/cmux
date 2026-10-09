import Foundation

/// What a surface (a tab in a pane) shows. Unknown kinds from a newer Mac
/// keep their raw value and render as a generic surface.
public enum WorkspaceSurfaceKind: Hashable, Sendable {
    case terminal
    case browser
    case agent
    case other(String)

    public init(wire: String) {
        switch wire {
        case "terminal": self = .terminal
        case "browser": self = .browser
        case "agent": self = .agent
        default: self = .other(wire)
        }
    }
}
