import Foundation
import Observation

/// One attached terminal: its own daemon connection streaming `vt-state`,
/// `output` and `resized` into the Ghostty surface, plus the mode tracker
/// that decides between native scrolling (shell) and a fixed grid (TUI).
@MainActor
@Observable
final class TerminalSession {
    enum Phase: Equatable {
        case attaching
        case live
        case exited
        case failed(String)
    }

    let surfaceID: Int
    private(set) var phase: Phase = .attaching
    private(set) var cols = 0
    private(set) var rows = 0
    private(set) var modes = TerminalModeTracker()
    /// The terminal's background from the Mac's theme (vt-state colors).
    private(set) var background: String?

    @ObservationIgnored private weak var connection: HostConnection?
    @ObservationIgnored private var client: DaemonClient?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var requestedSize: (cols: Int, rows: Int)?
    /// A replay taken while a TUI ran carries only the alternate screen; the
    /// shell's screen comes back empty when it exits, so attach again then.
    @ObservationIgnored private var primaryScreenMissing = false
    @ObservationIgnored let surfaceView = GhosttySurfaceView()
    /// Event counts for the debug overlay and the device log.
    @ObservationIgnored private(set) var stats = TerminalSessionStats()

    /// Fires when the grid size changes (the scroll view relayouts).
    @ObservationIgnored var onGridChange: ((Int, Int) -> Void)?
    /// Fires when TUI mode flips.
    @ObservationIgnored var onModeChange: ((Bool) -> Void)?

    init(surfaceID: Int, connection: HostConnection) {
        self.surfaceID = surfaceID
        self.connection = connection
    }

    var isTUI: Bool { modes.isTUI }

    /// Attaches with the grid that fits the phone (first call), afterwards
    /// asks the Mac to resize.
    func fit(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let requestedSize, requestedSize == (cols, rows) { return }
        requestedSize = (cols, rows)
        if reader == nil {
            // First fit attaches; later fits (layout passes, keyboard) only
            // resize once the attach is underway.
            attach(cols: cols, rows: rows)
        } else if client != nil {
            resize(to: (cols, rows))
        }
    }

    /// Resizes go out one at a time, latest size wins. A keyboard animation
    /// fits several sizes in a burst; independent tasks reached the daemon in
    /// any order and could leave the Mac on a stale intermediate grid.
    @ObservationIgnored private var pendingResize: (cols: Int, rows: Int)?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?

    private func resize(to size: (cols: Int, rows: Int)) {
        pendingResize = size
        guard resizeTask == nil else { return }
        resizeTask = Task { [weak self] in
            while let self, let next = self.pendingResize, let client = self.client {
                self.pendingResize = nil
                _ = try? await client.request("resize-surface", [
                    "surface": .number(Double(self.surfaceID)), "cols": .number(Double(next.cols)), "rows": .number(Double(next.rows)),
                ])
            }
            self?.resizeTask = nil
        }
    }

