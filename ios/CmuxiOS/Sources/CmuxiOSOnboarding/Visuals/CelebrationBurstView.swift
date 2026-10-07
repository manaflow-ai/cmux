import UIKit

/// A short burst of gray terminal glyphs behind the celebrate title
/// (`CAEmitterLayer`, births for half a second, then stops). Reduce Motion
/// shows nothing here; the step's checkmark carries the moment.
final class CelebrationBurstView: UIView {
    private var fired = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !fired, window != nil, bounds.width > 0, !UIAccessibility.isReduceMotionEnabled else { return }
        fired = true
        burst()
    }

    private func burst() {
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        emitter.emitterShape = .point
        emitter.renderMode = .unordered
        emitter.beginTime = CACurrentMediaTime()
        let glyphs = [">", "_", "$", "✓", "{", "}", "#"]
        let shades: [UIColor] = [.label, .secondaryLabel, .tertiaryLabel, .systemGreen]
        emitter.emitterCells = glyphs.enumerated().map { index, glyph in
            let cell = CAEmitterCell()
            cell.contents = Self.image(glyph, color: shades[index % shades.count].resolvedColor(with: traitCollection))
            cell.birthRate = 14
            cell.lifetime = 1.6
            cell.velocity = 220
            cell.velocityRange = 90
            cell.emissionRange = .pi * 2
            cell.yAcceleration = 260
            cell.spin = 2
            cell.spinRange = 4
            cell.scale = 0.5
            cell.scaleRange = 0.2
            cell.alphaSpeed = -0.6
            return cell
        }
        layer.addSublayer(emitter)
        // Stop births after the burst; the in-flight glyphs finish on their own.
        let stop = CABasicAnimation(keyPath: "birthRate")
        stop.fromValue = 1
        stop.toValue = 0
        stop.beginTime = emitter.beginTime + OnboardingMotion.burstBirth
        stop.duration = 0.01
        stop.fillMode = .forwards
        stop.isRemovedOnCompletion = false
        emitter.add(stop, forKey: "stop")
    }

    private static func image(_ glyph: String, color: UIColor) -> CGImage? {
        let font = UIFont.monospacedSystemFont(ofSize: 28, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (glyph as NSString).size(withAttributes: attributes)
        return UIGraphicsImageRenderer(size: size).image { _ in
            (glyph as NSString).draw(at: .zero, withAttributes: attributes)
        }.cgImage
    }
}
