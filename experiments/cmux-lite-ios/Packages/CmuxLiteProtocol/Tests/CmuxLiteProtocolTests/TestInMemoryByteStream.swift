internal import Foundation
import CmuxLiteProtocol

actor TestInMemoryByteStream: ByteStream {
    enum Failure: Error, Equatable {
        case closed
        case notConnected
        case receiveAlreadyPending
    }

    private enum State {
        case idle
        case connected
        case closed
    }

    private var state: State = .idle
    private var peer: TestInMemoryByteStream?
    private var inbound: [Data] = []
    private var peerEnded = false
    private var pendingReceive: CheckedContinuation<Data?, any Error>?
    private var pendingReceiveObserver: CheckedContinuation<Void, Never>?

    static func makePair() async -> (
        TestInMemoryByteStream,
        TestInMemoryByteStream
    ) {
        let first = TestInMemoryByteStream()
        let second = TestInMemoryByteStream()
        await first.setPeer(second)
        await second.setPeer(first)
        return (first, second)
    }

    func connect() async throws {
        switch state {
        case .idle:
            state = .connected
        case .connected:
            return
        case .closed:
            throw Failure.closed
        }
    }

    func send(_ bytes: Data) async throws {
        guard case .connected = state else {
            throw state == .closed ? Failure.closed : Failure.notConnected
        }
        guard !peerEnded else {
            throw Failure.closed
        }
        guard !bytes.isEmpty else {
            return
        }
        guard let peer else {
            throw Failure.notConnected
        }
        await peer.deliver(bytes)
    }

    func receive() async throws -> Data? {
        guard case .connected = state else {
            if case .closed = state {
                return nil
            }
            throw Failure.notConnected
        }
        if !inbound.isEmpty {
            return inbound.removeFirst()
        }
        if peerEnded {
            return nil
        }
        guard pendingReceive == nil else {
            throw Failure.receiveAlreadyPending
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingReceive = continuation
                pendingReceiveObserver?.resume()
                pendingReceiveObserver = nil
            }
        } onCancel: {
            Task {
                await self.cancelPendingReceive()
            }
        }
    }

    func close() async {
        guard state != .closed else {
            return
        }
        state = .closed
        pendingReceive?.resume(returning: nil)
        pendingReceive = nil
        pendingReceiveObserver?.resume()
        pendingReceiveObserver = nil
        let peer = self.peer
        self.peer = nil
        await peer?.peerDidClose()
    }

    func waitUntilReceiveIsPending() async {
        if pendingReceive != nil || state == .closed {
            return
        }
        await withCheckedContinuation { continuation in
            pendingReceiveObserver = continuation
        }
    }

    private func setPeer(_ peer: TestInMemoryByteStream) {
        self.peer = peer
    }

    private func deliver(_ bytes: Data) {
        guard state != .closed else {
            return
        }
        if let pendingReceive {
            self.pendingReceive = nil
            pendingReceive.resume(returning: bytes)
        } else {
            inbound.append(bytes)
        }
    }

    private func peerDidClose() {
        peerEnded = true
        pendingReceive?.resume(returning: nil)
        pendingReceive = nil
    }

    private func cancelPendingReceive() {
        pendingReceive?.resume(throwing: CancellationError())
        pendingReceive = nil
    }
}
