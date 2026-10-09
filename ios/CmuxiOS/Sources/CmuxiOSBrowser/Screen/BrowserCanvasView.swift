import CmuxiOSBrowserCore
import CmuxiOSFeatureKit
import UIKit

/// The page surface: the video plus the touch mapping of
/// c2-browser-stream.md section 4. One-finger drags scroll the page with
/// native UIScrollView mechanics (phases and momentum from UIKit, no
/// timers); taps click with a rising click count; long press is a
/// secondary click; pinch and two-finger pan move the local zoom lens.
@MainActor
final class BrowserCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    let videoView = BrowserVideoView()
    var onInput: ((BrowserInput) -> Void)?
    var onTap: (() -> Void)?
    /// The zoom bucket changed at the end of a pinch.
    var onZoomBucket: ((Int) -> Void)?
    var cursor = "default" {
        didSet { if cursor != oldValue { pointer?.invalidate() } }
    }
    private var pointer: UIPointerInteraction?
    private let drag = UIPanGestureRecognizer()
    /// Device streams (simulators, c14-web.md 6): one-finger drags are touch
    /// drags (pointer down, moves, up) instead of wheel scrolling.
    var directTouch = false {
        didSet {
            mechanics.isScrollEnabled = !directTouch
            drag.isEnabled = directTouch
        }
    }

    private(set) var lens = BrowserViewportTransform(viewSize: .zero, pageSize: CGSize(width: 1, height: 1))
    private let mechanics = UIScrollView()
    private var lastOffset = CGPoint.zero
    private var recentering = false
    private var anchor = CGPoint.zero
    private var phases = BrowserScrollPhaseReducer()
    private var clicks = BrowserTapClickCounter()
    private var pinchStartZoom: CGFloat = 1
    private var pinchLastLocation = CGPoint.zero
    private static let travel: CGFloat = 1_000_000

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        addSubview(videoView)
        mechanics.backgroundColor = .clear
        mechanics.showsVerticalScrollIndicator = false
        mechanics.showsHorizontalScrollIndicator = false
        mechanics.delaysContentTouches = false
        mechanics.scrollsToTop = false
        mechanics.contentInsetAdjustmentBehavior = .never
        mechanics.panGestureRecognizer.maximumNumberOfTouches = 1
        mechanics.delegate = self
        addSubview(mechanics)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        mechanics.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        mechanics.addGestureRecognizer(press)
        tap.require(toFail: press)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        mechanics.addGestureRecognizer(pinch)
        drag.addTarget(self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        drag.isEnabled = false
        mechanics.addGestureRecognizer(drag)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        mechanics.addGestureRecognizer(hover)
        let pointer = UIPointerInteraction(delegate: self)
        mechanics.addInteraction(pointer)
        self.pointer = pointer

        isAccessibilityElement = true
        accessibilityLabel = BrowserText.page
        accessibilityTraits = [.allowsDirectInteraction]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoView.frame = bounds
        mechanics.frame = bounds
        mechanics.contentSize = CGSize(width: Self.travel, height: Self.travel)
        if lastOffset == .zero { recenter() }
        lens = BrowserViewportTransform(viewSize: bounds.size, pageSize: lens.pageSize, zoom: lens.zoom,
                                             pan: lens.pan)
        videoView.setPageRect(lens.pageRect)
    }

    func setPageSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != lens.pageSize else { return }
        lens = BrowserViewportTransform(viewSize: bounds.size, pageSize: size, zoom: lens.zoom, pan: lens.pan)
        videoView.setPageRect(lens.pageRect)
    }

    // MARK: Scroll (one finger)

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        anchor = scrollView.panGestureRecognizer.location(in: self)
        emitWheel(.zero, phases.consume(.trackingBegan))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset
        defer { lastOffset = offset }
        guard !recentering else { return }
        let delta = CGPoint(x: offset.x - lastOffset.x, y: offset.y - lastOffset.y)
        guard delta != .zero else { return }
        let event: BrowserScrollPhaseReducer.Event = scrollView.isTracking ? .trackingChanged : .momentumChanged
        emitWheel(lens.pageDelta(fromView: delta), phases.consume(event))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        emitWheel(.zero, phases.consume(.trackingEnded(willDecelerate: decelerate)))
        if !decelerate { recenter() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        emitWheel(.zero, phases.consume(.momentumEnded))
        recenter()
    }

    private func emitWheel(_ delta: CGPoint, _ phases: (BrowserGesturePhase, BrowserGesturePhase)) {
        guard let point = lens.pagePoint(fromView: anchor) ?? lens.pagePoint(fromView: CGPoint(x: bounds.midX, y: bounds.midY))
        else { return }
        onInput?(.wheel(BrowserWheelEvent(x: point.x, y: point.y, dx: delta.x, dy: delta.y, phase: phases.0, momentumPhase: phases.1)))
    }

    private func recenter() {
        recentering = true
        let center = CGPoint(x: (Self.travel - bounds.width) / 2, y: (Self.travel - bounds.height) / 2)
        mechanics.setContentOffset(center, animated: false)
        lastOffset = center
        recentering = false
    }

    // MARK: Taps

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        guard let point = lens.pagePoint(fromView: location) else { return }
        let count = clicks.register(at: location, time: ProcessInfo.processInfo.systemUptime)
        onInput?(.pointer(BrowserPointerEvent(kind: .down, x: point.x, y: point.y, clickCount: count)))
        onInput?(.pointer(BrowserPointerEvent(kind: .up, x: point.x, y: point.y, clickCount: count)))
        onTap?()
    }

    @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let point = lens.pagePoint(fromView: recognizer.location(in: self)) else { return }
        onInput?(.pointer(BrowserPointerEvent(kind: .down, x: point.x, y: point.y, button: 2)))
        onInput?(.pointer(BrowserPointerEvent(kind: .up, x: point.x, y: point.y, button: 2)))
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard let point = lens.pagePoint(fromView: recognizer.location(in: self)) else { return }
        let kind: BrowserPointerEvent.Kind
        switch recognizer.state {
        case .began: kind = .down
        case .changed: kind = .move
        case .ended, .cancelled, .failed: kind = .up
        default: return
        }
        onInput?(.pointer(BrowserPointerEvent(kind: kind, x: point.x, y: point.y, clickCount: kind == .move ? 0 : 1)))
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .changed || recognizer.state == .began,
              let point = lens.pagePoint(fromView: recognizer.location(in: self)) else { return }
        onInput?(.pointer(BrowserPointerEvent(kind: .move, x: point.x, y: point.y, clickCount: 0, pointerType: "mouse")))
    }

    // MARK: Zoom lens (pinch, two-finger pan)

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            pinchStartZoom = lens.zoom
            pinchLastLocation = location
        case .changed:
            let moved = CGPoint(x: location.x - pinchLastLocation.x, y: location.y - pinchLastLocation.y)
            lens = lens.zoomed(to: pinchStartZoom * recognizer.scale, around: location).panned(by: moved)
            pinchLastLocation = location
            videoView.setPageRect(lens.pageRect)
        case .ended, .cancelled:
            let before = pinchStartZoom > 1.5 ? 2 : 1
            if lens.zoomBucket != before { onZoomBucket?(lens.zoomBucket) }
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    // MARK: Pointer (iPad)

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        cursor == "text" ? UIPointerStyle(shape: .verticalBeam(length: 22), constrainedAxes: []) : nil
    }
}
