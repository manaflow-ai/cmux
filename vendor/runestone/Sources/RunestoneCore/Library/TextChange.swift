import Foundation

struct TextChange {
    let byteRange: ByteRange
    let bytesAdded: ByteCount
    let oldEndLinePosition: LinePosition
    let startLinePosition: LinePosition
    let newEndLinePosition: LinePosition
}
