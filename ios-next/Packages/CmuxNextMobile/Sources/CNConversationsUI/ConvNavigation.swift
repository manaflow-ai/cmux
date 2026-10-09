#if os(iOS)
import CNCore
import CNDesign
import UIKit

/// A screen whose header items stay fixed during push and pop and cross-fade
/// instead of sliding (iOS 26 glass bar behaviour, reference §3).
@MainActor
protocol ConvTransitionHeader: AnyObject {
    /// Views kept in place (counter-translated) and faded during transitions.
    var transitionHeaderViews: [UIView] { get }
}

@MainActor
final class ConvNavigationController: UINavigationController, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    private(set) var store: ConversationsStore
    let list: ConversationListViewController
    private var interactive: ConvTransition?
    private lazy var backPan = UIPanGestureRecognizer(target: self, action: #selector(handleBackPan(_:)))

    init(store: ConversationsStore) {
        self.store = store
        self.list = ConversationListViewController(store: store)
        super.init(nibName: nil, bundle: nil)
        viewControllers = [list]
        setNavigationBarHidden(true, animated: false)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func replaceStore(_ newStore: ConversationsStore) {
        store.stop()
        store = newStore
        newStore.start()
        popToRootViewController(animated: false)
        list.setStore(newStore)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.isEnabled = false
        interactiveContentPopGestureRecognizer?.isEnabled = false
        backPan.delegate = self
        backPan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(backPan)
    }

    private var handledRoute: UUID?
    private var pendingRoute: CNShellRoute?

    /// Opens what the shell asked for (a drawer row or its compose button).
    func handle(_ route: CNShellRoute?) {
        guard let route, route.nonce != handledRoute else { return }
        switch route.kind {
        case .conversation:
            guard let id = route.id else { handledRoute = route.nonce; return }
            guard store.conversation(id) != nil else { pendingRoute = route; return }
            handledRoute = route.nonce
            popToRootViewController(animated: false)
            openThread(id)
        case .compose:
            guard let chief = store.sorted.first(where: { $0.kind == .chief }) ?? store.sorted.first else { pendingRoute = route; return }
            handledRoute = route.nonce
            popToRootViewController(animated: false)
            openThread(chief.id, focusComposer: true)
        default:
            handledRoute = route.nonce
        }
    }

    /// Retries a route that arrived before the list loaded.
    func retryPendingRoute() {
        guard let r = pendingRoute else { return }
        pendingRoute = nil
        handle(r)
    }

    func openThread(_ conversationId: String, focusComposer: Bool = false, animated: Bool = true) {
        guard let c = store.conversation(conversationId) else { return }
        let thread = ThreadViewController(store: store, conversation: c)
        thread.focusComposerOnAppear = focusComposer
        pushViewController(thread, animated: animated)
    }

    // MARK: Interactive back

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === backPan, viewControllers.count > 1, transitionCoordinator == nil else { return false }
        if let thread = topViewController as? ThreadViewController, thread.blocksBackGesture { return false }
        let v = backPan.velocity(in: view)
        return v.x > 0 && v.x > abs(v.y) * 1.2
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === backPan && other is UIPanGestureRecognizer && other.view is UIScrollView
    }

    @objc private func handleBackPan(_ g: UIPanGestureRecognizer) {
        let w = max(view.bounds.width, 1)
        switch g.state {
        case .began:
            // Stop the transcript from scrolling under the finger.
            for case let s as UIScrollView in (topViewController?.view.subviews ?? []) {
                s.panGestureRecognizer.isEnabled = false
                s.panGestureRecognizer.isEnabled = true
            }
            interactive = ConvTransition(operation: .pop, interactive: true)
            popViewController(animated: true)
        case .changed:
            interactive?.update(fraction: g.translation(in: view).x / w)
        case .ended, .cancelled, .failed:
            let fraction = g.translation(in: view).x / w
            let velocity = g.state == .ended ? g.velocity(in: view).x / w : -1
            interactive?.end(fraction: fraction, velocity: velocity)
            interactive = nil
        default:
            break
        }
    }

    // MARK: UINavigationControllerDelegate

    func navigationController(_ nav: UINavigationController, animationControllerFor operation: UINavigationController.Operation,
                              from fromVC: UIViewController, to toVC: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        switch operation {
        case .push: return ConvTransition(operation: .push, interactive: false)
        case .pop: return interactive ?? ConvTransition(operation: .pop, interactive: false)
        default: return nil
        }
    }

    func navigationController(_ nav: UINavigationController,
                              interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning) -> (any UIViewControllerInteractiveTransitioning)? {
        guard let t = animationController as? ConvTransition, t.isInteractive else { return nil }
        return t
    }
}

