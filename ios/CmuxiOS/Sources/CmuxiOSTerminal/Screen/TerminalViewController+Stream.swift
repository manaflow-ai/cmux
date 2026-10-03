import CmuxTerminalStream
import UIKit

/// The channel side of the terminal screen: attach, events, snapshot
/// requests and throttle retries.
extension TerminalViewController {
    func attach() {
        guard stream == nil else { return }
        let pipeline = self.pipeline ?? makePipeline()
        self.pipeline = pipeline
        // Each attach is a new connection: request ids from an older one are void.
        pipeline.connectionReset()
        let source = self.source
        let terminal = self.terminal
        stream = Task { [weak self] in
            guard let events = try? await source.attach(terminal) else { return }
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
        }
        let grid = terminalView.fittingGrid
        Task { await source.setPresence(terminal, visible: true, cols: grid.cols, rows: grid.rows) }
    }

    func detach() {
        stream?.cancel()
        stream = nil
        retry?.cancel()
        retry = nil
        pipeline?.connectionReset()
        let source = self.source
        let terminal = self.terminal
        Task { await source.detach(terminal) }
    }

    private func makePipeline() -> TerminalStreamPipeline {
        TerminalStreamPipeline(renderer: terminalView, terminal: terminal.terminal) { [weak self] controls, stats in
            self?.streamStats = stats
            for control in controls { self?.handle(control) }
        }
    }

    private func apply(_ event: TerminalChannelEvent) {
        switch event {
        case .frame(let data):
            pipeline?.receive(data)
        case .grid(let cols, let rows, let generation):
            pipeline?.grid(cols: cols, rows: rows, generation: generation)
        case .snapshotThrottled(let milliseconds, let requestID):
            pipeline?.throttled(retryAfterMilliseconds: milliseconds, requestID: requestID)
        case .path(let path, _):
            pathText = path.label
            updateBadge()
        case .kicked(let name):
            notice = String(format: String(localized: "terminal.kicked", defaultValue: "Disconnected by %@", bundle: .module), name)
            updateBadge()
        case .closed:
            notice = String(localized: "terminal.closed", defaultValue: "Closed", bundle: .module)
            updateBadge()
        }
    }

    private func handle(_ control: TerminalStreamControl) {
        switch control {
        case .send(let request):
            let source = self.source
            let terminal = self.terminal
            Task { try? await source.requestSnapshot(request, for: terminal) }
        case .retryAfter(let milliseconds):
            retry?.cancel()
            let clock = self.clock
            retry = Task { [weak self] in
                // wakeup-allow: one-shot deadline the host asked for (snapshot_throttled), injected clock, cancelled with the screen
                do { try await clock.sleep(for: .milliseconds(milliseconds)) } catch { return }
                self?.pipeline?.retryDue()
            }
        case .versionMismatch:
            notice = String(localized: "terminal.replay", defaultValue: "Byte replay", bundle: .module)
            updateBadge()
        }
    }

    private func updateBadge() {
        badge.text = [pathText, notice].compactMap { $0 }.joined(separator: " · ")
        badge.sizeToFit()
    }
}

extension TerminalStreamStats {
    /// DEBUG diagnostics keys (terminal.json in the simulator gallery).
    var diagnostics: [String: String] {
        var out = [
            "frames": String(frames), "frames_skipped": String(skippedFrames),
            "frames_undecodable": String(undecodableFrames), "restores": String(restores),
            "restores_refused": String(refusedRestores), "history_pages": String(historyPages),
            "fed_bytes": String(fedBytes), "snapshot_requests": String(snapshotRequests),
            "digest_checks": String(digestChecks), "scrollback_trims": String(scrollbackTrims),
        ]
        if let restoredGeneration { out["restored_generation"] = String(restoredGeneration) }
        if let grid {
            out["surface_grid"] = "\(grid.cols)x\(grid.rows) generation \(grid.generation)" + (grid.locked ? " locked" : "")
        }
        return out
    }
}
