import Foundation

struct CmuxIdentifyResponse: Decodable, Sendable {
    let app: String
    let version: String
    let `protocol`: UInt32
    let session: String
    let pid: UInt32
}
