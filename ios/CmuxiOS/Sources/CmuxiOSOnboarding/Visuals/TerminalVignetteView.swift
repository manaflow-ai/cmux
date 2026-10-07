import UIKit

/// The welcome step's live vignette: a mini terminal where an agent starts,
/// asks to run tests, is approved from the phone, and passes. Pure Core
/// Animation on the layer clock (keyframes across one loop period, repeated),
/// so the main thread does no per-frame work and nothing runs off screen.
/// Reduce Motion shows the approval moment as a still frame.
final class TerminalVignetteView: UIView {
    private let script = VignetteScript()
    private var builtSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = OnboardingText.vignetteLabel
        backgroundColor = .clear
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self, UITraitAccessibilityContrast.self]) {
            (view: TerminalVignetteView, _: UITraitCollection) in
            view.rebuild()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: VignetteLayout(font: Self.font, width: 320).windowHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != builtSize else { return }
        rebuild()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        rebuild()
    }

    @objc private func settingsChanged() { rebuild() }

    static var font: UIFont {
        let base = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return UIFontMetrics(forTextStyle: .footnote).scaledFont(for: base, maximumPointSize: 15)
    }

    private func rebuild() {
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        builtSize = bounds.size
        guard window != nil, bounds.width > 0 else { return }
        let layout = VignetteLayout(font: Self.font, width: bounds.width)
        let colors = VignetteColors(traits: traitCollection)
        let animated = !UIAccessibility.isReduceMotionEnabled
        let begin = CACurrentMediaTime()
        let builder = VignetteLayerBuilder(layout: layout, colors: colors, script: script, scale: traitCollection.displayScale)
        let scene = builder.build(in: CGRect(x: 0, y: 0, width: bounds.width, height: layout.windowHeight))
        layer.addSublayer(scene.root)
        if animated {
            builder.animate(scene, begin: begin)
        } else {
            builder.applyStillFrame(scene)
        }
        invalidateIntrinsicContentSize()
    }
}
