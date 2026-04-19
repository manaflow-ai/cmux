import Foundation

extension NSRange {
    /// Creates an NSRange from a `ByteRange`.
    /// - Parameter byteRange: `ByteRange` to convert to NSRange.
    init(_ byteRange: ByteRange) {
        let location = byteRange.location.value / 2
        let length = byteRange.length.value / 2
        self.init(location: location, length: length)
    }

    /// Checks if range overlaps another range.
    /// - Parameter range: Range to check against.
    /// - Returns: True if the ranges overlap otherwise false.
    func overlaps(_ range: NSRange) -> Bool {
        let r1 = location ..< location + length
        let r2 = range.location ..< range.location + range.length
        return r1.overlaps(r2)
    }

    /// Returns a range that is guaranteed not to have a negative length. As an example the range (20, -4) will be converted to (16, 4) and the range (20, -25) will be converted to (0, 20).
    var nonNegativeLength: NSRange {
        if length < 0 {
            let absoluteLength = abs(length)
            let safeAbsoluteLength = min(absoluteLength, location)
            return NSRange(location: location - safeAbsoluteLength, length: safeAbsoluteLength)
        } else {
            return self
        }
    }

    /// Ensures the range fits within the specified range.
    /// - Parameter cappingRange: The target range.
    /// - Returns: A range that fits within the target range.
    func capped(to cappingRange: NSRange) -> NSRange {
        let newLowerBound = min(max(lowerBound, cappingRange.lowerBound), cappingRange.upperBound)
        let tmpNewUpperBound = newLowerBound + length - (newLowerBound - lowerBound)
        let newUpperBound = min(max(tmpNewUpperBound, cappingRange.lowerBound), cappingRange.upperBound)
        let newLength = min(newUpperBound - newLowerBound, cappingRange.length)
        return NSRange(location: newLowerBound, length: newLength)
    }

    /// Crates a range that is local to the specified range.
    /// - Parameter parentRange: The parent range.
    /// - Returns: A range that is local to the parent range.
    func local(to parentRange: NSRange) -> NSRange {
        let localLowerBound = lowerBound - parentRange.lowerBound
        let localUpperBound = upperBound - parentRange.lowerBound
        let length = localUpperBound - localLowerBound
        return NSRange(location: localLowerBound, length: length)
    }
}
