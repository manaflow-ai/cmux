import CmuxHomeCore
import CmuxHomeRender
import CmuxiOSDesign
import UIKit

/// Shows the tapback picker over the transcript, next to the bubble it
/// reacts to, and keeps it there: when the rows move (a new message while
/// pinned, an older page, a scroll) the picker follows the bubble, found
/// again with the core's hit test, and closes when the bubble leaves the
/// screen. A touch anywhere else closes it. The choice leaves through
/// `onChoose`; the reaction itself appears only when the store's update
/// reaches the core (no local state).
@MainActor
final class HomeTapbackPresenter {
    var onChoose: (HomeReactionTarget, Reaction.Tapback) -> Void = { _, _ in }

    private weak var container: UIView?
    private weak var rowHost: HomeRowHostView?
    private weak var controller: HomeController?
    private var scrim: UIControl?
    private(set) var picker: HomeTapbackPicker?

    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    init(container: UIView, rowHost: HomeRowHostView, controller: HomeController) {
        self.container = container
        self.rowHost = rowHost
        self.controller = controller
    }

    var isShown: Bool { picker != nil }

    func show(_ target: HomeReactionTarget) {
        dismiss(animated: false)
        guard let container, let hit = bubble(for: target) else { return }
        let scrim = UIControl(frame: container.bounds)
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.isAccessibilityElement = false
        scrim.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchDown)
        container.addSubview(scrim)
        self.scrim = scrim

        let picker = HomeTapbackPicker(target: target)
        picker.onChoose = { [weak self] tapback in
            self?.dismiss(animated: true)
            self?.onChoose(target, tapback)
        }
        picker.onDismiss = { [weak self] in self?.dismiss(animated: true) }
        container.addSubview(picker)
        self.picker = picker
        place(picker, at: hit)

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        picker.alpha = 0
        if !HomeMotion.reduceMotion { picker.transform = CGAffineTransform(scaleX: 0.7, y: 0.7) }
        HomeMotion.animate {
            picker.alpha = 1
            picker.transform = .identity
        }
        let focus = picker.buttons.first { $0.accessibilityTraits.contains(.selected) } ?? picker.buttons.first
        UIAccessibility.post(notification: .screenChanged, argument: focus)
    }

    /// The rows moved: the picker follows its bubble, or closes when it is gone.
    func follow() {
        guard let picker else { return }
        guard let hit = bubble(for: picker.target) else { return dismiss(animated: false) }
        place(picker, at: hit)
    }

    func dismiss(animated: Bool) {
        scrim?.removeFromSuperview()
        scrim = nil
        guard let picker else { return }
        self.picker = nil
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        guard animated else { return picker.removeFromSuperview() }
        HomeMotion.animate({
            picker.alpha = 0
            if !HomeMotion.reduceMotion { picker.transform = CGAffineTransform(scaleX: 0.85, y: 0.85) }
        }, completion: { _ in picker.removeFromSuperview() })
    }

    /// The target's bubble on screen now (row host points), if visible.
    private func bubble(for target: HomeReactionTarget) -> HomeHit? {
        guard let controller, controller.size.width > 0 else { return nil }
        return controller.hits(in: CGRect(origin: .zero, size: controller.size)).first {
            $0.item == target.item && $0.partIndex == target.partIndex
        }
    }

    /// Above the bubble (below it when the top would go under the
    /// navigation bar), on the bubble's side, inside the safe area.
    private func place(_ picker: HomeTapbackPicker, at hit: HomeHit) {
        guard let container, let rowHost else { return }
        let bubble = rowHost.convert(hit.bubble, to: container)
        let size = picker.intrinsicContentSize
        let safe = container.bounds.inset(by: container.safeAreaInsets)
        var x = hit.isMine ? bubble.maxX - size.width : bubble.minX
        x = min(max(x, safe.minX + Self.margin), max(safe.minX + Self.margin, safe.maxX - Self.margin - size.width))
        var y = bubble.minY - Self.gap - size.height
        if y < safe.minY + Self.margin { y = bubble.maxY + Self.gap }
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        guard picker.bounds.size != size || picker.center != CGPoint(x: frame.midX, y: frame.midY) else { return }
        picker.bounds = CGRect(origin: .zero, size: size)
        picker.center = CGPoint(x: frame.midX, y: frame.midY)
    }
}
