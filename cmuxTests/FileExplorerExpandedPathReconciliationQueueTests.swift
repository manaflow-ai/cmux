import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct FileExplorerExpandedPathReconciliationQueueTests {
    @Test func drainsTenThousandPathsParentFirst() {
        let paths = Set((0..<10_000).map { index in
            let components = (0...(index % 12)).map { "level-\($0)" }
            return "/\(components.joined(separator: "/"))/leaf-\(index)"
        })
        var queue = FileExplorerExpandedPathReconciliationQueue(paths: paths)
        var previousDepth = 0
        var drained: Set<String> = []

        while let path = queue.removeFirst() {
            let depth = path.split(separator: "/").count
            #expect(depth >= previousDepth)
            previousDepth = depth
            drained.insert(path)
        }

        #expect(drained == paths)
        #expect(queue.isEmpty)
    }
}