    private func attach(cols: Int, rows: Int) {
        guard let connection else { return }
        phase = .attaching
        stats.attachStarted = Date()
        stats.attachError = nil
        debugLog("cmux-native: attach surface \(surfaceID) \(cols)x\(rows)")
        reader = Task { [weak self] in
            do {
                let client = try await connection.openTerminalClient()
                // Detached (or reattached) while the channel opened: this
                // attach is stale and must not replace the newer client.
                guard let self, !Task.isCancelled else {
                    await client.close()
                    return
                }
                self.client = client
                let events = client.events
                let consumer = Task { [weak self] in
                    for await event in events {
                        // Events still queued from a replaced client are stale.
                        guard let self, self.client === client else { continue }
                        self.handle(event)
                    }
                    if self?.client === client { self?.streamEnded() }
                }
                _ = try await client.request("attach-surface", [
                    "surface": .number(Double(self.surfaceID)), "mode": "bytes",
                    "cols": .number(Double(cols)), "rows": .number(Double(rows)),
                ])
                self.stats.attachReplied = Date()
                debugLog("cmux-native: attach ok surface \(self.surfaceID) vt-states \(self.stats.vtStates) outputs \(self.stats.outputs)")
                // The phone is the active viewer: its size wins while visible.
                _ = try? await client.request("set-client-sizing", [
                    "surface": .number(Double(self.surfaceID)), "enabled": true,
                ])
                await consumer.value
            } catch {
                // A detach cancels this attach; its failure isn't the session's.
                if Task.isCancelled { return }
                debugLog("cmux-native: attach FAILED \(error)")
                self?.stats.attachError = error.localizedDescription
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// After the link reconnects: start a fresh attach at the last size.
    func reattach() {
        guard let size = requestedSize else { return }
        detach()
        fit(cols: size.cols, rows: size.rows)
    }

    func detach() {
        reader?.cancel()
        reader = nil
        requestedSize = nil
        let client = client
        self.client = nil
        Task { await client?.close() }
    }

    private func streamEnded() {
        if phase == .live { phase = .failed(String(localized: "Disconnected from the Mac.")) }
    }

    private func handle(_ event: DaemonClient.Event) {
        let payload = event.payload
        guard payload["surface"]?.int == surfaceID || payload["surface"] == nil else { return }
        stats.lastEvent = event.name
        stats.lastEventAt = Date()
        switch event.name {
        case "vt-state":
            stats.vtStates += 1
            applyReplay(payload, event: event.name)
            if stats.vtStates == 1 { debugLog("cmux-native: vt-state \(cols)x\(rows) \(stats.replayBytes)B") }
            phase = .live
            // The daemon may ignore the attach size (no attach-initial-size):
            // claim the phone's grid explicitly.
            if let requestedSize, requestedSize != (cols, rows) { resize(to: requestedSize) }
        case "resized":
            stats.resizes += 1
            applyReplay(payload, event: event.name)
        case "output":
            guard let data = Data(base64Encoded: payload["data"]?.string ?? "") else { return }
            stats.outputs += 1
            stats.outputBytes += data.count
            if modes.scan(data) {
                if !modes.isTUI, primaryScreenMissing {
                    primaryScreenMissing = false
                    reattach()
                    return
                }
                onModeChange?(modes.isTUI)
            }
            surfaceView.feed(data)
        case "surface-exited":
            phase = .exited
        case "detached":
            phase = .failed(String(localized: "This terminal was detached on the Mac."))
        default:
            break
        }
    }

    private func applyReplay(_ payload: JSONValue, event: String) {
        let newCols = payload["cols"]?.int ?? cols
        let newRows = payload["rows"]?.int ?? rows
        if let colors = payload["colors"], let bg = colors["bg"]?.string { background = bg }
        let replay = TerminalReplay.bytes(event: event, payload: payload)
        if newCols != cols || newRows != rows {
            cols = newCols
            rows = newRows
            surfaceView.setGrid(cols: newCols, rows: newRows)
            onGridChange?(newCols, newRows)
        }
        // A resize without a replay keeps the screen (the program redraws
        // through `output`); only a replay starts the surface over.
        guard let replay else {
            stats.resizesWithoutReplay += 1
            return
        }
        stats.replayBytes = replay.count
        let wasTUI = modes.isTUI
        modes = TerminalModeTracker()
        modes.scan(replay)
        primaryScreenMissing = modes.isTUI
        surfaceView.reset(with: replay)
        if wasTUI != modes.isTUI { onModeChange?(modes.isTUI) }
    }

    /// Session facts for the debug overlay.
    func diagnosticsLines() -> [String] {
        let phaseText: String = switch phase {
        case .attaching: "attaching"
        case .live: "live"
        case .exited: "exited"
        case .failed(let message): "FAILED \(message)"
        }
        var lines = ["session \(surfaceID): \(phaseText) grid \(cols)x\(rows) \(isTUI ? "TUI" : "shell") client \(client == nil ? "none" : "open")"]
        let requested = requestedSize.map { "\($0.cols)x\($0.rows)" } ?? "none"
        let attach = stats.attachStarted.map { "sent \($0.ago)" } ?? "not sent"
        lines.append("attach \(attach) reply \(stats.attachReplied?.ago ?? "none") requested \(requested)\(stats.attachError.map { " error \($0)" } ?? "")")
        lines.append("events vt-state \(stats.vtStates) (\(stats.replayBytes)B) resized \(stats.resizes) (\(stats.resizesWithoutReplay) no replay) output \(stats.outputs) (\(stats.outputBytes)B)")
        lines.append("last event \(stats.lastEvent ?? "none") \(stats.lastEventAt?.ago ?? "")")
        return lines
    }

    // MARK: Input

    /// All input goes through one ordered queue: typed text, its Return and
    /// any keys must reach the Mac in the order the user produced them.
    @ObservationIgnored private var inputTail: Task<Void, Never>?

    private func enqueueInput(_ operation: @escaping @Sendable (DaemonClient) async throws -> Void) {
        guard let client else { return }
        let previous = inputTail
        inputTail = Task {
            await previous?.value
            try? await operation(client)
        }
    }

    func send(text: String) {
        let surface = surfaceID
        enqueueInput { try await $0.send(surface: surface, text: text) }
    }

    func paste(_ text: String) {
        let surface = surfaceID
        enqueueInput { try await $0.send(surface: surface, text: text, paste: true) }
    }

    func sendKeys(_ keys: [String]) {
        let surface = surfaceID
        enqueueInput { try await $0.sendKeys(surface: surface, keys) }
    }

    func sendBytes(_ bytes: Data) {
        let surface = surfaceID
        enqueueInput { try await $0.sendBytes(surface: surface, bytes) }
    }
}
