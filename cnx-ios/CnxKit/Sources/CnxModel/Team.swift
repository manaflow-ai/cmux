import Foundation

/// A Stack Auth team as the app shows it.
public struct Team: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var appearance: TeamAppearance
    public var macs: [MacDevice]

    public init(id: String, name: String, appearance: TeamAppearance? = nil, macs: [MacDevice] = []) {
        self.id = id
        self.name = name
        self.appearance = appearance ?? TeamAppearance(defaultFor: id)
        self.macs = macs
    }

    /// Up to `limit` dots for the sidebar row, online Macs first, then the overflow count.
    public func macDots(limit: Int = 5) -> (dots: [Bool], overflow: Int) {
        let ordered = macs.sorted { $0.isOnline && !$1.isOnline }
        let dots = ordered.prefix(limit).map(\.isOnline)
        return (Array(dots), max(0, macs.count - limit))
    }
}

/// A team's color, optionally overlaid by an emoji the user picked.
public struct TeamAppearance: Hashable, Sendable, Codable {
    public var colorHex: String
    public var emoji: String?

    public init(colorHex: String, emoji: String? = nil) {
        self.colorHex = colorHex
        self.emoji = emoji
    }

    /// A stable color from the palette, so a team keeps its color across launches and devices.
    public init(defaultFor teamID: String) {
        let palette = TeamAppearance.palette
        var hash: UInt64 = 1469598103934665603
        for byte in teamID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        self.init(colorHex: palette[Int(hash % UInt64(palette.count))])
    }

    /// Hues spaced for discernibility in dark and light mode.
    public static let palette: [String] = [
        "#FF6B5E", "#FF9F0A", "#FFD60A", "#32D74B", "#30D5C8",
        "#64D2FF", "#5E8BFF", "#BF5AF2", "#FF5AAA", "#AC8E68",
    ]
}

/// A Mac registered to a team.
public struct MacDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var isOnline: Bool
    public var lastSeenAt: Date?

    public init(id: String, name: String, isOnline: Bool, lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.isOnline = isOnline
        self.lastSeenAt = lastSeenAt
    }
}
