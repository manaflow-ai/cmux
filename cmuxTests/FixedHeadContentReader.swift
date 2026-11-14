import CmuxGit
import Foundation

/// A `GitHeadContentReading` fake with settable HEAD bytes and watched paths.
///
/// Every HEAD read is also yielded on ``headReads``, so a test can wait for a
/// tracker to finish a step that ends in a read instead of sleeping.
actor FixedHeadContentReader: GitHeadContentReading {
    nonisolated let headReads: AsyncStream<Void>
    private let headReadContinuation: AsyncStream<Void>.Continuation
    private var bytes: Data?
    private var paths: [String]?

    init(content: String?, watchedPaths: [String]? = nil) {
        self.init(bytes: content.map { Data($0.utf8) }, watchedPaths: watchedPaths)
    }

    init(bytes: Data?, watchedPaths: [String]? = nil) {
        self.bytes = bytes
        paths = watchedPaths
        (headReads, headReadContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func setContent(_ content: String?) {
        bytes = content.map { Data($0.utf8) }
    }

    func setWatchedPaths(_ watchedPaths: [String]?) {
        paths = watchedPaths
    }

    func headContent(forFile absolutePath: String) async -> Data? {
        headReadContinuation.yield(())
        return bytes
    }

    func watchedPaths(forFile absolutePath: String) async -> [String]? {
        paths
    }
}
