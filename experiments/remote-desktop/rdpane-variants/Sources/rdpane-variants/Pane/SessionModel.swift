import AppKit

/// The network path a session rides (lane 12 paths), as the badge shows it.
enum PathKind {
    case direct(rttMs: Int)
    case relayed(rttMs: Int)
    case connecting
    case ended

    var text: String {
        switch self {
        case .direct(let rtt): "\(L10n.pathDirect) · \(L10n.milliseconds(rtt))"
        case .relayed(let rtt): "\(L10n.pathRelayed) · \(L10n.milliseconds(rtt))"
        case .connecting: L10n.statusConnecting
        case .ended: L10n.statusEnded
        }
    }

    func dotColor(_ tokens: Tokens) -> NSColor {
        switch self {
        case .direct: tokens.success
        case .relayed: tokens.attention
        case .connecting, .ended: tokens.textTertiary
        }
    }
}

enum SessionMode {
    case view
    case control
}

/// What the pane chrome shows. Mock data: no real session behind it.
struct SessionModel {
    var host = "build-linux"
    var path: PathKind = .direct(rttMs: 4)
    var mode: SessionMode = .control
    var controlAvailable = true
    var display = 1
    /// False while connecting and after the session ended: only the host
    /// name and the path badge remain.
    var sessionControls = true
    var lossPercent = "0.0%"
    var glassToGlassMs = 31
}

/// "● direct · 4 ms": the path and live RTT.
final class PathBadge: NSView {
    init(path: PathKind, tokens: Tokens, compact: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let size: CGFloat = compact ? 10.5 : 11.5
        let background = FillView(fill: tokens.hoverFill, radius: .capsule)
        addSubview(background)
        Surface.pin(background, to: self)
        let row = UI.hstack([
            UI.dot(path.dotColor(tokens), diameter: compact ? 6 : 7),
            UI.label(path.text, size: size, weight: .medium, color: tokens.textSecondary, mono: true),
        ], spacing: 5, insets: NSEdgeInsets(top: 0, left: compact ? 6 : 8, bottom: 0, right: compact ? 7 : 9))
        addSubview(row)
        Surface.pin(row, to: self)
        heightAnchor.constraint(equalToConstant: compact ? 18 : 22).isActive = true
        setAccessibilityLabel(path.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
