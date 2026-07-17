import Foundation

struct CmuxWorkspace: Decodable, Sendable {
    let id: UInt64
    let name: String
    let active: Bool
    let screens: [CmuxScreen]
}
