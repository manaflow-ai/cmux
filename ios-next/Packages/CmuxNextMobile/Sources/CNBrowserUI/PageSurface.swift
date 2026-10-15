#if os(iOS)
import CNCore
import CNDesign
import GameController
import SwiftUI
import UIKit

/// The live page: draws the last streamed frame edge to edge under the status
/// bar, fills the strip above the page with the page's own top color, and
/// turns touches, hardware keys and soft-keyboard text into remote input.
final class PageSurfaceView: UIView, UIGestureRecognizerDelegate {
    var onTouch: ((TouchEventType, [TouchPoint]) -> Void)?
    /// Finger travel of a one-finger drag, in points (positive = finger moved down).
    var onDrag: ((CGFloat) -> Void)?
    /// The touch sequence (and so any drag) ended.
    var onDragEnded: (() -> Void)?
    var onKey: ((DOMKey) -> Void)?
    var onText: ((String) -> Void)?
    var onKeyboardDismissed: (() -> Void)?
    /// A touch sequence started, and one ended as a tap (keyboard policy).
    var onTouchSequenceBegan: (() -> Void)?
    var onTap: (() -> Void)?

    private let strip = UIView()
    private let stripFade = CAGradientLayer()
    private let imageLayer = CALayer()
    let proxy = KeyProxyField()

    private var touchIds: [ObjectIdentifier: Int] = [:]
    private var touchLocations: [ObjectIdentifier: CGPoint] = [:]
    private var nextTouchId = 1
    private var primaryTouch: ObjectIdentifier?
    /// Where the current sequence's first touch went down, the farthest any
    /// touch of it travelled, and how far its primary finger moved down
    /// while the keyboard was up (tap detection and drag dismissal).
    private var sequenceStart: CGPoint?
    private var sequenceTravel: CGFloat = 0
    private var sequenceMulti = false

    private(set) var frameCSS: CGSize?
    private var shownImage: CGImage?
    /// Where Chrome's viewport is on screen; touches map through this rect.
    /// Frames are drawn exactly as streamed (no local scroll prediction).
    private var imageRect: CGRect = .zero
    /// Touches of a taken-over pinch stay away from the page until all fingers lift.
    private var suppressTouches = false

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
        // Keyboard plumbing only: the page's own accessibility comes from the
        // stream; an unlabeled 1 pt field must not show up as an element.
        proxy.isAccessibilityElement = false
        proxy.accessibilityElementsHidden = true
        addSubview(proxy)
        proxy.onText = { [weak self] in self?.onText?($0) }
        proxy.onKey = { [weak self] in self?.onKey?($0) }
        proxy.onEnd = { [weak self] in self?.onKeyboardDismissed?() }

        #if DEBUG && targetEnvironment(simulator)
        // DEBUG harness (as in the terminal): the headless simulator reports
        // a hardware keyboard; CMUX_NEXT_SOFTWARE_KEYBOARD=1 switches its
        // input modes to the software keyboard so page typing can be tested.
        if ProcessInfo.processInfo.environment["CMUX_NEXT_SOFTWARE_KEYBOARD"] == "1" {
            Self.softwareKeyboardHarness = true
            let selector = NSSelectorFromString("setHardwareLayout:")
            for mode in UITextInputMode.activeInputModes where mode.responds(to: selector) {
                mode.perform(selector, with: nil)
            }
        }
        #endif

        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        long.cancelsTouchesInView = false
        long.delaysTouchesBegan = false
        long.delaysTouchesEnded = false
        addGestureRecognizer(long)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    /// DEBUG harness on: the simulator still lists its hardware keyboard,
    /// but input behaves as if there were none.
    nonisolated(unsafe) static var softwareKeyboardHarness = false

    /// A hardware keyboard is attached (the surface then takes its keys).
    static var hardwareKeyboard: Bool { GCKeyboard.coalesced != nil && !softwareKeyboardHarness }

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
        if touchIds.isEmpty, let first = touches.first {
            sequenceStart = first.location(in: self)
            sequenceTravel = 0
            sequenceMulti = touches.count > 1
            onTouchSequenceBegan?()
        } else {
            sequenceMulti = true
        }
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
            if let last = touchLocations[primary] {
                onDrag?(now.y - last.y)
            }
            if let start = sequenceStart { sequenceTravel = max(sequenceTravel, hypot(now.x - start.x, now.y - start.y)) }
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

    /// The keyboard host's pan took over this one-finger touch (it cancels
    /// the surface's touches when it starts dragging): the page keeps
    /// getting the touch, now from the pan.
    private var panTouch: Int?

