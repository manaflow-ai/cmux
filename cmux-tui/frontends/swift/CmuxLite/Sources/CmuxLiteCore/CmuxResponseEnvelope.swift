import Foundation

struct CmuxResponseEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let id: UInt64?
    let ok: Bool
    let data: Payload?
    let error: String?
}
