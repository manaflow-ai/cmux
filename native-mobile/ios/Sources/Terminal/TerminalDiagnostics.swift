import Foundation
import os
import UIKit

/// Which bytes a daemon replay event asks the surface to start over from.
enum TerminalReplay {
    /// The replay for `vt-state` / `resized`, or nil when the event carries
    /// none. A `resized` without a replay (allowed by the protocol: `replay`
    /// and `data` are both optional) only changes the grid: resetting the
    /// surface for it would wipe the screen until the program redraws.
    static func bytes(event: String, payload: JSONValue) -> Data? {
        let key: String
        switch event {
        case "vt-state": key = "data"
        case "resized": key = payload["replay"] != nil ? "replay" : "data"
        default: return nil
        }
        guard let encoded = payload[key]?.string, var replay = Data(base64Encoded: encoded) else {
            return event == "vt-state" ? pending(payload) : nil
        }
        if let bytes = pending(payload) { replay.append(bytes) }
        return replay
    }

    private static func pending(_ payload: JSONValue) -> Data? {
        guard let pending = payload["pending"]?.string else { return nil }
        return Data(base64Encoded: pending)
    }
}

/// Where the Ghostty view rides inside the scroll content (shell mode).
/// Pure so the placement can be checked without a device.
enum TerminalViewportMath {
    /// Space above the grid when the grid is shorter than the area above the composer.
    static func topPad(viewHeight: CGFloat, bottomInset: CGFloat, gridHeight: CGFloat) -> CGFloat {
        max(0, viewHeight - bottomInset - gridHeight)
    }

    /// The first scrollback row Ghostty shows for a content offset, and the
    /// last such row (the live screen).
    static func viewportRow(
        offset: CGFloat, maxOffset: CGFloat, cellHeight: CGFloat,
        totalRows: Int, gridRows: Int, viewportRows: Int
    ) -> (row: Int, maxRow: Int) {
        let maxRow = max(0, totalRows - max(gridRows, viewportRows))
        guard cellHeight.isFinite, cellHeight > 0, offset.isFinite, maxOffset.isFinite else { return (maxRow, maxRow) }
        let clamped = min(max(offset, 0), max(0, maxOffset))
        let raw = (clamped / cellHeight).rounded(.up)
        let row = raw.isFinite ? min(maxRow, max(0, Int(raw))) : maxRow
        return (row, maxRow)
    }

    /// Fraction (0...1) of `frame`'s height inside `visible` (both in one space).
    static func visibleFraction(of frame: CGRect, in visible: CGRect) -> CGFloat {
        guard frame.height > 0 else { return 0 }
        let overlap = frame.intersection(visible)
        return overlap.isNull ? 0 : min(1, overlap.height / frame.height)
    }
}

/// What one Ghostty surface has done; shown by the debug overlay and logged.
struct TerminalSurfaceStats {
    var createdAt: Date?
    var createFailure: String?
    var scale: Double = 0
    var feeds = 0
    var feedBytes = 0
    var lastFeed: Date?
    var pendingFeeds = 0
    var draws = 0
    var lastDraw: Date?
    var gridRequests = 0
    var scrollbar = (total: 0, offset: 0, length: 0)
    var scrollbarEvents = 0
    var rendererHealthy = true
    var occluded = false
    var focused = false
}

/// Event counts for one attached terminal.
struct TerminalSessionStats {
    var attachStarted: Date?
    var attachReplied: Date?
    var attachError: String?
    var vtStates = 0
    var resizes = 0
    var resizesWithoutReplay = 0
    var outputs = 0
    var outputBytes = 0
    var replayBytes = 0
    var lastEvent: String?
    var lastEventAt: Date?
}

/// Diagnostics logging: stderr (devicectl --console) plus the unified log
/// (Console.app, `log collect`), category `terminal`.
let terminalLog = Logger(subsystem: "dev.cmux.next.native", category: "terminal")

/// Unbuffered diagnostics on stderr and the unified log.
func debugLog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    terminalLog.info("\(message, privacy: .public)")
}

/// Hidden overlay with the terminal's render state. Toggle: three-finger
/// long press on the terminal, or `terminal.debugOverlay` in user defaults
/// (launch env `CMUX_NATIVE_TERMINAL_DEBUG=1` turns it on for a run).
@MainActor
final class TerminalDebugOverlay: UIView {
    static let defaultsKey = "terminal.debugOverlay"

    static var enabled: Bool {
        get {
            if ProcessInfo.processInfo.environment["CMUX_NATIVE_TERMINAL_DEBUG"] == "1" { return true }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private let label = UILabel()
    private var timer: Timer?
    var provider: (() -> [String])?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.6).cgColor
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .systemYellow
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        accessibilityIdentifier = "terminal.debugOverlay"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        refresh()
        // A display refresh while visible, not synchronization.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let lines = provider?() ?? []
        label.text = lines.joined(separator: "\n")
        accessibilityValue = label.text
    }
}

extension Date {
    /// "0.4s ago" for the overlay.
    var ago: String { String(format: "%.1fs ago", Date().timeIntervalSince(self)) }
}