    private func finish(_ touches: Set<UITouch>, type: TouchEventType) {
        if type == .cancel, !suppressTouches, touchIds.count == 1, touches.count == 1,
           let host = superview as? PageKeyboardDismissHost, host.isTracking || host.isDragging,
           let t = touches.first, let id = touchIds[ObjectIdentifier(t)] {
            panTouch = id
            touchIds = [:]
            touchLocations = [:]
            primaryTouch = nil
            sequenceStart = nil
            return
        }
        // CDP ends the whole sequence on touchEnd; send the lifted points so
        // hosts that track per-point state (the demo host) see where it ended.
        if !suppressTouches { onTouch?(type, points(touches)) }
        if let start = sequenceStart, let t = touches.first {
            let p = t.location(in: self)
            sequenceTravel = max(sequenceTravel, hypot(p.x - start.x, p.y - start.y))
        }
        let sequenceEnds = touches.count >= touchIds.count
        for t in touches {
            let key = ObjectIdentifier(t)
            touchIds[key] = nil
            touchLocations[key] = nil
            if primaryTouch == key { primaryTouch = nil }
        }
        if touchIds.isEmpty {
            primaryTouch = nil
            onDragEnded?()
            if sequenceEnds, type == .end, !sequenceMulti, !suppressTouches,
               sequenceTravel < PageKeyboardPolicy.tapSlop { onTap?() }
            sequenceStart = nil
            suppressTouches = false
        }
    }

    func panMoved(to p: CGPoint) {
        guard let id = panTouch else { return }
        let (x, y) = cssPoint(p)
        onTouch?(.move, [TouchPoint(x: x, y: y, id: id)])
    }

    func panEnded(at p: CGPoint, cancelled: Bool) {
        guard let id = panTouch else { return }
        panTouch = nil
        onDragEnded?()
        let (x, y) = cssPoint(p)
        onTouch?(cancelled ? .cancel : .end, [TouchPoint(x: x, y: y, id: id)])
    }

    // MARK: Zoom pinch

