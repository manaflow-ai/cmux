import Foundation

struct CmuxInboundHeader: Decodable, Sendable {
    let id: UInt64?
    let ok: Bool?
    let error: String?
    let event: String?
}
