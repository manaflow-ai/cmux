#if os(iOS)
import CNCore
import SwiftUI
import UIKit

/// The live page: draws the last streamed frame edge to edge under the status
/// bar, fills the strip above the page with the page's own top color, and
/// turns touches, hardware keys and soft-keyboard text into remote input.
final class PageSurfaceView: UIView {
    var onTouch: ((TouchEventType, [TouchPoint]) -> Void)?
    /// Finger travel of a one-finger drag, in points (positive = finger moved down).
    var onDrag: ((CGFloat) -> Void)?
    var onKey: ((DOMKey) -> Void)?
    var onText: ((String) -> Void)?
    var onKeyboardDismissed: (() -> Void)?

    private let strip = UIView()
    private let stripFade = CAGradientLayer()
    private let imageLayer = CALayer()
    let proxy = KeyProxyField()

    private var touchIds: [ObjectIdentifier: Int] = [:]
    private var touchLocations: [ObjectIdentifier: CGPoint] = [:]
    private var nextTouchId = 1
    private var primaryTouch: ObjectIdentifier?

    private(set) var frameCSS: CGSize?
    private var shownImage: CGImage?
    /// Document scroll (CSS px) of the shown frame, when the host sends it.
    private var shownScroll: CGFloat?
    /// Image rect without the local scroll prediction: where Chrome's
    /// viewport is on screen. Touches map through this rect.
    private var imageRect: CGRect = .zero
    private var prediction = ScrollPrediction()
    var topInset: CGFloat = 0 { didSet { if oldValue != topInset { setNeedsLayout() } } }
    /// CSS width of the requested viewport, used before the first frame.
    var viewportCSSWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        backgroundColor = .systemBackground
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(imageLayer)
        strip.isUserInteractionEnabled = false
        stripFade.actions = ["colors": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(stripFade)
        addSubview(strip)
        proxy.frame = CGRect(x: -10, y: -10, width: 1, height: 1)
        proxy.alpha = 0.01
        addSubview(proxy)
        proxy.onText = { [weak self] in self?.onText?($0) }
        proxy.onKey = { [weak self] in self?.onKey?($0) }
        proxy.onEnd = { [weak self] in self?.onKeyboardDismissed?() }

        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        long.cancelsTouchesInView = false
        long.delaysTouchesBegan = false
        long.delaysTouchesEnded = false
        addGestureRecognizer(long)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Frames

    func show(_ frame: PageFrame?) {
        guard let frame else {
            imageLayer.contents = nil
            shownImage = nil
            frameCSS = nil
            strip.backgroundColor = .systemBackground
            updateFade(.systemBackground)
            setNeedsLayout()
            return
        }
        guard frame.image !== shownImage || frameCSS != frame.cssSize else { return }
        let resized = frameCSS != nil && frameCSS != frame.cssSize
        shownImage = frame.image
        frameCSS = frame.cssSize
        shownScroll = frame.scroll.map { $0.y }
        prediction.frameArrived(scroll: shownScroll, cssPerPoint: cssPerPoint)
        imageLayer.contents = frame.image
        strip.backgroundColor = frame.topColor
        backgroundColor = frame.topColor
        updateFade(frame.topColor)
        if prediction.consumeExpired(now: CACurrentMediaTime()) { applyPrediction(animated: true) }
        if resized {
            // Smooth the jump when the host renders at a new CSS size.
            UIView.animate(withDuration: 0.2) { self.layoutImage(animated: true) }
        } else {
            setNeedsLayout()
        }
    }

    private func updateFade(_ color: UIColor) {
        stripFade.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
    }

    /// CSS px per point (the image is drawn at the view's full width).
    private var cssPerPoint: CGFloat {
        let w = frameCSS?.width ?? (viewportCSSWidth > 0 ? viewportCSSWidth : bounds.width)
        return bounds.width > 0 ? w / bounds.width : 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topInset)
        // Soft seam: the page-colored strip fades into the page over 6 pt
        // (Safari's scroll-edge tint toward the page background).
        stripFade.frame = CGRect(x: 0, y: topInset - 1, width: bounds.width, height: 7)
        layoutImage(animated: false)
    }

