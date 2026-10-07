import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import Foundation

/// A shell whose output the test drives; records input and resizes.
final class FakeShellChannel: SSHShellChannel, @unchecked Sendable {
    let events: AsyncStream<SSHSessionEvent>
    private let continuation: AsyncStream<SSHSessionEvent>.Continuation
    private let lock = NSLock()
    private var _written: [Data] = []
    private var _resizes: [String] = []
    private var _closed = false

    init() {
        (events, continuation) = AsyncStream.makeStream(of: SSHSessionEvent.self)
    }

    var written: [Data] { lock.withLock { _written } }
    var resizes: [String] { lock.withLock { _resizes } }
    var closed: Bool { lock.withLock { _closed } }

    func emit(_ event: SSHSessionEvent) {
        continuation.yield(event)
        if event == .closed { continuation.finish() }
    }

    func write(_ data: Data) async throws { lock.withLock { _written.append(data) } }
    func resize(cols: Int, rows: Int) async throws { lock.withLock { _resizes.append("\(cols)x\(rows)") } }
    func close() async {
        lock.withLock { _closed = true }
        continuation.finish()
    }
}

/// Hands out scripted results in order and records the PTY sizes asked for.
actor FakeConnector: SSHShellConnector {
    enum Step {
        case open(FakeShellChannel)
        case fail(SSHSessionFailure)
    }

    private var steps: [Step]
    private(set) var requests: [String] = []

    init(_ steps: [Step]) { self.steps = steps }

    func openShell(cols: Int, rows: Int) async throws -> any SSHShellChannel {
        requests.append("\(cols)x\(rows)")
        guard !steps.isEmpty else { throw SSHSessionFailure.network }
        switch steps.removeFirst() {
        case .open(let channel): return channel
        case .fail(let failure): throw failure
        }
    }
}
