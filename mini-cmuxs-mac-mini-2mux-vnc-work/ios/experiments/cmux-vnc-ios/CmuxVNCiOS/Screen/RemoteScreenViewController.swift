import CmuxVNC
import UIKit

/// The remote screen: a zoomable view of the framebuffer, the local cursor,
/// touch gestures and keyboard input.
///
/// Trackpad mode: one finger moves the pointer (the view follows it when
/// zoomed), tap clicks, two-finger tap right-clicks, press-and-hold then
/// drag drags, two fingers scroll, pinch zooms.
/// Touch mode: taps click where the finger is, one finger pans a zoomed
/// view, press-and-hold then drag drags, two fingers scroll, pinch zooms.
final class RemoteScreenViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let session: RemoteSession
    var inputMode: InputMode = .trackpad {
        didSet { if inputMode != oldValue { applyInputMode() } }
    }

    private let scrollView = UIScrollView()
    private let content = UIView()
    private let screenLayer = CALayer()
    private let cursorLayer = CALayer()
    private var cursor = VNCCursor(width: 0, height: 0, hotspotX: 0, hotspotY: 0, pixels: [])
    private let keyInput = KeyInputView()
    private var frameSize = CGSize.zero
    private var lastPan = CGPoint.zero
    private var lastLongPress = CGPoint.zero
    private var scrollRemainder = CGPoint.zero
    /// Finger travel in points per wheel click.
    private let pointsPerScrollClick: CGFloat = 18
    /// Pointer speed in trackpad mode (framebuffer pixels per screen point, before zoom).
    private let trackpadSpeed: CGFloat = 1.6

    init(session: RemoteSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.delaysContentTouches = false
        view.addSubview(scrollView)
        scrollView.addSubview(content)
        screenLayer.magnificationFilter = .linear
        screenLayer.minificationFilter = .trilinear
        screenLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        content.layer.addSublayer(screenLayer)
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        cursorLayer.zPosition = 1
        cursorLayer.isHidden = true
        content.layer.addSublayer(cursorLayer)
        keyInput.session = session
        view.addSubview(keyInput)
        installGestures()
        applyInputMode()

        session.onFrame = { [weak self] frame in self?.show(frame) }
        session.onCursor = { [weak self] cursor in self?.setCursor(cursor) }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateZoomLimits(resetToFit: false)
    }

    // MARK: Frames

    private func show(_ frame: VNCFrame) {
        let size = CGSize(width: frame.width, height: frame.height)
        guard let image = frame.makeImage() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if size != frameSize {
            frameSize = size
            scrollView.zoomScale = 1
            content.frame = CGRect(origin: .zero, size: size)
            screenLayer.frame = content.bounds
            scrollView.contentSize = size
            updateZoomLimits(resetToFit: true)
        }
        screenLayer.contents = image
        CATransaction.commit()
        updateCursor()
    }

    private func setCursor(_ cursor: VNCCursor) {
        self.cursor = cursor
        cursorLayer.contents = cursor.makeImage()
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: cursor.width, height: cursor.height)
        updateCursor()
    }

    /// Draws the cursor at the pointer when the server sent a shape (local cursor).
    private func updateCursor() {
        let visible = session.preferences.localCursor && !cursor.isEmpty && frameSize != .zero
        cursorLayer.isHidden = !visible
        guard visible else { return }
        let pointer = session.pointer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = CGPoint(x: pointer.x - CGFloat(cursor.hotspotX) + CGFloat(cursor.width) / 2,
                                       y: pointer.y - CGFloat(cursor.hotspotY) + CGFloat(cursor.height) / 2)
        // Keep the cursor a readable size when zoomed out.
        let scale = max(1, 0.75 / max(scrollView.zoomScale, 0.01))
        cursorLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    // MARK: Zoom

    private func updateZoomLimits(resetToFit: Bool) {
        guard frameSize.width > 0, frameSize.height > 0, view.bounds.width > 0 else { return }
        let fit = min(view.bounds.width / frameSize.width, view.bounds.height / frameSize.height)
        let wasAtFit = abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = max(fit * 6, 2)
        if resetToFit || wasAtFit || scrollView.zoomScale < fit { scrollView.zoomScale = fit }
        centerContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateCursor()
    }

    /// Letterboxes the screen when it is smaller than the view.
    private func centerContent() {
        let width = content.frame.width, height = content.frame.height
        let insetX = max(0, (scrollView.bounds.width - width) / 2)
        let insetY = max(0, (scrollView.bounds.height - height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    /// Trackpad mode: scrolls a zoomed view so the pointer stays inside a margin.
    private func follow(_ pointer: CGPoint) {
        let zoom = scrollView.zoomScale
        let point = CGPoint(x: pointer.x * zoom, y: pointer.y * zoom)
        let margin: CGFloat = 60
        var offset = scrollView.contentOffset
        let visible = CGRect(origin: offset, size: scrollView.bounds.size)
        if point.x < visible.minX + margin { offset.x = point.x - margin }
        if point.x > visible.maxX - margin { offset.x = point.x - visible.width + margin }
        if point.y < visible.minY + margin { offset.y = point.y - margin }
        if point.y > visible.maxY - margin { offset.y = point.y - visible.height + margin }
        let maxX = max(-scrollView.contentInset.left, scrollView.contentSize.width - visible.width + scrollView.contentInset.right)
        let maxY = max(-scrollView.contentInset.top, scrollView.contentSize.height - visible.height + scrollView.contentInset.bottom)
        offset.x = min(max(-scrollView.contentInset.left, offset.x), maxX)
        offset.y = min(max(-scrollView.contentInset.top, offset.y), maxY)
        if offset != scrollView.contentOffset { scrollView.setContentOffset(offset, animated: false) }
    }

    // MARK: Gestures

    private let trackpadPan = UIPanGestureRecognizer()
    private let longPress = UILongPressGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let twoFingerPan = UIPanGestureRecognizer()

    private func installGestures() {
        trackpadPan.addTarget(self, action: #selector(handleTrackpadPan(_:)))
        trackpadPan.maximumNumberOfTouches = 1
        longPress.addTarget(self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 12
        tap.addTarget(self, action: #selector(handleTap(_:)))
        twoFingerTap.addTarget(self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerPan.addTarget(self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        for recognizer in [trackpadPan, longPress, tap, twoFingerTap, twoFingerPan] as [UIGestureRecognizer] {
            recognizer.delegate = self
            scrollView.addGestureRecognizer(recognizer)
        }
        // Allow-scrolling vs dragging: a hold that becomes a drag wins over panning.
        trackpadPan.require(toFail: longPress)
        scrollView.panGestureRecognizer.require(toFail: longPress)
    }

    private func applyInputMode() {
        trackpadPan.isEnabled = inputMode == .trackpad
        scrollView.panGestureRecognizer.isEnabled = inputMode == .touch
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch zoom and two-finger scroll may run together.
        (gestureRecognizer == twoFingerPan && other == scrollView.pinchGestureRecognizer)
            || (other == twoFingerPan && gestureRecognizer == scrollView.pinchGestureRecognizer)
    }

    /// A touch location in framebuffer pixels.
    private func framebufferPoint(_ recognizer: UIGestureRecognizer) -> CGPoint {
        recognizer.location(in: content)
    }

    @objc private func handleTrackpadPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        if recognizer.state == .began { lastPan = .zero }
        let delta = CGPoint(x: translation.x - lastPan.x, y: translation.y - lastPan.y)
        lastPan = translation
        let scale = trackpadSpeed / max(scrollView.zoomScale, 0.01) * min(1, max(0.35, scrollView.zoomScale))
        session.movePointer(by: CGPoint(x: delta.x * scale, y: delta.y * scale))
        follow(session.pointer)
        updateCursor()
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if inputMode == .touch { session.movePointer(to: framebufferPoint(recognizer)) }
            lastLongPress = location
            session.press(.left, down: true)
        case .changed:
            if inputMode == .touch {
                session.movePointer(to: framebufferPoint(recognizer))
            } else {
                let scale = trackpadSpeed / max(scrollView.zoomScale, 0.01) * min(1, max(0.35, scrollView.zoomScale))
                session.movePointer(by: CGPoint(x: (location.x - lastLongPress.x) * scale, y: (location.y - lastLongPress.y) * scale))
                lastLongPress = location
                follow(session.pointer)
            }
        case .ended, .cancelled, .failed:
            session.press(.left, down: false)
        default:
            break
        }
        updateCursor()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        if inputMode == .touch { session.movePointer(to: framebufferPoint(recognizer)) }
        session.click(.left)
        updateCursor()
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        if inputMode == .touch { session.movePointer(to: framebufferPoint(recognizer)) }
        session.click(.right)
        updateCursor()
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let velocity = recognizer.translation(in: view)
        recognizer.setTranslation(.zero, in: view)
        if recognizer.state == .began { scrollRemainder = .zero }
        scrollRemainder.x += velocity.x
        scrollRemainder.y += velocity.y
        let clicksX = Int(scrollRemainder.x / pointsPerScrollClick), clicksY = Int(scrollRemainder.y / pointsPerScrollClick)
        scrollRemainder.x -= CGFloat(clicksX) * pointsPerScrollClick
        scrollRemainder.y -= CGFloat(clicksY) * pointsPerScrollClick
        // Natural scrolling: fingers moving down move the content down (wheel up).
        session.scroll(dx: clicksX, dy: clicksY)
    }

    // MARK: Keyboard

    var isKeyboardVisible: Bool {
        get { keyInput.isFirstResponder }
        set {
            if newValue { keyInput.becomeFirstResponder() } else { keyInput.resignFirstResponder(); becomeFirstResponder() }
        }
    }

    /// A hardware keyboard while the software keyboard is hidden.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keyInput.forward(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keyInput.forward(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keyInput.forward(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }
}
