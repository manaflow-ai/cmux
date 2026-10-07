import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import Foundation

/// Deterministic peer: tests drive command replies and consume outgoing
/// writes as lifecycle signals, with no timers or polling.
actor TmuxTestChannel: SSHShellChannel {
    nonisolated let events: AsyncStream<SSHSessionEvent>
    nonisolated let writes: AsyncStream<String>
    private let incoming: AsyncStream<SSHSessionEvent>.Continuation
    private let outgoing: AsyncStream<String>.Continuation
    private var sequence = 0
    private(set) var closed = false

    init() {
        (events, incoming) = AsyncStream.makeStream(of: SSHSessionEvent.self, bufferingPolicy: .bufferingOldest(64))
        (writes, outgoing) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(64))
    }

    func reply(_ lines: [String]) {
        sequence += 1
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        incoming.yield(.stdout(Data("%begin 100 \(sequence) 1\n\(body)%end 100 \(sequence) 1\n".utf8)))
    }

    func notify(_ wire: String) { incoming.yield(.stdout(Data(wire.utf8))) }
    func write(_ data: Data) async throws { outgoing.yield(String(decoding: data, as: UTF8.self)) }
    func resize(cols: Int, rows: Int) async throws {}
    func close() async {
        closed = true
        incoming.finish()
        outgoing.finish()
    }
}
