import SwiftUI
import UIKit

/// ChatGPT / Claude style sidebar: the main content is a card that slides
/// right over the sidebar, with a rounded leading edge and a dim. The whole
/// gesture runs in UIKit (one transform per frame, no SwiftUI layout), so it
/// tracks the finger at the display's refresh rate.
@MainActor
final class SidebarContainerController: UIViewController, UIGestureRecognizerDelegate {
    let sidebarHost: UIViewController
    let contentHost: UIViewController
    /// Called when the sidebar starts opening (true) or closing (false).
    var onOpenChange: ((Bool) -> Void)?

    private let card = UIView()
    private let clip = UIView()
    private let edge = UIView()
    private let dim = UIControl()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))

    private var progress: CGFloat = 0
    private var panStart: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private var isOpen = false
    private var competingPans: [WeakRecognizer] = []

    private struct WeakRecognizer { weak var value: UIGestureRecognizer? }

    init(sidebar: UIViewController, content: UIViewController) {
        sidebarHost = sidebar
        contentHost = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    private var openWidth: CGFloat {
        let width = view.bounds.width
        return min((width * 0.8).rounded(), 360)
    }

    /// Matches the display corners on Face ID iPhones; small on square screens.
    private var cardRadius: CGFloat {
        (view.window?.safeAreaInsets.bottom ?? 0) > 0 ? 54 : 14
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.sidebarBackground

        addChild(sidebarHost)
        sidebarHost.view.backgroundColor = Self.sidebarBackground
        sidebarHost.view.isHidden = true
        view.addSubview(sidebarHost.view)
        sidebarHost.didMove(toParent: self)

        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.28
        card.layer.shadowRadius = 18
        card.layer.shadowOffset = .zero
        view.addSubview(card)

        clip.clipsToBounds = true
        clip.layer.cornerCurve = .continuous
        clip.backgroundColor = .systemBackground
        card.addSubview(clip)

        addChild(contentHost)
        clip.addSubview(contentHost.view)
        contentHost.didMove(toParent: self)

        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        dim.addTarget(self, action: #selector(dimTapped), for: .touchUpInside)
        dim.isAccessibilityElement = true
        dim.accessibilityLabel = String(localized: "Close sidebar")
        dim.accessibilityTraits = .button
        dim.accessibilityIdentifier = "sidebar.dim"
        dim.accessibilityElementsHidden = true
        clip.addSubview(dim)

        edge.isUserInteractionEnabled = false
        edge.layer.cornerCurve = .continuous
        edge.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        edge.alpha = 0
        card.addSubview(edge)

        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateColors() }
        updateColors()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        sidebarHost.view.bounds = CGRect(x: 0, y: 0, width: openWidth, height: bounds.height)
        sidebarHost.view.center = CGPoint(x: openWidth / 2, y: bounds.midY)
        card.bounds = bounds
        card.center = CGPoint(x: bounds.midX, y: bounds.midY)
        clip.frame = card.bounds
        edge.frame = card.bounds
        contentHost.view.frame = clip.bounds
        dim.frame = clip.bounds
        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: cardRadius).cgPath
        if animator == nil, pan.state != .changed { apply(progress) }
    }

    private func updateColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        edge.layer.borderColor = UIColor(white: dark ? 1 : 0, alpha: dark ? 0.16 : 0.08).cgColor
        card.layer.shadowOpacity = dark ? 0.5 : 0.18
    }

    /// One frame of the transition. 0 = closed, 1 = open, >1 = rubber band.
    private func apply(_ value: CGFloat) {
        progress = value
        let clamped = min(max(value, 0), 1)
        card.transform = CGAffineTransform(translationX: openWidth * value, y: 0)
        let radius = cardRadius * min(1, clamped * 4)
        clip.layer.cornerRadius = radius
        edge.layer.cornerRadius = radius
        dim.alpha = clamped * (traitCollection.userInterfaceStyle == .dark ? 0.45 : 0.22)
        edge.alpha = clamped
        sidebarHost.view.transform = CGAffineTransform(translationX: -48 * (1 - clamped), y: 0)
        sidebarHost.view.alpha = 0.4 + 0.6 * clamped
    }

    // MARK: Open / close

    func setOpen(_ open: Bool, animated: Bool, velocity: CGFloat = 0) {
        guard isViewLoaded else { return }
        willChange(open: open)
        if let animator {
            animator.stopAnimation(true)
            self.animator = nil
            progress = card.transform.tx / max(openWidth, 1)
        }
        let target: CGFloat = open ? 1 : 0
        guard animated, view.window != nil else {
            apply(target)
            didSettle(open: open)
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            crossFade(to: target, open: open)
            return
        }
        let distance = (target - progress) * openWidth
        let relative = abs(distance) > 1 ? velocity / distance : 0
        let spring = UISpringTimingParameters(
            duration: 0.42, bounce: 0,
            initialVelocity: CGVector(dx: relative, dy: relative)
        )
        let animator = UIViewPropertyAnimator(duration: 0.42, timingParameters: spring)
        animator.isUserInteractionEnabled = true
        animator.addAnimations { [weak self] in self?.apply(target) }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end else { return }
            self.animator = nil
            self.didSettle(open: open)
        }
        self.animator = animator
        animator.startAnimation()
    }

    private func crossFade(to target: CGFloat, open: Bool) {
        let snapshot = card.snapshotView(afterScreenUpdates: false)
        if let snapshot {
            snapshot.frame = card.frame
            view.addSubview(snapshot)
        }
        card.alpha = 0
        apply(target)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            snapshot?.alpha = 0
            self.card.alpha = 1
        } completion: { _ in
            snapshot?.removeFromSuperview()
            self.didSettle(open: open)
        }
    }

    private func willChange(open: Bool) {
        sidebarHost.view.isHidden = false
        if open { view.window?.endEditing(true) }
        dim.isUserInteractionEnabled = open
        if open != isOpen {
            isOpen = open
            onOpenChange?(open)
        }
        dim.accessibilityElementsHidden = !open
        contentHost.view.accessibilityElementsHidden = open
        sidebarHost.view.accessibilityElementsHidden = !open
        if open { UIAccessibility.post(notification: .screenChanged, argument: sidebarHost.view) }
    }

    private func didSettle(open: Bool) {
        sidebarHost.view.isHidden = !open
        if !open { UIAccessibility.post(notification: .screenChanged, argument: nil) }
    }

    @objc private func dimTapped() { setOpen(false, animated: true) }

    override func accessibilityPerformEscape() -> Bool {
        guard isOpen else { return false }
        setOpen(false, animated: true)
        return true
    }

    // MARK: Pan

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let width = openWidth
        switch pan.state {
        case .began:
            if let animator {
                animator.stopAnimation(true)
                self.animator = nil
            }
            panStart = min(max(card.transform.tx / width, 0), 1)
            for recognizer in competingPans.compactMap(\.value) where recognizer.state == .began || recognizer.state == .changed {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
            competingPans.removeAll()
            sidebarHost.view.isHidden = false
            view.window?.endEditing(true)
        case .changed:
            let raw = panStart + pan.translation(in: view).x / width
            apply(raw > 1 ? 1 + 0.08 * (1 - exp(-(raw - 1) * 4)) : max(raw, 0))
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: view).x
            let open: Bool
            if pan.state != .ended {
                open = progress > 0.5
            } else if abs(velocity) > 400 {
                open = velocity > 0
            } else {
                open = progress + velocity * 0.15 / width > 0.5
            }
            setOpen(open, animated: true, velocity: velocity)
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
        if isOpen || animator != nil { return true }
        // Closed: a fast pan to the right on a root screen opens the sidebar.
        guard velocity.x > 180, contentIsAtRoot, !touchIsInHorizontalScroller(pan.location(in: view)) else { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, other is UIPanGestureRecognizer else { return false }
        // Scroll views and TUI pans may start on the same touch; they are
        // cancelled once the sidebar pan wins (it only begins horizontally).
        competingPans.append(WeakRecognizer(value: other))
        return true
    }

    private var contentIsAtRoot: Bool {
        guard contentHost.presentedViewController == nil else { return false }
        func navigationControllers(_ controller: UIViewController) -> [UINavigationController] {
            var found = controller.children.flatMap(navigationControllers)
            if let nav = controller as? UINavigationController { found.append(nav) }
            return found
        }
        return navigationControllers(contentHost).allSatisfy { $0.viewControllers.count <= 1 }
    }

    /// A pan inside a horizontally scrolled strip (special keys, code) scrolls it.
    private func touchIsInHorizontalScroller(_ point: CGPoint) -> Bool {
        var hit = view.hitTest(point, with: nil)
        while let current = hit, current !== view {
            if let scroll = current as? UIScrollView,
               scroll.contentSize.width > scroll.bounds.width + 1,
               scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 {
                return true
            }
            hit = current.superview
        }
        return false
    }

    static let sidebarBackground = UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .systemBackground
    }
}

/// Hosts the SwiftUI sidebar and main content in the UIKit container.
struct SidebarContainer<Sidebar: View, Content: View>: UIViewControllerRepresentable {
    let navigator: AppNavigator
    let sidebar: Sidebar
    let content: Content

    final class Coordinator {
        var sidebar: UIHostingController<Sidebar>?
        var content: UIHostingController<Content>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> SidebarContainerController {
        let sidebarHost = UIHostingController(rootView: sidebar)
        let contentHost = UIHostingController(rootView: content)
        context.coordinator.sidebar = sidebarHost
        context.coordinator.content = contentHost
        let container = SidebarContainerController(sidebar: sidebarHost, content: contentHost)
        container.onOpenChange = { [navigator] open in navigator.sidebarOpen = open }
        navigator.container = container
        return container
    }

    func updateUIViewController(_ controller: SidebarContainerController, context: Context) {
        context.coordinator.sidebar?.rootView = sidebar
        context.coordinator.content?.rootView = content
        navigator.container = controller
    }
}
