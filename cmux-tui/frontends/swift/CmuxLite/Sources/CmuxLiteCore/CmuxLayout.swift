import Foundation

/// The recursive pane layout returned by `list-workspaces`.
public indirect enum CmuxLayout: Decodable, Sendable, Equatable {
    /// A terminal pane leaf.
    case leaf(pane: UInt64)

    /// A pair of child layouts separated along an axis.
    case split(
        direction: CmuxSplitDirection,
        ratio: Double,
        first: CmuxLayout,
        second: CmuxLayout
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case direction = "dir"
        case ratio
        case first = "a"
        case second = "b"
    }

    private enum Kind: String, Decodable {
        case leaf
        case split
    }

    /// Decodes the protocol's discriminated recursive layout object.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .leaf:
            self = try .leaf(pane: container.decode(UInt64.self, forKey: .pane))
        case .split:
            self = try .split(
                direction: container.decode(CmuxSplitDirection.self, forKey: .direction),
                ratio: container.decode(Double.self, forKey: .ratio),
                first: container.decode(CmuxLayout.self, forKey: .first),
                second: container.decode(CmuxLayout.self, forKey: .second)
            )
        }
    }
}
