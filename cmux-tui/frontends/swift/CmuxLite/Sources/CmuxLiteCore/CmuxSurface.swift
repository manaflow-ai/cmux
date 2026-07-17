import Foundation

struct CmuxSurface: Decodable, Sendable {
    let surface: UInt64
    let kind: String
    let name: String?
    let title: String
    let size: CmuxSurfaceSize?
    let dead: Bool
}
