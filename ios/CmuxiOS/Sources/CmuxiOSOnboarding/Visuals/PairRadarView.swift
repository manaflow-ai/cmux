import UIKit

/// Two rings that grow and fade around the laptop glyph while discovery
/// searches (Core Animation, repeating). Reduce Motion shows one still ring.
final class PairRadarView: UIView {
    var isSearching = true {
        didSet { if isSearching != oldValue { rebuild() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PairRadarView, _: UITraitCollection) in view.rebuild() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuild()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        rebuild()
    }

    @objc private func settingsChanged() { rebuild() }

    private func rebuild() {
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard window != nil, bounds.width > 0 else { return }
        let color = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
        let side = min(bounds.width, bounds.height)
        let animated = isSearching && !UIAccessibility.isReduceMotionEnabled
        for index in 0..<(animated ? 2 : 1) {
            let ring = CAShapeLayer()
            ring.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            ring.path = UIBezierPath(ovalIn: ring.bounds.insetBy(dx: 1, dy: 1)).cgPath
            ring.fillColor = nil
            ring.strokeColor = color
            ring.lineWidth = 1.5
            layer.addSublayer(ring)
            guard animated else {
                ring.opacity = isSearching ? 0.6 : 0
                continue
            }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.6
            scale.toValue = 1.4
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = OnboardingMotion.radarPeriod
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() + OnboardingMotion.radarPeriod / 2 * Double(index)
            group.fillMode = .backwards
            ring.opacity = 0
            ring.add(group, forKey: "radar")
        }
    }
}
