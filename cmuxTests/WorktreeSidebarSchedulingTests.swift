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
        #expect(queue.enqueue(path: "/a", eligibleAt: now))
        #expect(!queue.enqueue(path: "/a", eligibleAt: now))
        #expect(queue.enqueue(path: "/b", eligibleAt: now))
        #expect(queue.popFirst() == "/a")
        #expect(queue.remove(path: "/b"))
        #expect(queue.isEmpty)
    }
}
