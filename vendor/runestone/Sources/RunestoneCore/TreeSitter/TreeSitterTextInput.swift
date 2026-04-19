import TreeSitter

struct TreeSitterTextProviderResult {
    let bytes: UnsafePointer<Int8>
    let length: UInt32
}

typealias TreeSitterReadCallback = (_ byteIndex: ByteCount, _ position: TreeSitterTextPoint) -> TreeSitterTextProviderResult?

/// The implementation is inspired by SwiftTreeSitter.
/// https://github.com/ChimeHQ/SwiftTreeSitter/blob/main/Sources/SwiftTreeSitter/Input.swift
final class TreeSitterTextInput {
    fileprivate let encoding: TSInputEncoding
    fileprivate let callback: TreeSitterReadCallback
    fileprivate var bytePointers: [UnsafePointer<Int8>] = []

    init(encoding: TSInputEncoding, callback: @escaping TreeSitterReadCallback) {
        self.encoding = encoding
        self.callback = callback
    }

    func makeTSInput() -> TSInput {
        let payload = Unmanaged.passUnretained(self).toOpaque()
        return TSInput(payload: payload, read: read, encoding: encoding)
    }

    func deallocate() {
        for bytePointer in bytePointers {
            bytePointer.deallocate()
        }
        bytePointers = []
    }
}

private func read(payload: UnsafeMutableRawPointer?,
                  byteIndex: UInt32,
                  position: TSPoint,
                  bytesRead: UnsafeMutablePointer<UInt32>?) -> UnsafePointer<Int8>? {
    let input: TreeSitterTextInput = Unmanaged.fromOpaque(payload!).takeUnretainedValue()
    if let result = input.callback(ByteCount(byteIndex), TreeSitterTextPoint(position)) {
        bytesRead?.pointee = result.length
        input.bytePointers.append(result.bytes)
        return result.bytes
    } else {
        bytesRead?.pointee = 0
        return nil
    }
}
