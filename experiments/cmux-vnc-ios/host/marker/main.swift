import AppKit

// Latency marker: a small always-on-top window at the top left of the main
// display that draws an 8-bit counter as 8 cells (white = 1), most
// significant bit first. Every key down and every pointer move inside the
// window increments it, so a viewer can read from decoded video exactly
// when input N became visible (glass-to-glass, remote-desktop.md 15.1).
final class MarkerView: NSView {
    var counter: UInt8 = 0 { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let cell = bounds.width / 8
        for bit in 0 ..< 8 {
            let on = (counter >> UInt8(7 - bit)) & 1 == 1
            (on ? NSColor.white : NSColor.black).setFill()
            NSRect(x: CGFloat(bit) * cell, y: 0, width: cell, height: bounds.height).fill()
        }
    }
    override func keyDown(with event: NSEvent) { counter &+= 1 }
    override func mouseMoved(with event: NSEvent) { counter &+= 1 }
    override func mouseDragged(with event: NSEvent) { counter &+= 1 }
}

/// Borderless windows cannot become key by default; this one must, to get keys and moves.
final class MarkerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main!.frame
let window = MarkerWindow(contentRect: NSRect(x: 40, y: screen.height - 40 - 64, width: 256, height: 64),
                      styleMask: [.borderless], backing: .buffered, defer: false)
let view = MarkerView(frame: NSRect(x: 0, y: 0, width: 256, height: 64))
window.contentView = view
window.level = .floating
window.acceptsMouseMovedEvents = true
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
app.run()
