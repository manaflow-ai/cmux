internal import Foundation
import Testing

@Suite("Byte-stream contract")
struct ByteStreamTests {
    @Test("paired streams preserve ordered non-empty chunks")
    func orderedChunks() async throws {
        let (sender, receiver) = await TestInMemoryByteStream.makePair()
        try await sender.connect()
        try await receiver.connect()

        try await sender.send(Data())
        try await sender.send(Data("first".utf8))
        try await sender.send(Data("second".utf8))

        #expect(try await receiver.receive() == Data("first".utf8))
        #expect(try await receiver.receive() == Data("second".utf8))
    }

    @Test("close is idempotent and unblocks a pending receive with EOF")
    func closeUnblocksReceive() async throws {
        let (sender, receiver) = await TestInMemoryByteStream.makePair()
        try await sender.connect()
        try await receiver.connect()

        let receive = Task {
            try await receiver.receive()
        }
        await receiver.waitUntilReceiveIsPending()
        await receiver.close()
        await receiver.close()

        #expect(try await receive.value == nil)
    }

    @Test("peer close delivers EOF after already-buffered bytes")
    func peerCloseDrainsBufferedBytes() async throws {
        let (sender, receiver) = await TestInMemoryByteStream.makePair()
        try await sender.connect()
        try await receiver.connect()
        try await sender.send(Data("final".utf8))
        await sender.close()

        #expect(try await receiver.receive() == Data("final".utf8))
        #expect(try await receiver.receive() == nil)
    }

    @Test("send fails after the peer has closed")
    func sendAfterPeerClose() async throws {
        let (sender, receiver) = await TestInMemoryByteStream.makePair()
        try await sender.connect()
        try await receiver.connect()
        await receiver.close()

        await #expect(throws: TestInMemoryByteStream.Failure.closed) {
            try await sender.send(Data("late".utf8))
        }
    }

    @Test("task cancellation unblocks a pending receive exactly once")
    func receiveCancellation() async throws {
        let (sender, receiver) = await TestInMemoryByteStream.makePair()
        try await sender.connect()
        try await receiver.connect()

        let receive = Task {
            try await receiver.receive()
        }
        await receiver.waitUntilReceiveIsPending()
        receive.cancel()

        await #expect(throws: CancellationError.self) {
            try await receive.value
        }
        await sender.close()
        await receiver.close()
    }

    @Test("a second concurrent receive is rejected without disturbing the first")
    func concurrentReceive() async throws {
        let (sender, receiver) = await TestInMemoryByteStream.makePair()
        try await sender.connect()
        try await receiver.connect()

        let firstReceive = Task {
            try await receiver.receive()
        }
        await receiver.waitUntilReceiveIsPending()

        await #expect(throws: TestInMemoryByteStream.Failure.receiveAlreadyPending) {
            try await receiver.receive()
        }

        try await sender.send(Data("value".utf8))
        #expect(try await firstReceive.value == Data("value".utf8))
    }
}
