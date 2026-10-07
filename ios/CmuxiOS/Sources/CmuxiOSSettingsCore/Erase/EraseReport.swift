/// What Erase All Data could not remove. Empty means everything went.
public struct EraseReport: Hashable, Sendable {
    public struct Failure: Hashable, Sendable {
        public var item: EraseItem
        /// A short, secret-free reason (an OSStatus or a POSIX error name).
        public var reason: String

        public init(item: EraseItem, reason: String) {
            self.item = item
            self.reason = reason
        }
    }

    public var failures: [Failure]

    public init(failures: [Failure] = []) {
        self.failures = failures
    }

    public var isComplete: Bool { failures.isEmpty }
}
