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
    @ObservationIgnored let surfaceView = GhosttySurfaceView()

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
        if client == nil {
            attach(cols: cols, rows: rows)
        } else {
            Task { [weak self] in
                guard let self, let client = self.client else { return }
                _ = try? await client.request("resize-surface", [
                    "surface": .number(Double(self.surfaceID)), "cols": .number(Double(cols)), "rows": .number(Double(rows)),
                ])
            }
        }
    }

    private func attach(cols: Int, rows: Int) {
        guard let connection else { return }
        phase = .attaching
        reader = Task { [weak self] in
            do {
                let client = try await connection.openTerminalClient()
                guard let self else { return }
                self.client = client
                let events = client.events
                let consumer = Task { [weak self] in
                    for await event in events { self?.handle(event) }
                    self?.streamEnded()
                }
                _ = try await client.request("attach-surface", [
                    "surface": .number(Double(self.surfaceID)), "mode": "bytes",
                    "cols": .number(Double(cols)), "rows": .number(Double(rows)),
                ])
                // The phone is the active viewer: its size wins while visible.
                _ = try? await client.request("set-client-sizing", [
                    "surface": .number(Double(self.surfaceID)), "enabled": true,
                ])
                await consumer.value
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func detach() {
        reader?.cancel()
        reader = nil
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
        switch event.name {
        case "vt-state":
            applyReplay(payload, key: "data")
            phase = .live
        case "resized":
            applyReplay(payload, key: payload["replay"] != nil ? "replay" : "data")
        case "output":
            guard let data = Data(base64Encoded: payload["data"]?.string ?? "") else { return }
            if modes.scan(data) { onModeChange?(modes.isTUI) }
            surfaceView.feed(data)
        case "surface-exited":
            phase = .exited
        case "detached":
            phase = .failed(String(localized: "This terminal was detached on the Mac."))
        default:
            break
        }
    }

    private func applyReplay(_ payload: JSONValue, key: String) {
        let newCols = payload["cols"]?.int ?? cols
        let newRows = payload["rows"]?.int ?? rows
        if let colors = payload["colors"], let bg = colors["bg"]?.string { background = bg }
        var replay = Data(base64Encoded: payload[key]?.string ?? "") ?? Data()
        if let pending = payload["pending"]?.string, let bytes = Data(base64Encoded: pending) { replay.append(bytes) }
        let wasTUI = modes.isTUI
        modes = TerminalModeTracker()
        modes.scan(replay)
        if newCols != cols || newRows != rows {
            cols = newCols
            rows = newRows
            surfaceView.setGrid(cols: newCols, rows: newRows)
            onGridChange?(newCols, newRows)
        }
        surfaceView.reset(with: replay)
        if wasTUI != modes.isTUI { onModeChange?(modes.isTUI) }
    }

    // MARK: Input

    func send(text: String) {
        guard let client else { return }
        Task { try? await client.send(surface: surfaceID, text: text) }
    }

    func paste(_ text: String) {
        guard let client else { return }
        Task { try? await client.send(surface: surfaceID, text: text, paste: true) }
    }

    func sendKeys(_ keys: [String]) {
        guard let client else { return }
        Task { try? await client.sendKeys(surface: surfaceID, keys) }
    }

    func sendBytes(_ bytes: Data) {
        guard let client else { return }
        Task { try? await client.sendBytes(surface: surfaceID, bytes) }
    }
}
