import Foundation

struct CmuxCommandRequest: Encodable, Sendable {
    let id: UInt64
    let cmd: String
    var name: String?
    var kind: String?
    var workspace: UInt64?
    var pane: UInt64?
    var surface: UInt64?
    var index: Int?
    var direction: String?
    var ratio: Double?
    var mode: String?
    var text: String?
    var bytes: String?
    var cols: UInt16?
    var rows: UInt16?

    enum CodingKeys: String, CodingKey {
        case id
        case cmd
        case name
        case kind
        case workspace
        case pane
        case surface
        case index
        case direction = "dir"
        case ratio
        case mode
        case text
        case bytes
        case cols
        case rows
    }
}
