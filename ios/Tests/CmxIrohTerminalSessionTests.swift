import Foundation
import XCTest
@testable import cmux_ios

final class CmxIrohIncomingMessageBufferTests: XCTestCase {
    func testIncomingMessageBufferSchedulesOnlyOneDrainForQueuedMessages() {
        let buffer = CmxIrohIncomingMessageBuffer(maxQueuedMessages: 10, maxQueuedBytes: 100)

        XCTAssertEqual(
            buffer.enqueue(Data("one".utf8)),
            CmxIrohIncomingMessageBuffer.EnqueueResult(
                shouldScheduleDrain: true,
                didOverflow: false,
                queuedMessages: 1,
                queuedBytes: 3
            )
        )
        XCTAssertEqual(
            buffer.enqueue(Data("two".utf8)),
            CmxIrohIncomingMessageBuffer.EnqueueResult(
                shouldScheduleDrain: false,
                didOverflow: false,
                queuedMessages: 2,
                queuedBytes: 6
            )
        )
    }

    func testIncomingMessageBufferDrainsByMessageAndByteBudgets() {
        let buffer = CmxIrohIncomingMessageBuffer(maxQueuedMessages: 10, maxQueuedBytes: 100)
        _ = buffer.enqueue(Data("1111".utf8))
        _ = buffer.enqueue(Data("2222".utf8))
        _ = buffer.enqueue(Data("3333".utf8))

        let firstBatch = buffer.dequeueBatch(maxMessages: 10, maxBytes: 8)
        XCTAssertEqual(firstBatch.messages, [Data("1111".utf8), Data("2222".utf8)])
        XCTAssertTrue(firstBatch.hasMore)
        XCTAssertEqual(firstBatch.queuedMessages, 1)
        XCTAssertEqual(firstBatch.queuedBytes, 4)

        let secondBatch = buffer.dequeueBatch(maxMessages: 10, maxBytes: 8)
        XCTAssertEqual(secondBatch.messages, [Data("3333".utf8)])
        XCTAssertFalse(secondBatch.hasMore)
        XCTAssertEqual(secondBatch.queuedMessages, 0)
        XCTAssertEqual(secondBatch.queuedBytes, 0)
    }

    func testIncomingMessageBufferOverflowsByMessageCountAndClearsQueue() {
        let buffer = CmxIrohIncomingMessageBuffer(maxQueuedMessages: 2, maxQueuedBytes: 100)
        _ = buffer.enqueue(Data("one".utf8))
        _ = buffer.enqueue(Data("two".utf8))

        XCTAssertEqual(
            buffer.enqueue(Data("three".utf8)),
            CmxIrohIncomingMessageBuffer.EnqueueResult(
                shouldScheduleDrain: false,
                didOverflow: true,
                queuedMessages: 0,
                queuedBytes: 0
            )
        )
        XCTAssertEqual(buffer.dequeueBatch(maxMessages: 10, maxBytes: 100).messages, [])
    }

    func testIncomingMessageBufferOverflowsByByteCountAndClearsQueue() {
        let buffer = CmxIrohIncomingMessageBuffer(maxQueuedMessages: 10, maxQueuedBytes: 8)
        _ = buffer.enqueue(Data("1111".utf8))
        _ = buffer.enqueue(Data("2222".utf8))

        XCTAssertEqual(
            buffer.enqueue(Data("3".utf8)),
            CmxIrohIncomingMessageBuffer.EnqueueResult(
                shouldScheduleDrain: false,
                didOverflow: true,
                queuedMessages: 0,
                queuedBytes: 0
            )
        )
        XCTAssertEqual(buffer.dequeueBatch(maxMessages: 10, maxBytes: 100).messages, [])
    }
}
