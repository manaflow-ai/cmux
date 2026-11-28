import AppKit

/// I1: a thin colored border along the (mock) screen edge. Never takes
/// mouse events.
final class EdgeBorderView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.7)
        glow.shadowBlurRadius = 8
        glow.set()
        color.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// I1 and I2: "● Controlled by Lawrence | Stop", floating at the top center.
final class IndicatorPill: NSView {
    init(viewer: String, tokens: Tokens, material: SurfaceMaterial) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let row = UI.hstack([
            UI.dot(tokens.controlIndicator, diameter: 8),
            UI.label(L10n.controlledBy(viewer), size: 12.5, weight: .semibold, color: tokens.textPrimary),
            UI.divider(vertical: true, length: 16, color: tokens.separator),
            ChromeButton(title: L10n.stop, symbol: "stop.fill", style: .danger, tokens: tokens, height: 24),
        ], spacing: 9, insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 6))
        let surface = Surface.make(content: row, material: material, tokens: tokens, cornerRadius: 18)
        addSubview(surface)
        Surface.pin(surface, to: self)
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        setAccessibilityLabel(L10n.controlledBy(viewer))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// I3: the menu bar item's open menu: every viewer with its own Stop, then
/// Stop All Sessions.
@MainActor
enum HostMenu {
    static func make(tokens: Tokens, material: SurfaceMaterial) -> NSView {
        MockMenu(items: [
            .header(L10n.hostMenuTitle),
            .custom(sessionRow(name: "Lawrence", detail: "lawrence-laptop · \(L10n.modeControl) · \(PathKind.direct(rttMs: 4).text)",
                               dot: tokens.controlIndicator, tokens: tokens)),
            .custom(sessionRow(name: "Sam", detail: "sam-ipad · \(L10n.modeView) · \(PathKind.relayed(rttMs: 142).text)",
                               dot: tokens.textTertiary, tokens: tokens)),
            .separator,
            .item(L10n.hostStopAll, danger: true),
            .item(L10n.hostSettings),
        ], width: 330, tokens: tokens, material: material)
    }

    private static func sessionRow(name: String, detail: String, dot: NSColor, tokens: Tokens) -> NSView {
        let text = UI.vstack([
            UI.label(name, size: 13, weight: .medium, color: tokens.textPrimary),
            UI.label(detail, size: 11, color: tokens.textSecondary, mono: true),
        ], spacing: 1, alignment: .leading)
        return UI.hstack([
            UI.dot(dot, diameter: 8),
            text,
            UI.spacer(),
            ChromeButton(title: L10n.stop, style: .danger, tokens: tokens, height: 22, fontSize: 11.5),
        ], spacing: 9)
    }
}

/// The consent sheet on the host, hanging from the mock cmux window.
/// Deny is not the default and nothing is the default: Return does
/// nothing, because this is a security decision.
@MainActor
enum ConsentSheet {
    static func make(requester: String, seconds: Int, total: Int, tokens: Tokens, material: SurfaceMaterial) -> NSView {
        let header = UI.hstack([
            UI.symbol("rectangle.inset.filled.and.person.filled", size: 24, color: tokens.textSecondary, fallback: "display"),
            UI.vstack([
                UI.label(L10n.consentRequestControl(requester), size: 14.5, weight: .semibold, color: tokens.textPrimary),
                UI.label(L10n.hostMenuTitle, size: 11.5, color: tokens.textTertiary),
            ], spacing: 2, alignment: .leading),
        ], spacing: 12)
        let facts = UI.vstack([
            fact(L10n.consentDevice, value: "sam-laptop · macOS 27", tokens: tokens),
            fact(L10n.consentPath, value: PathKind.direct(rttMs: 6).text, dot: tokens.success, tokens: tokens),
            fact(L10n.consentAccount, value: "sam@example.com", tokens: tokens),
        ], spacing: 6, alignment: .leading)
        let note = UI.wrapping(L10n.consentNote, size: 11.5, color: tokens.textSecondary, width: 392, centered: false)
        let countdown = countdownBar(seconds: seconds, total: total, tokens: tokens)
        let buttons = UI.hstack([
            ChromeButton(title: L10n.consentDeny, style: .subtle, tokens: tokens, height: 28, fontSize: 12.5),
            UI.spacer(),
            ChromeButton(title: L10n.consentAllowView, style: .neutral, tokens: tokens, height: 28, fontSize: 12.5),
            ChromeButton(title: L10n.consentAllowControl, style: .neutral, tokens: tokens, height: 28, fontSize: 12.5),
        ], spacing: 8)
        let column = UI.vstack([header, facts, note, countdown, buttons], spacing: 14, alignment: .leading,
                               insets: NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22))
        for view in [facts, countdown, buttons] {
            view.widthAnchor.constraint(equalToConstant: 392).isActive = true
        }
        let surface = Surface.make(content: column, material: material, tokens: tokens, cornerRadius: 16)
        surface.widthAnchor.constraint(equalToConstant: 436).isActive = true
        return surface
    }

    private static func fact(_ label: String, value: String, dot: NSColor? = nil, tokens: Tokens) -> NSView {
        let name = UI.label(label, size: 12, color: tokens.textTertiary)
        name.widthAnchor.constraint(equalToConstant: 72).isActive = true
        var parts: [NSView] = [name]
        if let dot { parts.append(UI.dot(dot, diameter: 7)) }
        parts.append(UI.label(value, size: 12, weight: .medium, color: tokens.textPrimary, mono: true))
        return UI.hstack(parts, spacing: 6)
    }

    private static func countdownBar(seconds: Int, total: Int, tokens: Tokens) -> NSView {
        let track = FillView(fill: tokens.hoverFill, radius: .capsule)
        let fill = FillView(fill: tokens.textSecondary, radius: .capsule)
        track.addSubview(fill)
        let fraction = CGFloat(seconds) / CGFloat(max(total, 1))
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: fraction),
        ])
        let caption = UI.label(L10n.consentCountdown(seconds), size: 11, color: tokens.textTertiary, mono: true)
        let column = UI.vstack([track, caption], spacing: 5, alignment: .leading)
        track.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }
}
