import CmuxTerminalStream
import CryptoKit
import Foundation

/// What the stream asks the screen to do, on the main actor.
enum TerminalStreamControl: Sendable, Hashable {
    /// Send this `snapshot_request` through the source.
    case send(SnapshotRequest)
    /// The host throttled the request: call `retryDue()` after this delay.
    case retryAfter(milliseconds: Int)
    /// The host's snapshot version differs: bytes are now a replay (badge only).
    case versionMismatch(host: UInt16)
    /// Call `readyDeadline(epoch)` after this delay (waiting for a READY).
    case armReadyDeadline(epoch: UInt64, milliseconds: Int)
    /// No READY came in time: detach and attach again.
    case reattach
}

/// Counters for DEBUG diagnostics, copied to the main actor with each update.
struct TerminalStreamStats: Sendable, Hashable {
    var frames = 0
    var skippedFrames = 0
    var undecodableFrames = 0
    var restores = 0
    var refusedRestores = 0
    var historyPages = 0
    var fedBytes = 0
    var snapshotRequests = 0
    var digestChecks = 0
    var scrollbackTrims = 0
    var restoredGeneration: UInt32?
    var grid: TerminalGrid?
}

/// Applies one terminal channel to a renderer under `terminal-snapshot-v1`.
///
/// Order and threading: every frame, grid change and viewer call runs as one
/// work item on the renderer's serial output queue, in the order the main
/// actor enqueued them. The `TerminalViewer` lives there too. That is what
/// makes the digest check exact: when a digest frame is reached, every
/// earlier frame has been parsed, so the local READY encoding (taken
/// synchronously on that queue) is the state the host hashed. The main thread
/// only enqueues; it never waits for the queue. Controls go back to the main
/// actor through the main queue, so they arrive in order.
///
/// Memory: a READY restore gives the terminal the host's scrollback limit,
/// so the phone bounds its local history itself. It never asks for HISTORY
/// (history comes on demand from the host, ghostty-next section 7), and when
/// the bytes parsed since the last READY pass `scrollbackBudget` it re-encodes
/// its own READY and restores it, which drops the local scrollback and keeps
/// the screen. Fed bytes over-count scrollback (escape sequences, redraws), so
/// the bound is conservative.
///
/// `@unchecked Sendable`: the mutable state is confined to the output queue
/// (work items) and the main actor (`renderer`, `deliver` callers).
final class TerminalStreamPipeline: @unchecked Sendable {
    /// `ios.terminal.scrollbackBytes` default (ghostty-next section 7).
    static let defaultScrollbackBudget = 8 * 1024 * 1024

    private weak var renderer: (any TerminalRenderer)?
    private let deliver: @MainActor @Sendable ([TerminalStreamControl], TerminalStreamStats) -> Void
    private let scrollbackBudget: Int
    // Output queue only.
    private var viewer: TerminalViewer
    private var stats = TerminalStreamStats()
    private var bytesSinceReady = 0

    @MainActor
    init(renderer: any TerminalRenderer, terminal: String,
         scrollbackBudget: Int = TerminalStreamPipeline.defaultScrollbackBudget,
         deliver: @escaping @MainActor @Sendable ([TerminalStreamControl], TerminalStreamStats) -> Void) {
        self.renderer = renderer
        self.deliver = deliver
        self.scrollbackBudget = scrollbackBudget
        viewer = TerminalViewer(terminal: terminal, snapshotVersion: renderer.snapshotVersion)
    }

    /// One `terminal_bytes` frame (sub-header plus payload).
    @MainActor func receive(_ frame: Data) {
        run { pipeline, surface in pipeline.decodeAndReceive(frame, surface) }
    }

    /// The host's grid from size-state.
    @MainActor func grid(cols: Int, rows: Int, generation: UInt32) {
        run { _, surface in
            surface.setGrid(cols: cols, rows: rows, generation: UInt64(generation))
            return []
        }
    }

