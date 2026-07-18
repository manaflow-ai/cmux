import Foundation

struct CmuxPane: Decodable, Sendable {
    let id: UInt64
    let activeTab: Int
    let tabs: [CmuxSurface]
    let dead: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case activeTab = "active_tab"
        case tabs
        case dead
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt64.self, forKey: .id)
        activeTab = try container.decodeIfPresent(Int.self, forKey: .activeTab) ?? 0
        tabs = try container.decodeIfPresent([CmuxSurface].self, forKey: .tabs) ?? []
        dead = try container.decodeIfPresent(Bool.self, forKey: .dead) ?? false
    }
}
