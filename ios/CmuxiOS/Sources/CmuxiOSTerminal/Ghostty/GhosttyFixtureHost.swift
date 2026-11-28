#if DEBUG
import Foundation
import GhosttyNextKit
import UIKit

/// The mock host's own terminal: a real ghostty-next surface that is never
/// shown. The mock feeds it the same bytes it sends and encodes its
/// snapshots and digests with it, so the GHOSTSNP bytes the phone restores
/// come from Ghostty, never from hand-written fixtures. DEBUG only.
@MainActor
final class GhosttyFixtureHost {
    enum Failure: Error { case surfaceCreationFailed }

    private let view: UIView
    private let ref: SurfaceRef
    /// The output functions run here, never on the main thread.
    private let queue = DispatchQueue(label: "cmux.ios.terminal.fixture-host")
    private var closed = false

    init() throws {
        let app = try GhosttyNextApp.shared()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = 2
        config.font_size = 13
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        guard let surface = ghostty_surface_new(app.app, &config) else { throw Failure.surfaceCreationFailed }
        // Never drawn: it only parses and encodes.
        ghostty_surface_set_occlusion(surface, false)
        self.view = view
        ref = SurfaceRef(surface)
    }

    func feed(_ bytes: Data) async {
        guard !closed else { return }
        await perform { $0.feed(bytes) }
    }

    func setGrid(cols: Int, rows: Int, generation: UInt64) async -> Bool {
        guard !closed else { return false }
        return await perform { $0.setGrid(cols: cols, rows: rows, generation: generation) }
    }

    func encode(_ phase: TerminalSnapshotPhase) async -> Data? {
        guard !closed else { return nil }
        return await perform { $0.encode(phase) }
    }

    /// Frees the surface after every queued call returned.
    func close() async {
        guard !closed else { return }
        closed = true
        await perform { _ in }
        ghostty_surface_free(ref.surface)
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable (GhosttyOutputSurface) -> T) async -> T {
        let output = GhosttyOutputSurface(ref: ref)
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work(output)) }
        }
    }
}
#endif
