import CnxTerminal
import Foundation

/// What one attach-stream event line means for the terminal, in order.
enum DaemonTerminalInbound: Sendable, Equatable {
    /// Bytes for the mirror.
    case output(Data)
    /// The program entered or left the alternate screen (after the bytes that switched).
    case alternateScreen(Bool)
    /// The Mac terminal's rows (`vt-state`, `resized`).
    case rows(Int)
    /// The authoritative mirror changed size: reset the local mirror before the replay.
    case resetMirror
    /// The daemon ended the surface.
    case detached(reason: String?)
}

/// Decodes attach-stream event lines (JSON, base64) and follows the alternate
/// screen. Pure, so it runs off the main thread: a flood of `output` lines
/// costs the main thread nothing until the screen takes the bytes.
struct DaemonTerminalEventParser: Sendable {
    let surface: Int
    private var detector = AlternateScreenDetector()

    init(surface: Int) { self.surface = surface }

    mutating func parse(_ line: Data) -> [DaemonTerminalInbound] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else { return [] }
        if let id = object["surface"] as? Int, id != surface { return [] }
        var out: [DaemonTerminalInbound] = []
        switch event {
        case "vt-state":
            if let rows = object["rows"] as? Int, rows > 0 { out.append(.rows(rows)) }
            emit(object["data"] as? String, into: &out)
            emit(object["pending"] as? String, into: &out)
        case "output":
            emit(object["data"] as? String, into: &out)
        case "resized":
            if let rows = object["rows"] as? Int, rows > 0 { out.append(.rows(rows)) }
            // The authoritative mirror changed size: start over from the replay.
            detector = AlternateScreenDetector()
            out.append(.resetMirror)
            emit((object["replay"] as? String) ?? (object["data"] as? String), into: &out)
            emit(object["pending"] as? String, into: &out)
        case "detached":
            out.append(.detached(reason: object["reason"] as? String))
        default:
            break
        }
        return out
    }

    private mutating func emit(_ base64: String?, into out: inout [DaemonTerminalInbound]) {
        guard let base64, let data = Data(base64Encoded: base64), !data.isEmpty else { return }
        out.append(.output(data))
        if let alternate = detector.scan(data) { out.append(.alternateScreen(alternate)) }
    }
}

/// Hands parsed events from the reader to the main actor: one main-queue hop
/// per batch, however many lines arrived since the last one. The reader waits
/// (and stops reading the channel) while more than `highWater` bytes are
/// waiting for the main actor, or while the screen asked for a pause
/// (``DaemonTerminalSession/setOutputPaused(_:)``).
final class DaemonTerminalInbox: @unchecked Sendable {
    static let highWater = 4 << 20

    private let lock = NSLock()
    private var items: [DaemonTerminalInbound] = []
    private var bytes = 0
    private var scheduled = false
    private var paused = false
    private var closed = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let deliver: @Sendable ([DaemonTerminalInbound]) -> Void
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// `deliver` runs on the main actor with every event queued since the last call.
    init(
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) },
        deliver: @escaping @Sendable ([DaemonTerminalInbound]) -> Void
    ) {
        self.schedule = schedule
        self.deliver = deliver
    }

    /// Queues events; waits first while the screen is behind.
    func push(_ events: [DaemonTerminalInbound]) async {
        guard !events.isEmpty else { return }
        await waitForRoom()
        let size = events.reduce(0) { if case .output(let data) = $1 { $0 + data.count } else { $0 } }
        let needsSchedule: Bool = lock.withLock {
            guard !closed else { return false }
            items += events
            bytes += size
            defer { scheduled = true }
            return !scheduled
        }
        if needsSchedule { schedule { [self] in drain() } }
    }

    private func waitForRoom() async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if closed || (!paused && bytes < Self.highWater) { return true }
                waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Main queue: delivers everything queued.
    private func drain() {
        let (batch, resume): ([DaemonTerminalInbound], CheckedContinuation<Void, Never>?) = lock.withLock {
            let batch = items
            items.removeAll(keepingCapacity: true)
            bytes = 0
            scheduled = false
            return (batch, takeWaiterIfReady())
        }
        resume?.resume()
        deliver(batch)
    }

    func setPaused(_ paused: Bool) {
        let resume = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            self.paused = paused
            return takeWaiterIfReady()
        }
        resume?.resume()
    }

    /// The channel ended: nothing more is delivered and the reader never waits.
    func close() {
        let resume = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            closed = true
            items.removeAll()
            bytes = 0
            return takeWaiterIfReady()
        }
        resume?.resume()
    }

    private func takeWaiterIfReady() -> CheckedContinuation<Void, Never>? {
        guard let waiter, closed || (!paused && bytes < Self.highWater) else { return nil }
        self.waiter = nil
        return waiter
    }

    var pendingBytes: Int { lock.withLock { bytes } }
}
