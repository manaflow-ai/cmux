import Foundation

/// The last byte count a transfer reported, written from the SFTP client's
/// progress callback and read when the transfer pauses or ends.
final class SFTPProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64

    init(_ bytes: Int64) { self.bytes = bytes }

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    func set(_ value: Int64) {
        lock.lock()
        bytes = value
        lock.unlock()
    }
}
