import Foundation

/// Collects the control commands emitted by a test's physical key delivery.
@MainActor
struct RemoteTmuxInputCommandCapture {
    enum CaptureError: Error, Equatable {
        case timedOut(expected: Int, received: Int)
        case endOfFile(expected: Int, received: Int)
    }

    func capture(
        from handle: FileHandle,
        expectedCount: Int,
        timeout: Duration = .seconds(5),
        clock: some Clock<Duration> = ContinuousClock(),
        sendInput: () throws -> Void
    ) async throws -> [String] {
        try sendInput()
        var lineData = Data()
        var commands: [String] = []
        for try await byte in handle.bytes {
            guard byte == UInt8(ascii: "\n") else {
                lineData.append(byte)
                continue
            }
            let line = String(decoding: lineData, as: UTF8.self)
            lineData.removeAll(keepingCapacity: true)
            guard line.hasPrefix("send-keys -t %4 ") else { continue }
            commands.append(line)
            if commands.count == expectedCount { break }
        }
        return commands
    }
}
