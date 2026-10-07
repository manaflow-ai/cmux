import Foundation

/// Incremental, byte-preserving tmux control framing. A response block is
/// opaque: a capture line beginning with `%output` is terminal text, never
/// a control notification. Oversize or mismatched blocks fail closed.
struct SSHTmuxControlDecoder: Sendable {
    enum Event: Sendable, Equatable {
        case response(lines: [Data], failed: Bool)
        case notification(Data)
    }

    private var line = Data()
    private var block: String?
    private var response: [Data] = []
    private var responseBytes = 0
    static let maximumLine = 256 * 1024
    static let maximumResponse = 2 * 1024 * 1024

    mutating func append(_ bytes: Data) throws -> [Event] {
        guard bytes.count <= Self.maximumResponse else { throw SSHSessionFailure.shellRejected }
        var events: [Event] = []
        for byte in bytes {
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                if let event = try consume(line) { events.append(event) }
                line.removeAll(keepingCapacity: true)
                guard events.count <= 4096 else { throw SSHSessionFailure.shellRejected }
            } else {
                guard line.count < Self.maximumLine else { throw SSHSessionFailure.shellRejected }
                line.append(byte)
            }
        }
        return events
    }

    private mutating func consume(_ line: Data) throws -> Event? {
        let text = String(decoding: line, as: UTF8.self)
        if let block {
            if text == "%end " + block || text == "%error " + block {
                let event = Event.response(lines: response, failed: text.hasPrefix("%error "))
                self.block = nil
                response = []
                responseBytes = 0
                return event
            }
            // Capture text may contain any '%' prefix. Only an exact block
            // terminator is structural while inside a command response.
            guard responseBytes + line.count + 1 <= Self.maximumResponse,
                  response.count < 4096 else { throw SSHSessionFailure.shellRejected }
            responseBytes += line.count + 1
            response.append(line)
            return nil
        }
        if text.hasPrefix("%begin ") {
            let fields = text.dropFirst(7).split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
                throw SSHSessionFailure.shellRejected
            }
            block = String(text.dropFirst(7))
            return nil
        }
        guard text.hasPrefix("%"), !text.hasPrefix("%end "), !text.hasPrefix("%error ") else {
            throw SSHSessionFailure.shellRejected
        }
        return .notification(line)
    }

    /// Both `%output` and `capture-pane -C` escape bytes as octal. Never
    /// round-trip through Unicode: terminal output may split a UTF-8 scalar.
    static func unescape(_ encoded: Data, capture: Bool = false) throws -> Data {
        let bytes = Array(encoded)
        var result = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 92 {
                // capture-pane -C doubles literal backslashes, whereas
                // control %output encodes them as octal \134.
                if capture, index + 1 < bytes.count, bytes[index + 1] == 92 {
                    result.append(92)
                    index += 2
                    continue
                }
                guard index + 3 < bytes.count,
                      bytes[(index + 1)...(index + 3)].allSatisfy({ (48...55).contains($0) }),
                      bytes[index + 1] <= 51 else { throw SSHSessionFailure.shellRejected }
                result.append((bytes[index + 1] - 48) * 64 + (bytes[index + 2] - 48) * 8 + (bytes[index + 3] - 48))
                index += 4
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return result
    }
}
