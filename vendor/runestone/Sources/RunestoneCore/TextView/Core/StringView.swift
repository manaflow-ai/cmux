import Foundation

final class StringViewBytesResult {
    // The bytes are not deallocated by this type.
    let bytes: UnsafePointer<Int8>
    let length: ByteCount

    init(bytes: UnsafePointer<Int8>, length: ByteCount) {
        self.bytes = bytes
        self.length = length
    }
}

final class StringView {
    var string: NSString {
        get {
            internalString
        }
        set {
            internalString = NSMutableString(string: newValue)
        }
    }
    private var internalString: NSMutableString {
        didSet {
            if internalString != oldValue {
                invalidate()
            }
        }
    }
    private var swiftString: String {
        if let swiftString = _swiftString {
            return swiftString
        } else {
            let swiftString = internalString as String
            _swiftString = swiftString
            return swiftString
        }
    }

    private var _swiftString: String?

    init(string: NSMutableString = NSMutableString()) {
        self.internalString = string
    }

    convenience init(string: String) {
        self.init(string: NSMutableString(string: string))
    }

    func substring(in range: NSRange) -> String? {
        if range.location >= 0 && range.upperBound <= internalString.length && range.length > 0 {
            return internalString.substring(with: range)
        } else {
            return nil
        }
    }

    func character(at location: Int) -> Character? {
        if location >= 0 && location < string.length, let scalar = Unicode.Scalar(internalString.character(at: location)) {
            return Character(scalar)
        } else {
            return nil
        }
    }

    func replaceText(in range: NSRange, with string: String) {
        internalString.replaceCharacters(in: range, with: string)
        invalidate()
    }

    func bytes(in range: ByteRange) -> StringViewBytesResult? {
        guard range.lowerBound.value >= 0 && range.upperBound <= string.byteCount else {
            return nil
        }
        let stringRange = NSRange(range)
        var usedLength = 0
        if let buffer = string.getBytes(in: stringRange, encoding: String.preferredUTF16Encoding, usedLength: &usedLength) {
            return StringViewBytesResult(bytes: buffer, length: ByteCount(usedLength))
        } else {
            return nil
        }
    }
}

private extension StringView {
    private func invalidate() {
        _swiftString = nil
    }
}
