import AppKit

/// A centered card over the pane: connecting, consent wait, ended states.
final class StateCard: NSView {
    enum Icon {
        case symbol(String, NSColor)
        case spinner
    }

    init(icon: Icon, title: String, detail: String, buttons: [NSView], tokens: Tokens, material: SurfaceMaterial) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let iconView: NSView
        switch icon {
        case .symbol(let name, let color):
            iconView = UI.symbol(name, size: 24, color: color, fallback: "exclamationmark.circle")
        case .spinner:
            iconView = Self.spinner(tokens: tokens)
        }
        var views: [NSView] = [
            iconView,
            UI.label(title, size: 15, weight: .semibold, color: tokens.textPrimary),
            UI.wrapping(detail, size: 12.5, color: tokens.textSecondary, width: 330),
        ]
        if !buttons.isEmpty { views.append(UI.hstack(buttons, spacing: 8)) }
        let column = UI.vstack(views, spacing: 8, insets: NSEdgeInsets(top: 22, left: 26, bottom: 20, right: 26))
        column.setCustomSpacing(12, after: iconView)
        if let detailView = views.dropFirst(2).first { column.setCustomSpacing(16, after: detailView) }
        let surface = Surface.make(content: column, material: material, tokens: tokens, cornerRadius: 16)
        addSubview(surface)
        Surface.pin(surface, to: self)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A spinner, or a still glyph under Reduce Motion.
    private static func spinner(tokens: Tokens) -> NSView {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return UI.symbol("ellipsis.circle", size: 24, color: tokens.textSecondary)
        }
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.isIndeterminate = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        UI.fixedSize(indicator, width: 26, height: 26)
        indicator.startAnimation(nil)
        return indicator
    }
}

/// "View only, high latency": a banner under the toolbar. The image stays
/// visible because view mode still works on a slow path.
final class LatencyBanner: NSView {
    init(rttMs: Int, path: String, limitMs: Int, tokens: Tokens, material: SurfaceMaterial) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let text = UI.vstack([
            UI.label(L10n.latencyTitle, size: 12.5, weight: .semibold, color: tokens.textPrimary),
            UI.label(L10n.latencyDetail(rtt: rttMs, path: path, limit: limitMs), size: 11.5, color: tokens.textSecondary),
        ], spacing: 2, alignment: .leading)
        let row = UI.hstack([
            UI.symbol("exclamationmark.triangle.fill", size: 15, color: tokens.attention),
            text,
            ChromeButton(title: L10n.controlAnyway, style: .neutral, tokens: tokens, height: 26),
        ], spacing: 12, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 10))
        row.setCustomSpacing(18, after: text)
        let surface = Surface.make(content: row, material: material, tokens: tokens, cornerRadius: 14)
        addSubview(surface)
        Surface.pin(surface, to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The cmux pane's tab strip, drawn so the pane reads in context.
final class MockTabStrip: NSView {
    static let tabWidth: CGFloat = 190

    init(host: String, tokens: Tokens) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let background = FillView(fill: tokens.stripBackground)
        addSubview(background)
        Surface.pin(background, to: self)
        let row = UI.hstack([
            Self.tab(symbol: "terminal", title: "~/src/rd", selected: false, tokens: tokens),
            Self.tab(symbol: "display", title: host, selected: true, tokens: tokens),
            UI.symbol("plus", size: 11, weight: .medium, color: tokens.textTertiary),
        ], spacing: 4, insets: NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
        row.setCustomSpacing(10, after: row.arrangedSubviews[1])
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Metrics.tabStripHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func tab(symbol: String, title: String, selected: Bool, tokens: Tokens) -> NSView {
        let tab = FillView(fill: selected ? tokens.selectionFill : .clear, radius: .fixed(Metrics.itemCornerRadius))
        var parts: [NSView] = [
            UI.symbol(symbol, size: 11, color: selected ? tokens.textPrimary : tokens.textSecondary),
            UI.label(title, size: 12, weight: selected ? .medium : .regular, color: selected ? tokens.textPrimary : tokens.textSecondary),
            UI.spacer(),
        ]
        if selected { parts.append(UI.symbol("xmark", size: 8.5, weight: .semibold, color: tokens.textTertiary)) }
        let row = UI.hstack(parts, spacing: 6, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
        tab.addSubview(row)
        Surface.pin(row, to: tab)
        UI.fixedSize(tab, width: tabWidth, height: Metrics.tabHeight)
        return tab
    }
}
