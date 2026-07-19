import Foundation

struct CmuxScreen: Decodable, Sendable {
    let id: UInt64
    let name: String?
    let active: Bool
    let activePane: UInt64
    let zoomedPane: UInt64?
    let layout: CmuxLayout
    let panes: [CmuxPane]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case active
        case activePane = "active_pane"
        case zoomedPane = "zoomed_pane"
        case layout
        case panes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt64.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        active = try container.decode(Bool.self, forKey: .active)
        activePane = try container.decode(UInt64.self, forKey: .activePane)
        zoomedPane = try container.decodeIfPresent(UInt64.self, forKey: .zoomedPane)
        layout = try container.decodeIfPresent(CmuxLayout.self, forKey: .layout)
            ?? .leaf(pane: activePane)
        panes = try container.decodeIfPresent([CmuxPane].self, forKey: .panes) ?? []
    }
}
