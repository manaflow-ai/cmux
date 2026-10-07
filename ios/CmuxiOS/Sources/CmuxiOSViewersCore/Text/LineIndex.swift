/// Line starts of a text in UTF-16 offsets (what TextKit and NSString
/// count), for line numbers and jump-to-line.
public struct LineIndex: Hashable, Sendable {
    /// Offset of the first character of each line; always starts with 0.
    public let starts: [Int]
    public let length: Int

    public init(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        // A trailing newline does not open a visible line.
        if starts.count > 1, starts.last == offset { starts.removeLast() }
        self.starts = starts
        length = offset
    }

    public var lineCount: Int { starts.count }

    /// The 0-based line containing a UTF-16 offset.
    public func line(containing offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
