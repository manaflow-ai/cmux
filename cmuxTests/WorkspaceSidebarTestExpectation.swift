import Foundation
import Testing

final class WorkspaceSidebarTestExpectation: @unchecked Sendable {
    let description: String
    private let condition = NSCondition()
    private var fulfillmentCount = 0
    private var expectedCount = 1
    private var shouldRejectOverFulfillment = false

    init(description: String) {
        self.description = description
    }

    var expectedFulfillmentCount: Int {
        get { condition.withLock { expectedCount } }
        set {
            condition.withLock {
                precondition(newValue > 0)
                expectedCount = newValue
            }
        }
    }

    var assertForOverFulfill: Bool {
        get { condition.withLock { shouldRejectOverFulfillment } }
        set { condition.withLock { shouldRejectOverFulfillment = newValue } }
    }

    var isFulfilled: Bool {
        condition.withLock { fulfillmentCount >= expectedCount }
    }

    func fulfill() {
        let overFulfilled = condition.withLock {
            fulfillmentCount += 1
            condition.broadcast()
            return shouldRejectOverFulfillment && fulfillmentCount > expectedCount
        }
        if overFulfilled {
            Issue.record("Over-fulfilled expectation: \(description)")
        }
    }
}
