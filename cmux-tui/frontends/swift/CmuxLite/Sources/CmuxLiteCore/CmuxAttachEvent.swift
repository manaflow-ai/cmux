import Foundation

/// Represents one ordered protocol-v7 render attachment or subscribed control event.
public enum CmuxAttachEvent: Decodable, Sendable, Equatable {
    /// A complete initial server-rendered viewport.
    case renderState(CmuxRenderStateEvent)

    /// A dirty-row or full replacement render frame.
    case renderDelta(CmuxRenderDeltaEvent)

    /// The terminal event that closes one surface attachment.
    case detached(surface: UInt64)

    /// A subscribed control event not interpreted by the terminal renderer.
    case other(name: String)

    /// The surface associated with this event, when present.
    public var surface: UInt64? {
        switch self {
        case let .renderState(state): state.surface
        case let .renderDelta(delta): delta.surface
        case let .detached(surface): surface
        case .other: nil
        }
    }

    /// Decodes the protocol's event discriminator and render payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .event)
        switch name {
        case "render-state":
            self = .renderState(try CmuxRenderStateEvent(from: decoder))
        case "render-delta":
            self = .renderDelta(try CmuxRenderDeltaEvent(from: decoder))
        case "detached":
            self = .detached(surface: try container.decode(UInt64.self, forKey: .surface))
        default:
            self = .other(name: name)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case event
        case surface
    }
}
