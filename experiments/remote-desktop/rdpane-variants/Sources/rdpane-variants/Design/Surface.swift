import AppKit

/// What a floating surface (toolbar pill, state card, menu) is drawn with.
enum SurfaceMaterial: String {
    /// Liquid Glass (`NSGlassEffectView`, macOS 26 and later).
    case glass
    /// A plain opaque fill with a hairline: Reduce Transparency, older
    /// macOS, or `--material opaque`.
    case opaque

    /// `--material auto` follows this Mac: Reduce Transparency wins, then
    /// the OS version decides.
    @MainActor
    static func resolve(_ choice: MaterialChoice) -> SurfaceMaterial {
        let glassAvailable: Bool
        if #available(macOS 26.0, *) { glassAvailable = true } else { glassAvailable = false }
        switch choice {
        case .opaque: return .opaque
        case .glass: return glassAvailable ? .glass : .opaque
        case .auto:
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { return .opaque }
            return glassAvailable ? .glass : .opaque
        }
    }
}

/// Builds floating surfaces in one shape whatever the material.
@MainActor
enum Surface {
    /// A surface that sizes to `content` (pinned edge to edge).
    static func make(content: NSView, material: SurfaceMaterial, tokens: Tokens, cornerRadius: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        if material == .glass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.cornerRadius = cornerRadius
            glass.tintColor = tokens.glassTint
            container.addSubview(glass)
            pin(glass, to: container)
            glass.contentView = content
            pin(content, to: container)
            return container
        }
        let fill = FillView(fill: opaqueFill(tokens), radius: .fixed(cornerRadius), border: tokens.separator.withAlphaComponent(tokens.isDark ? 0.16 : 0.12))
        container.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = tokens.shadow.withAlphaComponent(tokens.isDark ? 0.45 : 0.18)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        container.shadow = shadow
        container.addSubview(fill)
        pin(fill, to: container)
        container.addSubview(content)
        pin(content, to: container)
        return container
    }

    /// The Reduce Transparency fill: the window background lifted toward
    /// the text color (the design module's opaque overlay lift, 0.14).
    static func opaqueFill(_ tokens: Tokens) -> NSColor {
        tokens.windowBackground.blended(withFraction: 0.14, of: tokens.textPrimary) ?? tokens.elevatedBackground
    }

    static func pin(_ view: NSView, to other: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: other.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: other.trailingAnchor),
            view.topAnchor.constraint(equalTo: other.topAnchor),
            view.bottomAnchor.constraint(equalTo: other.bottomAnchor),
        ])
    }
}

/// A layer-backed rectangle with a fill, optional hairline and corner shape.
final class FillView: NSView {
    enum Radius {
        case none
        case fixed(CGFloat)
        case capsule
    }

    var fill: NSColor { didSet { needsDisplay = true } }
    private let radius: Radius
    private let border: NSColor?

    init(fill: NSColor, radius: Radius = .none, border: NSColor? = nil) {
        self.fill = fill
        self.radius = radius
        self.border = border
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fill.cgColor
        layer.cornerCurve = .continuous
        if let border {
            layer.borderColor = border.cgColor
            layer.borderWidth = 1 / max(window?.backingScaleFactor ?? 2, 1)
        }
        applyRadius()
    }

    override func layout() {
        super.layout()
        applyRadius()
    }

    private func applyRadius() {
        switch radius {
        case .none: layer?.cornerRadius = 0
        case .fixed(let value): layer?.cornerRadius = value
        case .capsule: layer?.cornerRadius = bounds.height / 2
        }
    }
}
