import AppKit

/// Variant A: a floating pill at the top center of the pane, shown on hover.
/// The prototype pins it in the shown state; `setRevealed` is the hover path.
final class HoverToolbar: NSView {
    private let surface: NSView

    init(model: SessionModel, tokens: Tokens, material: SurfaceMaterial) {
        var items: [NSView] = [
            UI.symbol("display", size: 12, color: tokens.textSecondary),
            UI.label(model.host, size: 12.5, weight: .semibold, color: tokens.textPrimary),
            PathBadge(path: model.path, tokens: tokens),
        ]
        if model.sessionControls {
            items.append(UI.divider(vertical: true, length: 16, color: tokens.separator))
            items.append(SegmentedToggle(
                titles: [L10n.modeView, L10n.modeControl],
                selected: model.mode == .view ? 0 : 1,
                disabled: model.controlAvailable ? [] : [1],
                tokens: tokens
            ))
            items.append(UI.divider(vertical: true, length: 16, color: tokens.separator))
            items.append(MenuChip(title: L10n.display(model.display), tokens: tokens))
            items.append(MenuChip(title: L10n.qualityAuto, symbol: "dial.medium", tokens: tokens))
            items.append(ChromeButton(title: L10n.stop, symbol: "stop.fill", style: .danger, tokens: tokens))
        }
        let row = UI.hstack(items, spacing: 8, insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 6))
        row.setCustomSpacing(6, after: items[0])
        surface = Surface.make(content: row, material: material, tokens: tokens, cornerRadius: 19)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        Surface.pin(surface, to: self)
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows or hides the pill: a short fade, none under Reduce Motion.
    func setRevealed(_ revealed: Bool) {
        let target: CGFloat = revealed ? 1 : 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = target
        }
    }
}

/// Variant B: a thin plain strip under the image, always visible. It takes
/// its own row, so it never covers remote pixels.
final class StatusStrip: NSView {
    static let height: CGFloat = 28

    init(model: SessionModel, tokens: Tokens) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let background = FillView(fill: tokens.stripBackground)
        addSubview(background)
        Surface.pin(background, to: self)
        let hairline = UI.divider(vertical: false, length: 0, color: tokens.separator)
        addSubview(hairline)
        let stats = "\(L10n.loss(model.lossPercent)) · \(L10n.glassToGlass(model.glassToGlassMs))"
        let items: [NSView] = [
            UI.symbol("display", size: 11, color: tokens.textSecondary),
            UI.label(model.host, size: 11.5, weight: .semibold, color: tokens.textPrimary),
            PathBadge(path: model.path, tokens: tokens, compact: true),
            UI.label(stats, size: 11, color: tokens.textTertiary, mono: true),
            UI.spacer(),
            SegmentedToggle(titles: [L10n.modeView, L10n.modeControl], selected: model.mode == .view ? 0 : 1,
                            tokens: tokens, fontSize: 11, height: 20),
            MenuChip(title: L10n.display(model.display), tokens: tokens, fontSize: 11),
            MenuChip(title: L10n.qualityAuto, symbol: "dial.medium", tokens: tokens, fontSize: 11),
            ChromeButton(title: L10n.stop, symbol: "stop.fill", style: .danger, tokens: tokens, height: 20, fontSize: 11),
        ]
        let row = UI.hstack(items, spacing: 8, insets: NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 4))
        row.setCustomSpacing(5, after: items[0])
        addSubview(row)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Variant C: only a tiny path badge in the corner over the image.
final class CornerBadge: NSView {
    init(model: SessionModel, tokens: Tokens, material: SurfaceMaterial) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let badge = PathBadge(path: model.path, tokens: tokens, compact: true)
        let surface = Surface.make(content: badge, material: material, tokens: tokens, cornerRadius: 9)
        addSubview(surface)
        Surface.pin(surface, to: self)
        alphaValue = 0.92
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
