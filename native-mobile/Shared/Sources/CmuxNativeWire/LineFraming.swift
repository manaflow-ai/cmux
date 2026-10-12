import Foundation

/// Splits newline-JSON lines into link messages of at most 16 KiB.
///
/// A line that fits (with its newline) travels as one message: the line plus
/// `\n`. A longer line travels as `n` envelopes, each one message:
///
///     {"frag":k,"of":n,"d":"<base64 of bytes k>"}\n      k = 0 ..< n
///
/// `d` is base64 so a fragment boundary may fall inside a UTF-8 sequence.
/// Daemon and svc lines are JSON objects starting with `{"id"` or
/// `{"event"`, so the `{"frag":` prefix is unambiguous.
public struct LineFramer: Sendable {
    public static let defaultMaximumMessageBytes = 16 * 1024
    static let fragmentPrefix = Data(#"{"frag":"#.utf8)
    static let newline = UInt8(ascii: "\n")

    public let maximumMessageBytes: Int

    public init(maximumMessageBytes: Int = LineFramer.defaultMaximumMessageBytes) {
        precondition(maximumMessageBytes >= 256, "message limit too small for a fragment envelope")
        self.maximumMessageBytes = maximumMessageBytes
    }

    /// Raw bytes carried per fragment so the envelope stays under the limit.
    var fragmentPayloadBytes: Int {
        // Envelope overhead: {"frag":K,"of":N,"d":""}\n with K, N up to 10 digits each.
        let overhead = 48
        return ((maximumMessageBytes - overhead) / 4) * 3
    }

    /// Encodes one line (a trailing `\n` is optional and ignored) into one or
    /// more newline-terminated messages.
    public func encode(line input: Data) -> [Data] {
        var line = input
        if line.last == Self.newline { line.removeLast() }
        if line.count + 1 <= maximumMessageBytes {
            var message = line
            message.append(Self.newline)
            return [message]
        }
        let chunk = fragmentPayloadBytes
        let count = (line.count + chunk - 1) / chunk
        var messages: [Data] = []
        messages.reserveCapacity(count)
        var index = 0
        var start = line.startIndex
        while start < line.endIndex {
            let end = line.index(start, offsetBy: chunk, limitedBy: line.endIndex) ?? line.endIndex
            let payload = line[start..<end].base64EncodedString()
            var message = Data(#"{"frag":\#(index),"of":\#(count),"d":""#.utf8)
            message.append(Data(payload.utf8))
            message.append(Data("\"}\n".utf8))
            messages.append(message)
            index += 1
            start = end
        }
        return messages
    }
}

/// Reassembles link messages produced by `LineFramer` into complete lines.
public struct LineReassembler: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case badFragment
        case outOfOrder(expected: Int, got: Int)
        case lineTooLarge
    }

    public let maximumLineBytes: Int
    private var pending = Data()
    private var expectedCount = 0
    private var nextIndex = 0

    public init(maximumLineBytes: Int = 64 << 20) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// True while a fragmented line is incomplete.
    public var isMidLine: Bool { expectedCount > 0 }

    private struct Envelope: Decodable {
        var frag: Int
        var of: Int
        var d: String
    }

    /// Accepts one link message and returns the complete lines it finishes,
    /// without trailing newlines. A plain message may carry several lines.
    public mutating func accept(_ message: Data) throws -> [Data] {
        if message.starts(with: LineFramer.fragmentPrefix) {
            return try acceptFragment(message).map { [$0] } ?? []
        }
        if isMidLine { throw Failure.badFragment }
        var lines: [Data] = []
        var start = message.startIndex
        while start < message.endIndex {
            let end = message[start...].firstIndex(of: LineFramer.newline) ?? message.endIndex
            if end > start {
                guard end - start <= maximumLineBytes else { throw Failure.lineTooLarge }
                lines.append(Data(message[start..<end]))
            }
            start = end < message.endIndex ? message.index(after: end) : end
        }
        return lines
    }

    private mutating func acceptFragment(_ message: Data) throws -> Data? {
        var body = message
        if body.last == LineFramer.newline { body.removeLast() }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
            envelope.of > 0, envelope.frag >= 0, envelope.frag < envelope.of,
            let bytes = Data(base64Encoded: envelope.d)
        else { throw Failure.badFragment }
        if envelope.frag == 0 {
            if isMidLine { throw Failure.outOfOrder(expected: nextIndex, got: 0) }
            expectedCount = envelope.of
            nextIndex = 0
            pending = Data()
        }
        guard envelope.frag == nextIndex, envelope.of == expectedCount else {
            let expected = nextIndex
            reset()
            throw Failure.outOfOrder(expected: expected, got: envelope.frag)
        }
        guard pending.count + bytes.count <= maximumLineBytes else {
            reset()
            throw Failure.lineTooLarge
        }
        pending.append(bytes)
        nextIndex += 1
        if nextIndex == expectedCount {
            let line = pending
            reset()
            return line
        }
        return nil
    }

    private mutating func reset() {
        pending = Data()
        expectedCount = 0
        nextIndex = 0
    }
}

/// Splits a byte stream (a socket) into newline-terminated lines.
public struct ByteStreamLineSplitter: Sendable {
    public enum Failure: Error, Equatable, Sendable { case lineTooLarge }

    public let maximumLineBytes: Int
    private var buffer = Data()

    public init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// Bytes held for an unfinished line.
    public var pendingByteCount: Int { buffer.count }

    /// Appends bytes and returns every completed line without its newline.
    /// Empty lines are dropped.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        var searchFrom = buffer.count
        buffer.append(chunk)
        var lineStart = buffer.startIndex
        while let newline = buffer[(buffer.startIndex + searchFrom)...].firstIndex(of: LineFramer.newline) {
            if newline > lineStart { lines.append(Data(buffer[lineStart..<newline])) }
            lineStart = newline + 1
            searchFrom = lineStart - buffer.startIndex
            if searchFrom >= buffer.count { break }
        }
        if lineStart > buffer.startIndex { buffer = Data(buffer[lineStart...]) }
        if buffer.count > maximumLineBytes { throw Failure.lineTooLarge }
        return lines
    }
}
