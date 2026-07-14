import Foundation

struct CmuxVTStateResponse: Decodable, Sendable {
    let cols: UInt16
    let rows: UInt16
    let data: String

    var replay: Data? {
        Data(base64Encoded: data)
    }
}
