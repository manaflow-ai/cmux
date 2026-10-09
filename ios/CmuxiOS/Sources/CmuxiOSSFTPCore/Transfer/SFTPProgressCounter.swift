import os

/// The last byte count a transfer reported, written from the SFTP client's
/// progress callback and read when the transfer pauses or ends.
final class SFTPProgressCounter: Sendable {
    // carve-out: the progress callback is synchronous and runs on the SFTP
    // client's thread; one load or store, never held across a suspension.
    private let bytes: OSAllocatedUnfairLock<Int64>

    init(_ bytes: Int64) {
        self.bytes = OSAllocatedUnfairLock(initialState: bytes) // carve-out: as declared above
    }

    var value: Int64 { bytes.withLock { $0 } }

    func set(_ value: Int64) { bytes.withLock { $0 = value } }
}
