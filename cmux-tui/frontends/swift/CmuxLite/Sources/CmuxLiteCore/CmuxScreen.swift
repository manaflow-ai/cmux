import Foundation

struct CmuxScreen: Decodable, Sendable {
    let id: UInt64
    let name: String?
    let active: Bool
    let activePane: UInt64
    let panes: [CmuxPane]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case active
        case activePane = "active_pane"
        case panes
    }
}
