import CmuxTerminalRenderCore
import CmuxiOSDesign
import GhosttyNextKit
import UIKit

/// Touch (ghostty-next section 5): tap opens a link or focuses, long-press
/// selects a word and drags the selection, one-finger pan scrolls local
/// history (or sends wheel events when the program tracks the mouse), pinch
/// zooms the font. Every touch reaches Ghostty as a pointer event, so link
/// detection, selection and mouse reporting are Ghostty's own.
extension GhosttyTerminalView {
    func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.35
        addGestureRecognizer(press)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)
        addInteraction(UIEditMenuInteraction(delegate: self))
    }

    /// Pointer modifiers: Shift selects even while the program captured the
    /// mouse (Ghostty's override), so a long-press always selects.
    private var selectionMods: ghostty_input_mods_e {
        guard let surface, ghostty_surface_mouse_captured(surface) else { return GHOSTTY_MODS_NONE }
        return GHOSTTY_MODS_SHIFT
    }

    private func pointer(_ point: CGPoint, _ mods: ghostty_input_mods_e) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, point.x, point.y, mods)
    }

    private func button(_ state: ghostty_input_mouse_state_e, _ mods: ghostty_input_mods_e) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, GHOSTTY_MOUSE_LEFT, mods)
    }

    // MARK: Tap

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        dismissEditMenu()
        // A link click is Super+click (Ghostty's link modifier on Apple
        // platforms); Ghostty answers with OPEN_URL. Without a link it is a
        // plain click: clears the selection, or reaches a mouse-tracking program.
        gestures.openedLink = false
        let mods = GHOSTTY_MODS_SUPER
        pointer(recognizer.location(in: self), mods)
        button(GHOSTTY_MOUSE_PRESS, mods)
        button(GHOSTTY_MOUSE_RELEASE, mods)
        requestFrame()
        if !gestures.openedLink { onTap?() }
    }

    // MARK: Selection

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        let mods = selectionMods
        switch recognizer.state {
        case .began:
            dismissEditMenu()
            gestures.selecting = true
            // Two presses at one point: Ghostty's double-click selects the
            // word; holding the second press drags by words.
            pointer(point, mods)
            button(GHOSTTY_MOUSE_PRESS, mods)
            button(GHOSTTY_MOUSE_RELEASE, mods)
            button(GHOSTTY_MOUSE_PRESS, mods)
            Haptics().play(.selection)
        case .changed:
            pointer(point, mods)
        case .ended:
            button(GHOSTTY_MOUSE_RELEASE, mods)
            gestures.selecting = false
            if hasSelection { presentEditMenu(at: point) }
        case .cancelled, .failed:
            button(GHOSTTY_MOUSE_RELEASE, mods)
            gestures.selecting = false
        default:
            break
        }
        requestFrame()
    }

    // MARK: Scroll

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            frameLink.stop()
            gestures.momentum = nil
            gestures.scrolledTranslation = 0
            pointer(recognizer.location(in: self), GHOSTTY_MODS_NONE)
            // The link keeps frames at the gesture rate while the finger moves.
            frameLink.start(screen: window?.screen) { [weak self] _ in self?.gestures.momentum == nil }
        case .changed:
            let y = recognizer.translation(in: self).y
            scroll(by: y - gestures.scrolledTranslation, momentum: GHOSTTY_MOUSE_MOMENTUM_NONE)
            gestures.scrolledTranslation = y
        case .ended:
            let momentum = TerminalScrollMomentum(velocity: recognizer.velocity(in: self).y)
            guard !momentum.isFinished else { return frameLink.stop() }
            gestures.momentum = momentum
            frameLink.start(screen: window?.screen) { [weak self] dt in self?.decelerate(dt) ?? false }
        default:
            frameLink.stop()
        }
    }

    private func decelerate(_ dt: Double) -> Bool {
        guard var momentum = gestures.momentum else { return false }
        let distance = momentum.step(dt)
        gestures.momentum = momentum.isFinished ? nil : momentum
        scroll(by: distance, momentum: momentum.isFinished ? GHOSTTY_MOUSE_MOMENTUM_ENDED : GHOSTTY_MOUSE_MOMENTUM_CHANGED)
        return !momentum.isFinished
    }

    /// Finger down reveals older lines. Precision deltas are pixels; Ghostty
    /// turns them into lines at its cell height (local history, wheel events
    /// for a mouse-tracking program, or arrows in alternate-scroll mode).
    private func scroll(by points: CGFloat, momentum: ghostty_input_mouse_momentum_e) {
        guard let surface, points != 0 else { return }
        let scale = window?.screen.scale ?? 2
        let mods = ghostty_input_scroll_mods_t(1 | Int32(momentum.rawValue) << 1)
        ghostty_surface_mouse_scroll(surface, 0, Double(points * scale), mods)
        requestFrame()
    }

    // MARK: Zoom

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            gestures.pinchStartZoom = zoom
            // The viewport is reported once, when the pinch ends.
            deferViewportReports = true
            frameLink.start(screen: window?.screen) { _ in true }
        case .changed:
            zoom = fontSizing.zoom(startZoom: gestures.pinchStartZoom, pinchScale: Double(recognizer.scale))
        default:
            frameLink.stop()
            deferViewportReports = false
            reportViewport()
        }
    }
}
