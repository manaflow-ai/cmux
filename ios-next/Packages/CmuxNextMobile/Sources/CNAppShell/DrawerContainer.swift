#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// ChatGPT-style push-aside drawer geometry and motion.
struct DrawerSpec {
    /// Visible width of the content card when the drawer is open.
    var sliver: CGFloat = 64
    /// Dim on the content card at fully open.
    var maxDim: CGFloat = 0.3
    /// Release spring: SwiftUI-style response / damping fraction.
    var response: Double = 0.38
    var dampingFraction: Double = 0.9
    /// How far ahead the release velocity is projected (s), for the
    /// open-or-close decision.
    var projection: CGFloat = 0.18
    /// Reduce Motion: a short ease instead of the spring.
    var reducedDuration: TimeInterval = 0.2
}

/// Drawer state the SwiftUI side observes and drives.
@MainActor
@Observable
final class DrawerState {
    /// 0 closed ... 1 open, updated while dragging and animating.
    fileprivate(set) var progress: CGFloat = 0
    /// Settled state (true once open, false once closed).
    fileprivate(set) var isOpen = false
    @ObservationIgnored fileprivate weak var controller: DrawerContainerController?

    func open() { controller?.setOpen(true, animated: true, velocity: 0) }
    func close() { controller?.setOpen(false, animated: true, velocity: 0) }
    func toggle() { isOpen ? close() : open() }
}

/// Hosts the sidebar and the content card. The card follows the finger 1:1,
/// then settles with a velocity-matched spring; the sidebar moves with it.
struct DrawerContainer<Sidebar: View, Content: View>: UIViewControllerRepresentable {
    let state: DrawerState
    var spec = DrawerSpec()
    let sidebar: Sidebar
    let content: Content

    func makeUIViewController(context: Context) -> DrawerContainerController {
        let controller = DrawerContainerController(
            spec: spec,
            sidebar: UIHostingController(rootView: AnyView(sidebar)),
            content: UIHostingController(rootView: AnyView(content))
        )
        controller.state = state
        state.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: DrawerContainerController, context: Context) {
        (controller.sidebar as? UIHostingController<AnyView>)?.rootView = AnyView(sidebar)
        (controller.content as? UIHostingController<AnyView>)?.rootView = AnyView(content)
    }
}

final class DrawerContainerController: UIViewController, UIGestureRecognizerDelegate {
    let spec: DrawerSpec
    let sidebar: UIViewController
    let content: UIViewController
    weak var state: DrawerState?

    private let cardView = UIView()
    private let dimView = UIView()
    private let edgeLine = UIView()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    private var animator: UIViewPropertyAnimator?
    /// Card x at rest or under the finger (the model value, not presentation).
    private var cardX: CGFloat = 0
    private var dragStartX: CGFloat = 0
    private var targetOpen = false