    /// The screen's zoom pinch took these touches: cancel the touch sequence
    /// on the host once and keep the remaining touches away from the page
    /// until every finger lifts.
    func zoomPinchTookOver() {
        guard !suppressTouches else { return }
        suppressTouches = true
        if !touchIds.isEmpty { onTouch?(.cancel, []) }
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
    private var traits = PageFieldTraits()
    /// Safari's form bar above the keyboard: previous and next field (Tab
    /// and Shift-Tab on the page) and Done, which lowers the keyboard.
    private lazy var formBar: UIToolbar = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let previous = UIBarButtonItem(image: UIImage(systemName: "chevron.up"), primaryAction: UIAction { [weak self] _ in
            self?.onKey?(DOMKey(key: "Tab", code: "Tab", text: nil, modifiers: DOMKey.shift))
        })
        previous.accessibilityLabel = "Previous Field"
        let next = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), primaryAction: UIAction { [weak self] _ in
            self?.onKey?(DOMKey(key: "Tab", code: "Tab", text: nil, modifiers: 0))
        })
        next.accessibilityLabel = "Next Field"
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            _ = self?.resignFirstResponder()
        })
        done.accessibilityLabel = "Done"
        bar.items = [previous, next, .flexibleSpace(), done]
        bar.sizeToFit()
        return bar
    }()

    override var inputAccessoryView: UIView? {
        get { formBar }
        set {}
    }

    /// Keyboard layout and Return key for the focused page field.
    func apply(_ traits: PageFieldTraits) {
        guard traits != self.traits else { return }
        self.traits = traits
        let keyboard: UIKeyboardType = switch traits.keyboardKind {
        case .text: .default
        case .email: .emailAddress
        case .url: .URL
        case .phone: .phonePad
        case .number: .numberPad
        case .decimal: .decimalPad
        }
        let ret: UIReturnKeyType = switch traits.returnKey {
        case .default: .default
        case .go: .go
        case .search: .search
        case .send: .send
        case .next: .next
        case .done: .done
        }
        guard keyboard != keyboardType || ret != returnKeyType else { return }
        keyboardType = keyboard
        returnKeyType = ret
        if isFirstResponder { reloadInputViews() }
    }

    private func pressReturn() {
        onKey?(DOMKey(key: "Enter", code: "Enter", text: "\r", modifiers: 0))
        // Return submits a single-line field: Safari lowers the keyboard.
        if traits.returnLowersKeyboard { _ = resignFirstResponder() }
    }

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
            pressReturn()
        } else {
            onText?(text)
        }
    }

    override func deleteBackward() {
        onKey?(DOMKey(key: "Backspace", code: "Backspace", text: nil, modifiers: 0))
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        pressReturn()
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
    var onDragEnded: () -> Void = {}
    var onKeyboardDismissed: () -> Void
    var zoomPinchActive = false

    func makeUIView(context: Context) -> PageKeyboardDismissHost {
        let host = PageKeyboardDismissHost()
        let view = host.surface
        view.onTouch = { [model] type, points in model.sendTouch(type, points: points) }
        view.onKey = { [model] in model.sendKey($0) }
        view.onText = { [model] in model.sendText($0) }
        view.onTouchSequenceBegan = { [model] in model.pageTouchBegan() }
        view.onTap = { [model] in model.pageTapped() }
        return host
    }

    func updateUIView(_ host: PageKeyboardDismissHost, context: Context) {
        let view = host.surface
        view.topInset = topInset
        view.viewportCSSWidth = viewportCSSWidth
        view.onDrag = onDrag
        view.onDragEnded = onDragEnded
        view.onKeyboardDismissed = onKeyboardDismissed
        if zoomPinchActive { view.zoomPinchTookOver() }
        view.show(frame)
        view.proxy.apply(model.pageField)
        if keyboardActive {
            if !view.proxy.isFirstResponder { view.proxy.becomeFirstResponder() }
        } else if view.proxy.isFirstResponder {
            view.proxy.resignFirstResponder()
        }
        // While the page's keyboard is up, a drag on the page pulls it down
        // with the finger (the scroll view's interactive dismissal).
        // (Set only on a change: re-setting it on every frame reset the pan.)
        if host.isScrollEnabled != keyboardActive { host.isScrollEnabled = keyboardActive }
        host.coversTabBar(keyboardActive)
        // Off the page (the grid, address editing) the surface lets go of
        // the keys: a menu presented over the grid while it was still first
        // responder brought up the software keyboard (re-audit blocker).
        // Only with a hardware keyboard attached: a first-responder surface
        // brought up the software keyboard whenever a menu (the Back
        // history menu, the grid's menus) was presented over it.
        let wantsHardwareKeys = wantsHardwareKeys && PageSurfaceView.hardwareKeyboard
        if !wantsHardwareKeys, view.isFirstResponder { view.resignFirstResponder() }
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

/// Holds the page surface so a drag can dismiss the page's keyboard the way
/// Safari's does: the keyboard follows the finger once it reaches the
/// keyboard and goes, or comes back, on release (`keyboardDismissMode =
/// .interactive`). Only its pan is used: the surface stays put on screen
/// (the page scrolls on the Mac) and still gets every touch.
final class PageKeyboardDismissHost: UIScrollView, UIScrollViewDelegate {
    let surface = PageSurfaceView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        keyboardDismissMode = .interactive
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false
        delaysContentTouches = false
        // The pan takes the touch over from the surface (a scroll view
        // only drags after cancelling its content's touches); the surface
        // keeps feeding the page from the pan (`panned`).
        canCancelContentTouches = true
        panGestureRecognizer.cancelsTouchesInView = false
        panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
        isScrollEnabled = false
        delegate = self
        addSubview(surface)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: surface)
        switch g.state {
        case .changed: surface.panMoved(to: p)
        case .ended: surface.panEnded(at: p, cancelled: false)
        case .cancelled, .failed: surface.panEnded(at: p, cancelled: true)
        default: break
        }
    }

    /// The pan runs beside the page's own recognizers (long press, the
    /// screen's zoom pinch) instead of losing to them.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === panGestureRecognizer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if contentSize != bounds.size { contentSize = bounds.size }
        pinSurface()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { pinSurface() }

    // MARK: Shell tab bar

    /// The page's keyboard covers the shell's tab bar and its bottom
    /// accessory: out of the accessibility tree while it is up (layout and
    /// visibility untouched). Shared with the terminal (CNDesign).
    private let tabBarCover = CNTabBarCover()

    func coversTabBar(_ covered: Bool) {
        tabBarCover.setCovered(covered, from: self)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { tabBarCover.release() }
    }

    /// The page scrolls on the Mac, not here: while the pan drags the
    /// content (which drives the interactive dismissal), the surface rides
    /// along so it stays put on screen.
    private func pinSurface() {
        let frame = CGRect(origin: contentOffset, size: bounds.size)
        if surface.frame != frame { surface.frame = frame }
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
