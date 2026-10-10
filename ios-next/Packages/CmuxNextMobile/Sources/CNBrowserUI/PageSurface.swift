#if os(iOS)
import CNCore
import SwiftUI
import UIKit

/// The live page: draws the last streamed frame edge to edge under the status
/// bar, fills the strip above the page with the page's own top color, and
/// turns touches, hardware keys and soft-keyboard text into remote input.
final class PageSurfaceView: UIView, UIGestureRecognizerDelegate {
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
    /// Where Chrome's viewport is on screen; touches map through this rect.
    /// Frames are drawn exactly as streamed (no local scroll prediction).
    private var imageRect: CGRect = .zero
    /// Remote page zoom of the shown frame (1 = minimum for mobile pages).
    private var shownPageScale: CGFloat = 1
    /// A pinch-in at the page's minimum zoom became the tab-overview pinch:
    /// its touches no longer go to the page.
    private var pinchTakenOver = false
    /// Touches of a taken-over pinch stay away from the page until all fingers lift.
    private var suppressTouches = false
    /// Pinch handed to the overview: (phase, scale, velocity).
    var onOverviewPinch: ((PinchPhase, CGFloat, CGFloat) -> Void)?
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

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delaysTouchesEnded = false
        pinch.delegate = self
        addGestureRecognizer(pinch)

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
        shownPageScale = frame.pageScale
        imageLayer.contents = frame.image
        strip.backgroundColor = frame.topColor
        backgroundColor = frame.topColor
        updateFade(frame.topColor)
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
        imageLayer.frame = imageRect
        CATransaction.commit()
    }

    // MARK: Touches

    /// View point -> CSS px in Chrome's viewport, through the image rect and
    /// the frame's CSS size.
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
        if touchIds.count > 1 { primaryTouch = nil }
        guard !suppressTouches else { return }
        onTouch?(.start, points(active(event)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let primary = primaryTouch, let t = touches.first(where: { ObjectIdentifier($0) == primary }) {
            let now = t.location(in: self)
            if let last = touchLocations[primary] { onDrag?(now.y - last.y) }
        }
        for t in touches { touchLocations[ObjectIdentifier(t)] = t.location(in: self) }
        guard !suppressTouches else { return }
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
        if !suppressTouches { onTouch?(type, points(touches)) }
        for t in touches {
            let key = ObjectIdentifier(t)
            touchIds[key] = nil
            touchLocations[key] = nil
            if primaryTouch == key { primaryTouch = nil }
        }
        if touchIds.isEmpty {
            primaryTouch = nil
            suppressTouches = false
        }
    }

    // MARK: Pinch to the tab overview

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            if !pinchTakenOver {
                // Only a pinch-in on a page that cannot zoom out further
                // (mobile pages at scale 1) belongs to the overview.
                guard g.scale < 0.94, shownPageScale <= 1.02, onOverviewPinch != nil else { return }
                pinchTakenOver = true
                suppressTouches = true
                onTouch?(.cancel, [])
            }
            onOverviewPinch?(.changed, g.scale / 0.94, g.velocity)
        case .ended, .cancelled, .failed:
            if pinchTakenOver {
                onOverviewPinch?(.ended, g.scale / 0.94, g.velocity)
                pinchTakenOver = false
            }
        default:
            break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

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
    var onOverviewPinch: ((PinchPhase, CGFloat, CGFloat) -> Void)? = nil

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
        view.onOverviewPinch = onOverviewPinch
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
