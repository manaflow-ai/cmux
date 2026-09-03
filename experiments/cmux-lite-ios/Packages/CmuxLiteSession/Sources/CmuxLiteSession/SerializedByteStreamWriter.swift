internal import Foundation
internal import CmuxLiteProtocol

/// Serializes writes without using a lock or a blocking queue.
actor SerializedByteStreamWriter {
    private let stream: any ByteStream
    private var tail: Task<Void, any Error>?

    init(stream: any ByteStream) {
        self.stream = stream
    }

    func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else {
            return
        }

        let predecessor = tail
        let stream = stream
        let operation = Task<Void, any Error> {
            try await predecessor?.value
            try await stream.send(bytes)
        }
        tail = operation
        try await operation.value
    }

    func cancel() {
        tail?.cancel()
        tail = nil
    }
}
