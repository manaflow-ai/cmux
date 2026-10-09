public import Foundation
import os

/// Keeps the state in memory only (tests, previews).
public final class MemoryTerminalComposePersistence: TerminalComposePersisting {
    // carve-out: `TerminalComposePersisting` is synchronous; one load or store,
    // never held across a suspension.
    private let data: OSAllocatedUnfairLock<Data?>

    public init(data: Data? = nil) {
        self.data = OSAllocatedUnfairLock(initialState: data) // carve-out: as declared above
    }

    public func load() -> Data? { data.withLock { $0 } }
    public func save(_ data: Data) { self.data.withLock { $0 = data } }
    public func remove() { data.withLock { $0 = nil } }
    public var stored: Data? { load() }
}