/// Push and pop between the list and a thread, measured from Messages:
/// critically damped springs (0.28 s push, 0.27 s pop), the list parallaxes
/// by 30% of the width and dims by 10%, and header items hold ~100 ms then
/// cross-fade over ~60 ms without translating.
@MainActor
final class ConvTransition: NSObject, UIViewControllerAnimatedTransitioning, UIViewControllerInteractiveTransitioning {
    enum Operation { case push, pop }

    let operation: Operation
    let isInteractive: Bool
    var wantsInteractiveStart: Bool { isInteractive }

    private var context: (any UIViewControllerContextTransitioning)?
    private weak var listView: UIView?
    private weak var threadView: UIView?
    private var listHeaders: [UIView] = []
    private var threadHeaders: [UIView] = []
    private let dim = UIView()
    private let shadow = ConvEdgeShadow()
    private var width: CGFloat = 402
    private var driver: SpringDriver?
    private var fade: TimedDriver?
    private var presence: CGFloat = 0
    private var pendingFraction: CGFloat?
    private var pendingEnd: (CGFloat, CGFloat)?

    init(operation: Operation, interactive: Bool) {
        self.operation = operation
        self.isInteractive = interactive
    }

    nonisolated func transitionDuration(using ctx: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0.35 }

    nonisolated func animateTransition(using ctx: any UIViewControllerContextTransitioning) {
        MainActor.assumeIsolated {
            setUp(ctx)
            run(to: operation == .push ? 1 : 0, velocity: 0)
        }
    }

    nonisolated func startInteractiveTransition(_ ctx: any UIViewControllerContextTransitioning) {
        MainActor.assumeIsolated {
            setUp(ctx)
            if let f = pendingFraction { update(fraction: f) }
            if let (f, v) = pendingEnd { end(fraction: f, velocity: v) }
        }
    }

