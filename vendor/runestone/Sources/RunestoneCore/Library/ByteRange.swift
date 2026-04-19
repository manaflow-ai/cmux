import Foundation

struct ByteRange: Hashable {
    let location: ByteCount
    let length: ByteCount
    var lowerBound: ByteCount {
        location
    }
    var upperBound: ByteCount {
        location + length
    }
    var isEmpty: Bool {
        length == 0
    }

    init(location: ByteCount, length: ByteCount) {
        self.location = location
        self.length = length
    }

    init(from startByte: ByteCount, to endByte: ByteCount) {
        self.location = startByte
        self.length = endByte - startByte
    }

    init(utf16Range: NSRange) {
        self.location = ByteCount(utf16Range.location * 2)
        self.length = ByteCount(utf16Range.length * 2)
    }

    func overlaps(_ otherRange: Self) -> Bool {
        let r1 = location ... location + length
        let r2 = otherRange.location ... otherRange.location + otherRange.length
        return r1.overlaps(r2)
    }
}

extension ByteRange: CustomStringConvertible {
    var description: String {
        "{\(location), \(length)}"
    }
}

extension ByteRange: CustomDebugStringConvertible {
    var debugDescription: String {
        "{\(location), \(length)}"
    }
}
