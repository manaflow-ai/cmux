import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("DirectoryDropFilter")
struct DirectoryDropFilterTests {
    private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    @Test func keepsOnlyDirectories() {
        let urls = [url("/a"), url("/b/file.txt"), url("/c")]
        let dirs: Set<String> = ["/a", "/c"]
        let result = DirectoryDropFilter.directories(among: urls) { dirs.contains($0.path) }
        #expect(result.map(\.path) == ["/a", "/c"])
    }

    @Test func emptyWhenNoDirectories() {
        let urls = [url("/x/file.txt"), url("/y/img.png")]
        let result = DirectoryDropFilter.directories(among: urls) { _ in false }
        #expect(result.isEmpty)
    }

    @Test func dedupesByPathPreservingOrder() {
        let urls = [url("/a"), url("/a"), url("/b")]
        let result = DirectoryDropFilter.directories(among: urls) { _ in true }
        #expect(result.map(\.path) == ["/a", "/b"])
    }
}