    private func layoutImage(animated: Bool) {
        // Chrome's viewport starts right under the status-bar strip and is
        // exactly the frame's CSS size scaled to the view's width.
        if let css = frameCSS, css.width > 0 {
            imageRect = CGRect(x: 0, y: topInset, width: bounds.width, height: bounds.width * css.height / css.width)
        } else {
            imageRect = CGRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.2) }
        imageLayer.frame = imageRect.offsetBy(dx: 0, dy: prediction.offset)
        CATransaction.commit()
    }

    /// Moves the image by the predicted scroll (no relayout).
    private func applyPrediction(animated: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.15)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        imageLayer.frame = imageRect.offsetBy(dx: 0, dy: prediction.offset)
        CATransaction.commit()
    }

    // MARK: Touches

    /// View point -> CSS px in Chrome's viewport, through the unpredicted
    /// image rect and the frame's CSS size. When the prediction is right the
    /// content under the finger is where Chrome has it.
    private func cssPoint(_ p: CGPoint) -> (Double, Double) {
        let css = frameCSS ?? CGSize(width: bounds.width * cssPerPoint, height: imageRect.height * cssPerPoint)
        guard imageRect.width > 0, imageRect.height > 0 else { return (0, 0) }
        let x = (p.x - imageRect.minX) / imageRect.width * css.width
        let y = (p.y - imageRect.minY) / imageRect.height * css.height
        return (Double(min(max(0, x), css.width)), Double(min(max(0, y), css.height)))
    }

    private func points(_ touches: some Sequence<UITouch>) -> [TouchPoint] {
        touches.compactMap { t in
            guard let id = touchIds[ObjectIdentifier(t)] else { return nil }
            let (x, y) = cssPoint(t.location(in: self))
            return TouchPoint(x: x, y: y, id: id)
        }
    }

    private func active(_ event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter { touchIds[ObjectIdentifier($0)] != nil && $0.phase != .ended && $0.phase != .cancelled }
            .sorted { touchIds[ObjectIdentifier($0)]! < touchIds[ObjectIdentifier($1)]! }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let key = ObjectIdentifier(t)
            touchIds[key] = nextTouchId
            nextTouchId += 1
            touchLocations[key] = t.location(in: self)
            if primaryTouch == nil { primaryTouch = key }
        }
        if touchIds.count > 1 {
            primaryTouch = nil
            prediction.cancel()
            applyPrediction(animated: true)
        } else {
            prediction.begin(shownScroll: shownScroll)
        }
        onTouch?(.start, points(active(event)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let primary = primaryTouch, let t = touches.first(where: { ObjectIdentifier($0) == primary }) {
            let now = t.location(in: self)
            if let last = touchLocations[primary] {
                onDrag?(now.y - last.y)
                prediction.drag(dy: now.y - last.y, cssPerPoint: cssPerPoint, limit: bounds.height * 0.75)
                applyPrediction()
            }
        }
        for t in touches { touchLocations[ObjectIdentifier(t)] = t.location(in: self) }
        onTouch?(.move, points(active(event)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, type: .end)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, type: .cancel)
    }

    private func finish(_ touches: Set<UITouch>, type: TouchEventType) {
        // CDP ends the whole sequence on touchEnd; send the lifted points so
        // hosts that track per-point state (the demo host) see where it ended.
        onTouch?(type, points(touches))
        if touches.contains(where: { ObjectIdentifier($0) == primaryTouch }) {
            prediction.release(now: CACurrentMediaTime())
            if type == .cancel {
                prediction.cancel()
                applyPrediction(animated: true)
            } else {
                // Frames stop when the page cannot scroll further (its end);
                // ease the offset back if none caught up in time.
                DispatchQueue.main.asyncAfter(deadline: .now() + ScrollPrediction.releaseTimeout + 0.05) { [weak self] in
                    guard let self, self.prediction.consumeExpired(now: CACurrentMediaTime()) else { return }
                    self.applyPrediction(animated: true)
                }
            }
        }
        for t in touches {
            let key = ObjectIdentifier(t)
            touchIds[key] = nil
            touchLocations[key] = nil
            if primaryTouch == key { primaryTouch = nil }
        }
        if touchIds.isEmpty { primaryTouch = nil }
    }

    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        // The remote page sees the held touch and opens its own context
        // menu; acknowledge the press locally.
        if g.state == .began { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }

    // MARK: Hardware keys (surface is first responder when no field is)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let dom = DOMKey(key) { onKey?(dom); handled = true }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}

/// Local scroll prediction for one-finger drags. Frames arrive a round trip
/// late, so while dragging the last frame is moved with the finger and each
/// new frame is placed where the page should be by now.
///
/// With scroll metadata (`frameMeta`), the page is expected at
/// `scrollAtStart - fingerTravel`; a frame captured at scroll S is drawn
/// offset by (S - expected) / cssPerPoint. After the finger lifts, the offset
/// is kept until a frame reaches the expected scroll (Chrome may fling past
/// it) or `releaseTimeout` passes. Without metadata, the offset is the finger
/// travel since the last frame (dead reckoning), reset by each frame.
struct ScrollPrediction {
    static let releaseTimeout: CFTimeInterval = 0.6

    private(set) var offset: CGFloat = 0
    private var active = false
    private var released: CFTimeInterval?
    private var baseScroll: CGFloat?
    private var fingerTravel: CGFloat = 0
    private var shownScroll: CGFloat?
    private var sinceFrame: CGFloat = 0
    private var limit: CGFloat = 600

    mutating func begin(shownScroll: CGFloat?) {
        active = true
        released = nil
        baseScroll = shownScroll
        self.shownScroll = shownScroll
        fingerTravel = 0
        sinceFrame = 0
        offset = 0
    }

    mutating func drag(dy: CGFloat, cssPerPoint k: CGFloat, limit: CGFloat) {
        guard active, released == nil else { return }
        self.limit = limit
        fingerTravel += dy
        sinceFrame += dy
        recompute(k: k)
    }

    mutating func release(now: CFTimeInterval) {
        guard active else { return }
        released = now
    }

    mutating func cancel() {
        active = false
        released = nil
        offset = 0
    }

    mutating func frameArrived(scroll: CGFloat?, cssPerPoint k: CGFloat) {
        guard active else { offset = 0; return }
        shownScroll = scroll
        sinceFrame = 0
        if released != nil {
            guard let expected = expectedScroll(k: k), let scroll else { cancel(); return }
            // Reached (or flung past) the finger's end position: frames are current.
            let direction: CGFloat = fingerTravel < 0 ? 1 : -1
            if (scroll - expected) * direction >= -0.5 { cancel(); return }
        }
        recompute(k: k)
    }

    /// Ends a prediction whose frames never caught up (page edge). Returns
    /// true when the offset changed.
    mutating func consumeExpired(now: CFTimeInterval) -> Bool {
        guard let released, now - released > Self.releaseTimeout, offset != 0 else { return false }
        cancel()
        return true
    }

    private func expectedScroll(k: CGFloat) -> CGFloat? {
        guard let baseScroll else { return nil }
        return max(0, baseScroll - fingerTravel * k)
    }

    private mutating func recompute(k: CGFloat) {
        let raw: CGFloat
        if let expected = expectedScroll(k: k), let shownScroll, k > 0 {
            raw = (shownScroll - expected) / k
        } else {
            raw = released == nil ? sinceFrame : 0
        }
        offset = min(limit, max(-limit, raw))
    }
}

/// Hidden text field that owns the software keyboard for remote text entry.
/// Typed text goes out as `browser.text`; Backspace, Enter and arrows go out
/// as `browser.key`. It never keeps text, so deleteBackward always fires.
final class KeyProxyField: UITextField, UITextFieldDelegate {
    var onText: ((String) -> Void)?
    var onKey: ((DOMKey) -> Void)?
    var onEnd: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardType = .default
        returnKeyType = .default
        delegate = self
        tintColor = .clear
        textColor = .clear
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func insertText(_ text: String) {
        if text == "\n" {
            onKey?(DOMKey(key: "Enter", code: "Enter", text: "\r", modifiers: 0))
        } else {
            onText?(text)
        }
    }

    override func deleteBackward() {
        onKey?(DOMKey(key: "Backspace", code: "Backspace", text: nil, modifiers: 0))
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onKey?(DOMKey(key: "Enter", code: "Enter", text: "\r", modifiers: 0))
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        onEnd?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let dom = DOMKey(key) else { rest.insert(press); continue }
            // Plain characters go through the text system (insertText); named
            // keys and shortcuts go straight to the page.
            if DOMKey.named[key.keyCode] != nil || dom.modifiers & (DOMKey.meta | DOMKey.ctrl) != 0 {
                onKey?(dom)
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }
}

/// SwiftUI host for `PageSurfaceView`.
struct PageSurface: UIViewRepresentable {
    let model: BrowserModel
    var frame: PageFrame?
    var topInset: CGFloat
    var viewportCSSWidth: CGFloat
    var keyboardActive: Bool
    var wantsHardwareKeys: Bool
    var onDrag: (CGFloat) -> Void
    var onKeyboardDismissed: () -> Void

    func makeUIView(context: Context) -> PageSurfaceView {
        let view = PageSurfaceView()
        view.onTouch = { [model] type, points in model.sendTouch(type, points: points) }
        view.onKey = { [model] in model.sendKey($0) }
        view.onText = { [model] in model.sendText($0) }
        return view
    }

    func updateUIView(_ view: PageSurfaceView, context: Context) {
        view.topInset = topInset
        view.viewportCSSWidth = viewportCSSWidth
        view.onDrag = onDrag
        view.onKeyboardDismissed = onKeyboardDismissed
        view.show(frame)
        if keyboardActive {
            if !view.proxy.isFirstResponder { view.proxy.becomeFirstResponder() }
        } else if view.proxy.isFirstResponder {
            view.proxy.resignFirstResponder()
        }
        if wantsHardwareKeys, !keyboardActive, view.window != nil, !view.isFirstResponder {
            DispatchQueue.main.async {
                // Only claim keys when nothing else (the address field) holds focus.
                if view.window != nil, !view.isFirstResponder, !view.proxy.isFirstResponder,
                   UIResponder.cnBrowserCurrentFirstResponder == nil {
                    view.becomeFirstResponder()
                }
            }
        }
    }
}

extension UIResponder {
    private nonisolated(unsafe) static weak var found: UIResponder?

    /// The current first responder, found with a nil-targeted action.
    @MainActor static var cnBrowserCurrentFirstResponder: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(cnBrowserCapture), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func cnBrowserCapture() { UIResponder.found = self }
}
#endif