    init(spec: DrawerSpec, sidebar: UIViewController, content: UIViewController) {
        self.spec = spec
        self.sidebar = sidebar
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private var openX: CGFloat { max(0, view.bounds.width - spec.sliver) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true

        addChild(sidebar)
        view.addSubview(sidebar.view)
        sidebar.didMove(toParent: self)
        sidebar.view.backgroundColor = .clear

        cardView.clipsToBounds = true
        view.addSubview(cardView)
        addChild(content)
        cardView.addSubview(content.view)
        content.didMove(toParent: self)

        edgeLine.backgroundColor = .separator
        edgeLine.alpha = 0
        cardView.addSubview(edgeLine)

        dimView.backgroundColor = .black
        dimView.alpha = 0
        dimView.isUserInteractionEnabled = false
        dimView.accessibilityLabel = "Close sidebar"
        dimView.accessibilityTraits = .button
        cardView.addSubview(dimView)

        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        tap.delegate = self
        dimView.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if animator == nil, pan.state != .changed {
            cardX = targetOpen ? openX : 0
            applyLayout(cardX)
        }
    }

    // MARK: Layout

    private func applyLayout(_ x: CGFloat) {
        let bounds = view.bounds
        let width = openX
        let progress = width > 0 ? min(max(x / width, 0), 1) : 0
        cardView.frame = CGRect(x: x, y: 0, width: bounds.width, height: bounds.height)
        content.view.frame = cardView.bounds
        dimView.frame = cardView.bounds
        edgeLine.frame = CGRect(x: 0, y: 0, width: 1 / max(1, traitCollection.displayScale), height: bounds.height)
        dimView.alpha = spec.maxDim * progress
        edgeLine.alpha = progress > 0 ? 1 : 0
        sidebar.view.frame = CGRect(x: x - width, y: 0, width: width, height: bounds.height)
    }

    private func report(_ x: CGFloat) {
        let width = openX
        state?.progress = width > 0 ? min(max(x / width, 0), 1) : 0
    }

    // MARK: Open / close

    func setOpen(_ open: Bool, animated: Bool, velocity: CGFloat) {
        let from = currentPresentationX()
        animator?.stopAnimation(true)
        animator = nil
        targetOpen = open
        let to = open ? openX : 0
        dimView.isUserInteractionEnabled = open
        if open { view.endEditing(true) }
        guard animated, view.window != nil else {
            settle(at: to, open: open)
            return
        }
        applyLayout(from)
        let animator: UIViewPropertyAnimator
        if UIAccessibility.isReduceMotionEnabled {
            animator = UIViewPropertyAnimator(duration: spec.reducedDuration, curve: .easeOut)
        } else {
            let distance = to - from
            let relative = abs(distance) > 0.5 ? velocity / distance : 0
            let stiffness = pow(2 * .pi / spec.response, 2)
            let damping = 4 * .pi * spec.dampingFraction / spec.response
            let timing = UISpringTimingParameters(mass: 1, stiffness: stiffness, damping: damping,
                                                  initialVelocity: CGVector(dx: relative, dy: 0))
            animator = UIViewPropertyAnimator(duration: 0, timingParameters: timing)
        }
        animator.addAnimations { [weak self] in self?.applyLayout(to) }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end else { return }
            self.animator = nil
            self.settle(at: to, open: open)
        }
        self.animator = animator
        cardX = to
        state?.progress = open ? 1 : 0
        state?.isOpen = open
        animator.startAnimation()
    }

    private func settle(at x: CGFloat, open: Bool) {
        cardX = x
        applyLayout(x)
        report(x)
        state?.isOpen = open
        UIAccessibility.post(notification: .screenChanged, argument: open ? sidebar.view : content.view)
    }

    private func currentPresentationX() -> CGFloat {
        if animator != nil, let presented = cardView.layer.presentation() {
            return presented.frame.minX
        }
        return cardView.frame.minX
    }

    // MARK: Gestures

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        setOpen(false, animated: true, velocity: 0)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            let x = currentPresentationX()
            animator?.stopAnimation(true)
            animator = nil
            dragStartX = x
            cardX = x
            applyLayout(x)
            view.endEditing(true)
        case .changed:
            let x = min(max(dragStartX + recognizer.translation(in: view).x, 0), openX)
            cardX = x
            applyLayout(x)
            report(x)
        case .ended, .cancelled, .failed:
            let velocity = recognizer.state == .ended ? recognizer.velocity(in: view).x : 0
            let projected = cardX + velocity * spec.projection
            let open = projected > openX / 2
            setOpen(open, animated: true, velocity: velocity)
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === tap { return targetOpen }
        guard recognizer === pan else { return true }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
        if targetOpen || animator != nil { return true }
        guard velocity.x > 0 else { return false }
        let point = pan.location(in: view)
        guard let hit = view.hitTest(point, with: nil) else { return true }
        return !Self.contentClaimsRightSwipe(from: hit, in: view)
    }

    /// Vertical scrollers wait for the drawer pan to fail, so a horizontal
    /// swipe on a list opens the drawer instead of jittering the list.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard recognizer === pan, let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer else { return false }
        return !Self.scrollsHorizontally(scroll)
    }

    /// True when something under the finger should own a rightward swipe: a
    /// horizontal scroller that can scroll back, a slider/switch, or a
    /// navigation stack that can pop (its back swipe wins).
    static func contentClaimsRightSwipe(from hit: UIView, in root: UIView) -> Bool {
        var responder: UIResponder? = hit
        while let current = responder, current !== root {
            if let scroll = current as? UIScrollView, scrollsHorizontally(scroll),
               scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5 {
                return true
            }
            if current is UISlider || current is UISwitch { return true }
            if let nav = current as? UINavigationController, nav.viewControllers.count > 1 { return true }
            responder = current.next
        }
        return false
    }

    static func scrollsHorizontally(_ scroll: UIScrollView) -> Bool {
        let inset = scroll.adjustedContentInset
        return scroll.isScrollEnabled && scroll.contentSize.width + inset.left + inset.right > scroll.bounds.width + 0.5
    }
}
#endif
