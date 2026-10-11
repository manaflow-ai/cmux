import Foundation
import GhosttyNextKit

/// A surface handle sent to the output queue. The owner keeps the surface
/// alive until every queued output call returned (ghostty-next threading
/// contract).
struct SurfaceRef: @unchecked Sendable {
    let surface: ghostty_surface_t
    init(_ surface: ghostty_surface_t) { self.surface = surface }
}

/// `TerminalOutputSurface` over a ghostty-next surface. Every call here is an
/// output function (process_output, set_grid, restore_snapshot,
/// encode_snapshot): the caller is the surface's one serial output queue.
struct GhosttyOutputSurface: TerminalOutputSurface {
    let ref: SurfaceRef

    static var snapshotVersion: UInt16 { ghostty_surface_snapshot_version() }

    func feed(_ bytes: Data) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(ref.surface, base, UInt(raw.count))
        }
    }

    func restore(_ snapshot: Data, phase: TerminalSnapshotPhase) -> Bool {
        snapshot.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return ghostty_surface_restore_snapshot(ref.surface, base, raw.count, phase.ghostty)
        }
    }

    func setGrid(cols: Int, rows: Int, generation: UInt64) -> Bool {
        guard let cols = UInt16(exactly: cols), let rows = UInt16(exactly: rows) else { return false }
        return ghostty_surface_set_grid(ref.surface, cols, rows, generation)
    }

    var grid: TerminalGrid {
        let grid = ghostty_surface_grid(ref.surface)
        return TerminalGrid(cols: Int(grid.columns), rows: Int(grid.rows), generation: grid.generation, locked: grid.locked)
    }

    func encode(_ phase: TerminalSnapshotPhase) -> Data? {
        let sink = SnapshotSink()
        let ok = withExtendedLifetime(sink) {
            ghostty_surface_encode_snapshot(ref.surface, { userdata, bytes, length in
                guard let userdata, let bytes else { return }
                // Copy now: the bytes are valid only during the call.
                Unmanaged<SnapshotSink>.fromOpaque(userdata).takeUnretainedValue().data.append(bytes, count: length)
            }, Unmanaged.passUnretained(sink).toOpaque(), phase.ghostty)
        }
        return ok ? sink.data : nil
    }
}

/// Collects encode_snapshot's bytes; written once, before encode returns, on
/// the calling queue.
private final class SnapshotSink {
    var data = Data()
}

extension TerminalSnapshotPhase {
    var ghostty: ghostty_surface_snapshot_phase_e {
        switch self {
        case .ready: GHOSTTY_SURFACE_SNAPSHOT_READY
        case .history: GHOSTTY_SURFACE_SNAPSHOT_HISTORY
        case .complete: GHOSTTY_SURFACE_SNAPSHOT_COMPLETE
        }
    }
}
