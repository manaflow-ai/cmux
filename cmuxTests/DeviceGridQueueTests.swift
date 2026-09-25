import Foundation
import CmuxMobileHost
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Mac grid queue admission")
struct DeviceGridQueueTests {
    @Test("Distinct Mac grids respect event and byte budgets", arguments: [true, false])
    func distinctSurfacesCannotExceedBudget(countLimited: Bool) {
        let queue = MobileHostConnectionEventQueue(
            maximumEventCount: countLimited ? 2 : 10,
            maximumByteCount: countLimited ? 100 : 4
        )
        let topic = "device.terminal.grid"
        queue.updateSubscribedTopics([topic])
        for surface in ["a", "b"] {
            #expect(queue.enqueue(topic: topic, coalesceKey: surface,
                isFullRenderGridFrame: false, frame: Data([1, 2])).admitted)
        }
        let rejected = queue.enqueue(topic: topic, coalesceKey: "c",
            isFullRenderGridFrame: false, frame: Data([3, 4]))
        #expect(!rejected.admitted)
        #expect(queue.count == 2)
        #expect(queue.byteCount == 4)
        #expect(queue.dequeue()?.coalesceKey == "a")
        #expect(queue.dequeue()?.coalesceKey == "b")
    }

    @Test("Replacing a grid keeps chronological order and current byte accounting")
    func coalescingAndDrainKeepIdentity() {
        let queue = MobileHostConnectionEventQueue(maximumEventCount: 3, maximumByteCount: 10)
        let topic = "device.terminal.grid"
        queue.updateSubscribedTopics([topic, "terminal.bytes"])
        _ = queue.enqueue(topic: topic, coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([1]))
        _ = queue.enqueue(topic: "terminal.bytes", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([2]))
        for _ in 0..<100 {
            #expect(queue.enqueue(topic: topic, coalesceKey: "a", isFullRenderGridFrame: false,
                frame: Data([3, 4])).admitted)
        }
        #expect(queue.count == 2 && queue.byteCount == 3)
        #expect(queue.dequeue()?.frame == Data([3, 4]))
        #expect(queue.dequeue()?.frame == Data([2]))
        #expect(queue.byteCount == 0)
        #expect(queue.enqueue(topic: topic, coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([5])).admitted)
        #expect(queue.dequeue()?.frame == Data([5]))
        queue.close()
        #expect(queue.count == 0 && queue.byteCount == 0)
        #expect(!queue.enqueue(topic: topic, coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([6])).admitted)
    }
}