    @MainActor func throttled(retryAfterMilliseconds: Int, requestID: String) {
        run { pipeline, _ in pipeline.viewer.throttled(retryAfterMilliseconds: retryAfterMilliseconds, requestID: requestID) }
    }

    @MainActor func retryDue() {
        run { pipeline, _ in pipeline.viewer.retryDue() }
    }

    /// A new connection starts: forget the in-flight request and wait for the
    /// host's first READY under the viewer's deadline.
    @MainActor func attachStarted() {
        run { pipeline, _ in pipeline.viewer.attachStarted() }
    }

    /// The READY deadline armed for `epoch` ended.
    @MainActor func readyDeadline(_ epoch: UInt64) {
        run { pipeline, _ in pipeline.viewer.readyDeadline(epoch) }
    }

    /// Detach: forget the in-flight request, wait for READY.
    @MainActor func connectionReset() {
        run { pipeline, _ in
            pipeline.viewer.connectionReset()
            return []
        }
    }

    @MainActor
    private func run(_ step: @escaping @Sendable (TerminalStreamPipeline, any TerminalOutputSurface) -> [TerminalViewerAction]) {
        renderer?.enqueueOutput { [self] surface in
            let controls = apply(step(self, surface), surface)
            stats.grid = surface.grid
            let stats = self.stats
            let deliver = self.deliver
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(controls, stats) } }
        }
    }

    // MARK: Output queue

    private func decodeAndReceive(_ data: Data, _ surface: any TerminalOutputSurface) -> [TerminalViewerAction] {
        stats.frames += 1
        let frame: TerminalFrame
        do {
            guard let decoded = try TerminalFrame.decodeSkippingUnknown(data) else {
                stats.skippedFrames += 1
                return []
            }
            frame = decoded
        } catch {
            // A lost frame shows up as an offset gap on the next bytes frame,
            // which resyncs with a snapshot.
            stats.undecodableFrames += 1
            return []
        }
        return viewer.receive(frame, localDigest: {
            stats.digestChecks += 1
            return surface.encode(.ready).map { Data(SHA256.hash(data: $0)) }
        })
    }

    private func apply(_ actions: [TerminalViewerAction], _ surface: any TerminalOutputSurface) -> [TerminalStreamControl] {
        var controls: [TerminalStreamControl] = []
        for action in actions {
            switch action {
            case .restore(let snapshot, let generation):
                if surface.restore(snapshot, phase: .ready) {
                    stats.restores += 1
                    stats.restoredGeneration = generation
                    bytesSinceReady = 0
                } else {
                    // The terminal is unchanged; the next digest or gap resyncs.
                    stats.refusedRestores += 1
                }
            case .prependHistory(let pages):
                if surface.restore(pages, phase: .history) { stats.historyPages += 1 }
                bytesSinceReady += pages.count
                trimIfOverBudget(surface)
            case .feed(let bytes):
                surface.feed(bytes)
                stats.fedBytes += bytes.count
                bytesSinceReady += bytes.count
                trimIfOverBudget(surface)
            case .requestSnapshot(let request):
                stats.snapshotRequests += 1
                controls.append(.send(request))
            case .retryAfter(let milliseconds):
                controls.append(.retryAfter(milliseconds: milliseconds))
            case .versionMismatch(let host):
                controls.append(.versionMismatch(host: host))
            case .armReadyDeadline(let epoch, let milliseconds):
                controls.append(.armReadyDeadline(epoch: epoch, milliseconds: milliseconds))
            case .reattach:
                controls.append(.reattach)
            }
        }
        return controls
    }

    /// Drops local scrollback once the parsed bytes pass the budget: the
    /// terminal's own READY keeps the screens and modes, not the history.
    private func trimIfOverBudget(_ surface: any TerminalOutputSurface) {
        guard bytesSinceReady > scrollbackBudget else { return }
        // Reset first: a failed encode retries after the next budget, not on every feed.
        bytesSinceReady = 0
        guard let ready = surface.encode(.ready), surface.restore(ready, phase: .ready) else { return }
        stats.scrollbackTrims += 1
    }
}
