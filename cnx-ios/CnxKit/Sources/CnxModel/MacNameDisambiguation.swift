import Foundation

/// Tells apart Macs that share a name ("Aziz's MacBook Pro" twice). Only
/// Macs whose name collides with another in the same list get a tag; a
/// unique name reads as before.
///
/// The tag is the end of the Mac's device id ("3F2A"), the one stable
/// identifier every list has (the team's Macs, presence frames and
/// `GET /v1/me/devices`), so the same Mac carries the same tag in Settings,
/// the Workspaces filter and the remove confirmation. A tag is at least
/// four characters, and longer only when two colliding ids end alike.
public struct MacNameDisambiguation: Sendable, Equatable {
    /// Tag by device id, for Macs whose name collides.
    public let tags: [String: String]

    /// One entry per Mac: its device id and display name. Duplicate ids
    /// (the same Mac listed twice) count once.
    public init(_ macs: [(id: String, name: String)]) {
        var seen = Set<String>()
        let unique = macs.filter { seen.insert($0.id).inserted }
        let groups = Dictionary(grouping: unique, by: { Self.key($0.name) })
        var tags: [String: String] = [:]
        for group in groups.values where group.count > 1 {
            let ids = group.map(\.id)
            for (id, tag) in zip(ids, Self.suffixes(ids)) { tags[id] = tag }
        }
        self.tags = tags
    }

    public init(_ macs: [MacDevice]) {
        self.init(macs.map { (id: $0.id, name: $0.name) })
    }

    /// The Mac's tag ("3F2A") when its name collides; nil otherwise.
    public func tag(for id: String) -> String? { tags[id] }

    /// "Aziz's MacBook Pro (3F2A)" for a colliding name, else the name.
    public func displayName(id: String, name: String) -> String {
        guard let tag = tags[id] else { return name }
        return "\(name) (\(tag))"
    }

    public func displayName(_ mac: MacDevice) -> String { displayName(id: mac.id, name: mac.name) }

    /// "ID 3F2A" (and "Added Oct 13" when known) for a subtitle; nil for a
    /// unique name.
    public func detail(for id: String, addedAt: Date? = nil) -> String? {
        guard let tag = tags[id] else { return nil }
        guard let addedAt else { return "ID \(tag)" }
        return "Added \(addedAt.formatted(.dateTime.month(.abbreviated).day())) · ID \(tag)"
    }

    /// Names that differ only by case or surrounding spaces read the same.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The shortest id endings (at least four characters, alphanumerics
    /// only, uppercased) that differ across `ids`; an id too short for
    /// that is used whole.
    static func suffixes(_ ids: [String]) -> [String] {
        let cleaned = ids.map { id in
            let chars = id.uppercased().filter { $0.isLetter || $0.isNumber }
            return chars.isEmpty ? id.uppercased() : chars
        }
        let longest = cleaned.map(\.count).max() ?? 0
        var length = 4
        while length < longest {
            let tags = cleaned.map { String($0.suffix(length)) }
            if Set(tags).count == tags.count { return tags }
            length += 1
        }
        return cleaned.map { String($0.suffix(max(length, 4))) }
    }
}
