public import CmuxTerminalRenderCore
public import CmuxTerminalStream
public import Foundation
import QuartzCore

/// A `.local` source that replays a workload script one chunk per display
/// frame, as a fast remote program would deliver it. The benchmark screen's
/// source; also a reference implementation of `TerminalByteSource`.
@MainActor
public final class FixtureByteSource: TerminalByteSource {
    public nonisolated let authority: TerminalAuthority = .local
    public nonisolated let terminalID: String = "fixture"
    /// Every chunk was delivered.
    public var onFinished: (() -> Void)?
    public private(set) var script: TerminalWorkloadScript?
    public private(set) var delivered = 0
    /// Bytes the terminal wrote back (query replies in `.local` mode).
    public private(set) var replies = 0

    private var continuation: AsyncStream<TerminalSourceEvent>.Continuation?
    private var link: CADisplayLink?

    public init() {}

    /// The script the next `open` replays.
    public func load(_ script: TerminalWorkloadScript) {
        self.script = script
        delivered = 0
    }

    public func open(_ viewport: TerminalViewport) async throws -> AsyncStream<TerminalSourceEvent> {
        stopPump()
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: TerminalSourceEvent.self)
        self.continuation = continuation
        delivered = 0
        if let script { continuation.yield(.title(script.name)) }
        // wakeup-allow: DEBUG benchmark pump, one chunk per vsync while a workload replays; stops itself
        let made = CADisplayLink(target: Pump(owner: self), selector: #selector(Pump.tick))
        made.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        made.add(to: .main, forMode: .common)
        link = made
        return stream
    }

    public func send(_ input: Data) async throws { replies += input.count }
    public func viewportChanged(_ viewport: TerminalViewport) async {}
    public func requestSnapshot(_ request: SnapshotRequest) async throws {}

    public func close() async {
        stopPump()
        continuation?.finish()
        continuation = nil
    }

    fileprivate func tick() {
        guard let script, delivered < script.chunks.count, let continuation else { return stopPump() }
        continuation.yield(.bytes(script.chunks[delivered]))
        delivered += 1
        if delivered == script.chunks.count {
            stopPump()
            onFinished?()
        }
    }

    private func stopPump() {
        link?.invalidate()
        link = nil
    }

    /// The display link calls it on the main run loop.
    @MainActor
    private final class Pump: NSObject {
        weak var owner: FixtureByteSource?
        init(owner: FixtureByteSource) { self.owner = owner }
        @objc func tick() { owner?.tick() }
    }
}
