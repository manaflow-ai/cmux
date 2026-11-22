import AppKit

/// Small AppKit building blocks. No system accent anywhere: every control
/// draws its own neutral fills from `Tokens`.
@MainActor
enum UI {
    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return field
    }

    static func wrapping(_ text: String, size: CGFloat, color: NSColor, width: CGFloat, centered: Bool = true) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        field.alignment = centered ? .center : .natural
        field.preferredMaxLayoutWidth = width
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return field
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, fallback: String = "circle") -> NSImageView {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
            ?? NSImage()
        let configured = base.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? base
        let view = NSImageView(image: configured)
        view.contentTintColor = color
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    static func hstack(_ views: [NSView], spacing: CGFloat, insets: NSEdgeInsets = NSEdgeInsetsZero) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func vstack(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .centerX, insets: NSEdgeInsets = NSEdgeInsetsZero) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return view
    }

    /// A hairline divider; `length` is its extent along the other axis.
    static func divider(vertical: Bool, length: CGFloat, color: NSColor) -> NSView {
        let view = FillView(fill: color)
        let hairline: CGFloat = 1
        if vertical {
            view.widthAnchor.constraint(equalToConstant: hairline).isActive = true
            view.heightAnchor.constraint(equalToConstant: length).isActive = true
        } else {
            view.heightAnchor.constraint(equalToConstant: hairline).isActive = true
        }
        return view
    }

    static func dot(_ color: NSColor, diameter: CGFloat) -> NSView {
        let view = FillView(fill: color, radius: .capsule)
        view.widthAnchor.constraint(equalToConstant: diameter).isActive = true
        view.heightAnchor.constraint(equalToConstant: diameter).isActive = true
        return view
    }

    static func fixedSize(_ view: NSView, width: CGFloat? = nil, height: CGFloat? = nil) {
        if let width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }
}

/// A flat button: neutral gray fill, a clear "subtle" form, or danger text.
final class ChromeButton: NSControl {
    enum Style {
        case neutral
        case subtle
        case danger
    }

    init(title: String, symbol: String? = nil, style: Style, tokens: Tokens, height: CGFloat = 24, fontSize: CGFloat = 12) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let textColor: NSColor
        let fillColor: NSColor
        switch style {
        case .neutral:
            textColor = tokens.textPrimary
            fillColor = tokens.badgeFill
        case .subtle:
            textColor = tokens.textPrimary
            fillColor = .clear
        case .danger:
            textColor = tokens.danger
            fillColor = tokens.danger.withAlphaComponent(tokens.isDark ? 0.16 : 0.10)
        }
        let background = FillView(fill: fillColor, radius: .fixed(min(height / 2, Metrics.itemCornerRadius + 1)))
        addSubview(background)
        Surface.pin(background, to: self)
        var parts: [NSView] = []
        if let symbol { parts.append(UI.symbol(symbol, size: fontSize - 1, weight: .semibold, color: textColor)) }
        parts.append(UI.label(title, size: fontSize, weight: .medium, color: textColor))
        let row = UI.hstack(parts, spacing: 4, insets: NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10))
        addSubview(row)
        Surface.pin(row, to: self)
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}

/// View / Control. The selected segment is a lifted neutral pill.
final class SegmentedToggle: NSView {
    init(titles: [String], selected: Int, disabled: Set<Int> = [], tokens: Tokens, fontSize: CGFloat = 12, height: CGFloat = 24) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let track = FillView(fill: tokens.hoverFill, radius: .capsule)
        addSubview(track)
        Surface.pin(track, to: self)
        var segments: [NSView] = []
        for (index, title) in titles.enumerated() {
            let isSelected = index == selected
            let color = disabled.contains(index) ? tokens.textTertiary : (isSelected ? tokens.textPrimary : tokens.textSecondary)
            let segment = FillView(fill: isSelected ? tokens.segmentSelected : .clear, radius: .capsule)
            let text = UI.label(title, size: fontSize, weight: isSelected ? .semibold : .medium, color: color)
            segment.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: segment.leadingAnchor, constant: 10),
                text.trailingAnchor.constraint(equalTo: segment.trailingAnchor, constant: -10),
                text.centerYAnchor.constraint(equalTo: segment.centerYAnchor),
                segment.heightAnchor.constraint(equalToConstant: height - 4),
            ])
            if isSelected && !tokens.isDark {
                segment.shadow = {
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
                    shadow.shadowBlurRadius = 2
                    shadow.shadowOffset = NSSize(width: 0, height: -1)
                    return shadow
                }()
            }
            segments.append(segment)
        }
        let row = UI.hstack(segments, spacing: 0, insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
        addSubview(row)
        Surface.pin(row, to: self)
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setAccessibilityRole(.radioGroup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A pop-up menu trigger: title and a small chevron, no fill.
final class MenuChip: NSView {
    init(title: String, symbol: String? = nil, tokens: Tokens, fontSize: CGFloat = 12) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var parts: [NSView] = []
        if let symbol { parts.append(UI.symbol(symbol, size: fontSize - 1, color: tokens.textSecondary)) }
        parts.append(UI.label(title, size: fontSize, weight: .medium, color: tokens.textSecondary))
        parts.append(UI.symbol("chevron.down", size: fontSize - 4, weight: .semibold, color: tokens.textTertiary))
        let row = UI.hstack(parts, spacing: 4, insets: NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
        addSubview(row)
        Surface.pin(row, to: self)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
