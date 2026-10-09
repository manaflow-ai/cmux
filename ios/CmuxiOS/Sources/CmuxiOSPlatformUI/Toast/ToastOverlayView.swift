import CmuxiOSDesign
import CmuxiOSPlatform
import Observation
import UIKit

/// Renders `ToastCenter.current` at the top of the screen. Touches outside
/// the card pass through. Announces each new toast to VoiceOver, plays the
/// style's haptic, slides (or fades under Reduce Motion), and dismisses on
/// tap or an upward swipe.
@MainActor
final class ToastOverlayView: UIView {
    private let toasts: ToastCenter
    private var card: ToastCardView?

    init(toasts: ToastCenter) {
        self.toasts = toasts
        super.init(frame: .zero)
        backgroundColor = .clear
        toasts.dwellScale = { UIAccessibility.isVoiceOverRunning ? 2 : 1 }
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let card, card.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }

    private func observe() {
        withObservationTracking {
            render(toasts.current)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render(_ toast: Toast?) {
        if let toast, let card, card.toast.id == toast.id {
            card.apply(toast)
            return
        }
        if let old = card { remove(old) }
        card = nil
        guard let toast else { return }
        let next = ToastCardView(
            toast: toast,
            onAction: { [weak toasts] in toasts?.performAction() },
            onDismiss: { [weak toasts] in toasts?.dismiss(toast.id) }
        )
        next.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(tapped))
        swipe.direction = .up
        next.addGestureRecognizer(swipe)
        next.translatesAutoresizingMaskIntoConstraints = false
        addSubview(next)
        NSLayoutConstraint.activate([
            next.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            next.centerXAnchor.constraint(equalTo: centerXAnchor),
            next.leadingAnchor.constraint(greaterThanOrEqualTo: layoutMarginsGuide.leadingAnchor),
            next.trailingAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.trailingAnchor),
            next.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        card = next
        layoutIfNeeded()
        appear(next)
        Self.haptic(toast.style)
        UIAccessibility.post(notification: .announcement, argument: toast.accessibilityText)
    }

    @objc private func tapped() { toasts.dismissCurrent() }

    private func appear(_ view: UIView) {
        view.alpha = 0
        if !HomeMotion.reduceMotion { view.transform = CGAffineTransform(translationX: 0, y: -24) }
        HomeMotion.animate {
            view.alpha = 1
            view.transform = .identity
        }
    }

    private func remove(_ view: UIView) {
        HomeMotion.animate({
            view.alpha = 0
            if !HomeMotion.reduceMotion { view.transform = CGAffineTransform(translationX: 0, y: -24) }
        }, completion: { _ in view.removeFromSuperview() })
    }

    private static func haptic(_ style: ToastStyle) {
        switch style {
        case .info: return
        case .success: Haptics().play(.success)
        case .warning: Haptics().play(.warning)
        case .failure: Haptics().play(.error)
        }
    }
}
