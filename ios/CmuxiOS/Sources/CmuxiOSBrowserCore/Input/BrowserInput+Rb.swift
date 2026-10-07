import CmuxBrowserStream
import CmuxiOSFeatureKit

extension BrowserInput {
    /// The `cmux.rb/1` event this input becomes on the wire.
    var rbEvent: RbInputEvent {
        switch self {
        case .pointer(let pointer):
            let kind: RbPointerKind = switch pointer.kind {
            case .move: .move
            case .down: .down
            case .up: .up
            }
            let pressed: UInt8 = pointer.kind == .down ? (pointer.button == 2 ? 2 : 1) : 0
            return .pointer(kind: kind, x: pointer.x, y: pointer.y, button: UInt8(clamping: pointer.button), buttons: pressed,
                            clickCount: UInt8(clamping: pointer.clickCount), modifiers: RbModifiers(pointer.modifiers),
                            pointerType: pointer.pointerType)
        case .wheel(let wheel):
            return .wheel(x: wheel.x, y: wheel.y, dx: wheel.dx, dy: wheel.dy, precise: true, phase: RbPhase(wheel.phase),
                          momentumPhase: RbPhase(wheel.momentumPhase), modifiers: [])
        case .key(let key):
            return .key(RbKeyEvent(down: key.down, code: key.code, key: key.key, text: key.text, unmodifiedText: key.text,
                                   modifiers: RbModifiers(key.modifiers), isRepeat: key.isRepeat))
        case .composition(let text, let selection):
            let length = UInt32(text.utf16.count)
            return .imeSetComposition(text: text, underlines: [RbUnderline(start: 0, end: length)],
                                      selectionStart: UInt32(clamping: selection.lowerBound),
                                      selectionEnd: UInt32(clamping: selection.upperBound), replacement: nil)
        case .commit(let text):
            return .imeCommit(text: text, replacement: nil)
        case .cancelComposition:
            return .imeCancel
        }
    }
}

extension RbModifiers {
    init(_ modifiers: BrowserModifiers) {
        var out: RbModifiers = []
        if modifiers.contains(.shift) { out.insert(.shift) }
        if modifiers.contains(.control) { out.insert(.control) }
        if modifiers.contains(.option) { out.insert(.option) }
        if modifiers.contains(.command) { out.insert(.command) }
        self = out
    }
}

extension RbPhase {
    init(_ phase: BrowserGesturePhase) {
        self = switch phase {
        case .none: .none
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        }
    }
}