    private func setUp(_ ctx: any UIViewControllerContextTransitioning) {
        context = ctx
        let container = ctx.containerView
        guard let fromVC = ctx.viewController(forKey: .from), let toVC = ctx.viewController(forKey: .to),
              let fromView = ctx.view(forKey: .from) ?? fromVC.view, let toView = ctx.view(forKey: .to) ?? toVC.view else { return }
        width = container.bounds.width
        toView.frame = ctx.finalFrame(for: toVC)
        let listVC = operation == .push ? fromVC : toVC
        let threadVC = operation == .push ? toVC : fromVC
        let list = operation == .push ? fromView : toView
        let thread = operation == .push ? toView : fromView
        if operation == .push { container.addSubview(toView) } else { container.insertSubview(toView, belowSubview: fromView) }
        listView = list
        threadView = thread
        dim.backgroundColor = .black
        dim.frame = container.bounds
        dim.isUserInteractionEnabled = false
        container.insertSubview(dim, aboveSubview: list)
        shadow.frame = CGRect(x: -20, y: 0, width: 20, height: container.bounds.height)
        thread.addSubview(shadow)
        listHeaders = (listVC as? ConvTransitionHeader)?.transitionHeaderViews ?? []
        threadHeaders = (threadVC as? ConvTransitionHeader)?.transitionHeaderViews ?? []
        presence = operation == .push ? 0 : 1
        thread.layoutIfNeeded()
        apply(presence)
        if !isInteractive { startHeaderFade() } else { applyInteractiveHeaders(presence) }
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    private func apply(_ q: CGFloat) {
        presence = q
        let w = width
        if reduceMotion {
            threadView?.transform = .identity
            threadView?.alpha = q
            listView?.transform = .identity
        } else {
            threadView?.transform = CGAffineTransform(translationX: w * (1 - q), y: 0)
            listView?.transform = CGAffineTransform(translationX: -0.3 * w * q, y: 0)
        }
        dim.alpha = 0.10 * q
        shadow.alpha = q > 0.999 ? 0 : 1
        let threadCounter = reduceMotion ? 0 : -w * (1 - q)
        for h in threadHeaders { h.transform = CGAffineTransform(translationX: threadCounter, y: 0) }
        let listCounter = reduceMotion ? 0 : 0.3 * w * q
        for h in listHeaders { h.transform = CGAffineTransform(translationX: listCounter, y: 0) }
        if isInteractive { applyInteractiveHeaders(q) }
    }

    private func applyInteractiveHeaders(_ q: CGFloat) {
        let t = clamp01((q - 0.35) / 0.3)
        for h in threadHeaders { h.alpha = t }
        for h in listHeaders { h.alpha = 1 - t }
    }

    /// Hold ~100 ms, then cross-fade over ~60 ms (reference §3 nav bar morph).
    private func startHeaderFade() {
        let showingThread = operation == .push
        for h in threadHeaders { h.alpha = showingThread ? 0 : 1 }
        for h in listHeaders { h.alpha = showingThread ? 1 : 0 }
        let threadHeaders = self.threadHeaders, listHeaders = self.listHeaders
        fade = TimedDriver(duration: 0.16) { p in
            let t = clamp01((p * 0.16 - 0.10) / 0.06)
            let threadAlpha = showingThread ? t : 1 - t
            for h in threadHeaders { h.alpha = threadAlpha }
            for h in listHeaders { h.alpha = 1 - threadAlpha }
        }
        fade?.run()
    }

    func update(fraction: CGFloat) {
        guard let ctx = context else { pendingFraction = fraction; return }
        let f = clamp01(fraction)
        apply(1 - f)
        ctx.updateInteractiveTransition(f)
    }

    /// `velocity` is in widths per second, positive toward completing the pop.
    func end(fraction: CGFloat, velocity: CGFloat) {
        guard let ctx = context else { pendingEnd = (fraction, velocity); return }
        // The last touch can arrive with .ended only; land on it first.
        let f = clamp01(fraction)
        apply(1 - f)
        ctx.updateInteractiveTransition(f)
        let projected = fraction + velocity * 0.15
        let complete = velocity > 0.3 || (velocity > -0.3 && projected > 0.5)
        run(to: complete ? 0 : 1, velocity: -velocity)
    }

    private func run(to target: CGFloat, velocity: CGFloat) {
        let d = SpringDriver(value: presence, spring: operation == .push ? .push : .pop, label: operation == .push ? "push" : "pop") { [weak self] q in self?.apply(q) }
        driver = d
        if isInteractive {
            let threadHeaders = self.threadHeaders, listHeaders = self.listHeaders
            let startAlpha = threadHeaders.first?.alpha ?? 1
            let endAlpha: CGFloat = target == 1 ? 1 : 0
            fade = TimedDriver(duration: 0.06) { p in
                let a = lerp(startAlpha, endAlpha, p)
                for h in threadHeaders { h.alpha = a }
                for h in listHeaders { h.alpha = 1 - a }
            }
            fade?.run()
        }
        d.animate(to: target, velocity: velocity) { [weak self] _ in self?.finish(reached: target) }
    }

    private func finish(reached target: CGFloat) {
        guard let ctx = context else { return }
        let completed = operation == .push ? target == 1 : target == 0
        listView?.transform = .identity
        threadView?.transform = .identity
        threadView?.alpha = 1
        for h in threadHeaders { h.transform = .identity; h.alpha = 1 }
        for h in listHeaders { h.transform = .identity; h.alpha = 1 }
        dim.removeFromSuperview()
        shadow.removeFromSuperview()
        if isInteractive {
            if completed { ctx.finishInteractiveTransition() } else { ctx.cancelInteractiveTransition() }
        }
        ctx.completeTransition(completed)
        context = nil
    }

    nonisolated func animationEnded(_ transitionCompleted: Bool) {
        MainActor.assumeIsolated {
            fade?.cancel()
        }
    }
}

/// The soft ~20 pt shadow the thread page casts on the list while sliding.
final class ConvEdgeShadow: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let g = layer as! CAGradientLayer
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.06).cgColor]
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
#endif
