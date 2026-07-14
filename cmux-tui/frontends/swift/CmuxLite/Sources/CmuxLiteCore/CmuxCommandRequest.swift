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
    var mode: String?
    var text: String?
    var bytes: String?
    var cols: UInt16?
    var rows: UInt16?
}
