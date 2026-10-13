#if os(iOS)
import UIKit

/// Long-press bubble menu (reference §6 Tapback): the transcript dims to
/// 80% (no blur) while the pressed bubble stays undimmed in place; a 64 pt
/// glass reaction bar sits above it and a 250 pt glass action menu below,
/// aligned to the bubble's sender edge.
@MainActor
final class TapbackOverlay: UIView {
    var onCopy: (() -> Void)?
    var onShare: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let dim = UIView()
    private let bar = makeGlass()
    private let emojiButton = makeGlass()
    private let thoughtDot = makeGlass(interactive: false)
    private let menu = makeGlass(capsule: false, radius: 26)
    private let snapshot: UIView?
    private let bubbleFrame: CGRect
    private let outgoing: Bool
    private let safeTop: CGFloat
    private let safeBottom: CGFloat
    private var spring: SpringDriver?

    static let reactions = ["❤️", "👍", "👎", "😂", "‼️", "❓", "🎉"]

    init(frame: CGRect, bubbleFrame: CGRect, outgoing: Bool, snapshot: UIView?, safeTop: CGFloat, safeBottom: CGFloat) {
        self.bubbleFrame = bubbleFrame
        self.outgoing = outgoing
        self.snapshot = snapshot
        self.safeTop = safeTop
        self.safeBottom = safeBottom
        super.init(frame: frame)
        dim.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.45) : UIColor.black.withAlphaComponent(0.2) }
        dim.frame = bounds
        dim.alpha = 0
        addSubview(dim)
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapDim)))
        if let snapshot {
            snapshot.frame = bubbleFrame
            addSubview(snapshot)
        }
        buildBar()
        buildMenu()
        layoutPanels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildBar() {
        addSubview(bar)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        for r in Self.reactions {
            let b = UIButton(type: .system)
            b.setTitle(r, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 28)
            b.accessibilityLabel = r
            b.addAction(UIAction { [weak self] _ in
                UISelectionFeedbackGenerator().selectionChanged()
                self?.onDismiss?()
            }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        stack.frame = CGRect(x: 8, y: 0, width: CGFloat(Self.reactions.count) * 49, height: 64)
        bar.contentView.addSubview(stack)
        addSubview(thoughtDot)
        addSubview(emojiButton)
        let face = UIImageView(image: UIImage(systemName: "face.smiling", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)))
        face.tintColor = ConvStyle.shared.secondary
        face.contentMode = .center
        face.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        emojiButton.contentView.addSubview(face)
    }

    private func buildMenu() {
        addSubview(menu)
        let items: [(String, String, () -> Void)] = [
            (String(localized: "Copy"), "doc.on.doc", { [weak self] in self?.onCopy?(); self?.onDismiss?() }),
            (String(localized: "Share…"), "square.and.arrow.up", { [weak self] in self?.onDismiss?(); self?.onShare?() }),
        ]
        for (i, item) in items.enumerated() {
            let row = UIButton(type: .system)
            row.frame = CGRect(x: 0, y: 10 + CGFloat(i) * 42, width: 250, height: 42)
            let icon = UIImageView(image: UIImage(systemName: item.1, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)))
            icon.tintColor = ConvStyle.shared.primary
            icon.contentMode = .center
            icon.frame = CGRect(x: 26, y: 0, width: 26, height: 42)
            let label = UILabel(frame: CGRect(x: 64, y: 0, width: 170, height: 42))
            label.text = item.0
            label.font = .sf(17)
            label.textColor = ConvStyle.shared.primary
            row.addSubview(icon)
            row.addSubview(label)
            row.accessibilityLabel = item.0
            let action = item.2
            row.addAction(UIAction { _ in action() }, for: .touchUpInside)
            menu.contentView.addSubview(row)
        }
        menu.bounds = CGRect(x: 0, y: 0, width: 250, height: 20 + CGFloat(items.count) * 42)
    }

    private func layoutPanels() {
        let w = bounds.width
        let barH: CGFloat = 64
        var barY = bubbleFrame.minY - 8 - barH
        var menuY = bubbleFrame.maxY + 12
        let menuH = menu.bounds.height
        // Keep panels on screen: flip the menu above when there is no room.
        if menuY + menuH > bounds.height - safeBottom - 8 {
            menuY = bubbleFrame.minY - 12 - menuH
            barY = menuY - 8 - barH
        }
        barY = max(safeTop + 8, barY)
        bar.frame = CGRect(x: 10.3, y: barY, width: w - 20.6, height: barH)
        let menuX = outgoing ? min(w - 16, bubbleFrame.maxX) - 250 : max(16, bubbleFrame.minX)
        menu.frame = CGRect(x: max(16, menuX), y: menuY, width: 250, height: menuH)
        let ex = outgoing ? bubbleFrame.maxX - 107 : bubbleFrame.minX + 63
        emojiButton.frame = CGRect(x: ex, y: bar.frame.maxY - 8, width: 44, height: 44)
        thoughtDot.frame = CGRect(x: emojiButton.frame.minX + (outgoing ? 2 : 32), y: emojiButton.frame.maxY + 2, width: 10, height: 10)
    }

    func present() {
        let panels: [UIView] = [bar, menu, emojiButton, thoughtDot]
        for p in panels { p.alpha = 0 }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.15) {
                self.dim.alpha = 1
                for p in panels { p.alpha = 1 }
            }
            return
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut]) { self.dim.alpha = 1 }
        let anchors = panels.map { p in CGPoint(x: bubbleFrame.midX - p.center.x, y: bubbleFrame.midY - p.center.y) }
        let s = SpringDriver(value: 0, spring: .pop2, label: "tapback") { t in
            for (p, a) in zip(panels, anchors) {
                let k = lerp(0.6, 1, t)
                p.transform = CGAffineTransform(translationX: a.x * (1 - t), y: a.y * (1 - t)).scaledBy(x: k, y: k)
                p.alpha = clamp01(t * 1.6)
            }
        }
        spring = s
        s.animate(to: 1)
    }

    func dismiss(animated: Bool) {
        spring?.stop()
        guard animated else { removeFromSuperview(); return }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
            self.alpha = 0
        }, completion: { _ in self.removeFromSuperview() })
    }

    @objc private func tapDim() { onDismiss?() }
}
#endif
