import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct WorktreeSidebarSchedulingTests {
    @Test("status queue is FIFO and deduplicated")
    func statusQueueIsFIFOAndDeduplicated() {
        var queue = WorktreeSidebarStatusQueue()
        let now = ContinuousClock().now
        let enqueuedA = queue.enqueue(path: "/a", eligibleAt: now)
        let duplicatedA = queue.enqueue(path: "/a", eligibleAt: now)
        let enqueuedB = queue.enqueue(path: "/b", eligibleAt: now)
        let firstPath = queue.popFirst()
        let removedB = queue.remove(path: "/b")

        #expect(enqueuedA)
        #expect(!duplicatedA)
        #expect(enqueuedB)
        #expect(firstPath == "/a")
        #expect(removedB)
        #expect(queue.isEmpty)
    }
}
