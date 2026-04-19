import Foundation

struct ByteCount: Hashable {
    private(set) var value: Int
    var utf16Length: Int {
        value / 2
    }

    init(_ value: Int) {
        self.value = value
    }

    init(_ value: UInt32) {
        self.value = Int(value)
    }

    init(utf16Length: Int) {
        self.value = utf16Length * 2
    }
}

extension ByteCount: Comparable {
    static func < (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.value < rhs.value
    }

    static func <= (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.value <= rhs.value
    }

    static func >= (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.value >= rhs.value
    }

    static func > (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.value > rhs.value
    }
}

extension ByteCount: Numeric {
    typealias Magnitude = Int
    typealias IntegerLiteralType = Int

    static var zero: ByteCount {
        ByteCount(0)
    }

    var magnitude: Int {
        value
    }

    init?<T>(exactly source: T) where T: BinaryInteger {
        self.value = Int(source)
    }

    init(integerLiteral value: Int) {
        self.value = value
    }

    static func - (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        ByteCount(lhs.value - rhs.value)
    }

    static func -= (lhs: inout ByteCount, rhs: ByteCount) {
        lhs.value -= rhs.value
    }

    static func + (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        ByteCount(lhs.value + rhs.value)
    }

    static func += (lhs: inout ByteCount, rhs: ByteCount) {
        lhs.value += rhs.value
    }

    static func * (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        ByteCount(lhs.value * rhs.value)
    }

    static func *= (lhs: inout ByteCount, rhs: ByteCount) {
        lhs.value *= rhs.value
    }
}

extension ByteCount: CustomStringConvertible {
    var description: String {
        "\(value)"
    }
}

extension ByteCount: CustomDebugStringConvertible {
    var debugDescription: String {
        "\(value)"
    }
}
