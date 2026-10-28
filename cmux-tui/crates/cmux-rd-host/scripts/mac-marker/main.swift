// The glass-to-glass marker for a macOS host (the Linux test app's counterpart; layout in
// src/marker.rs): 20 cells of 32x32 pixels in one row at the display's top-left pixel. Cells
// 0..15 carry bit i of the counter, least significant first; cells 16..19 are the guard 1,0,1,0.
// Every key down, mouse down and scroll event increments the counter and redraws at once.
//
//   swiftc -O -o cmux-rd-marker main.swift
//   ./cmux-rd-marker [--motion]     --motion: animate the rest of the display every refresh
//
// Test hosts only: it covers the menu bar corner and takes key focus on the host Mac.

import AppKit

let cells = 20
let guardBits = [true, false, true, false]

final class MarkerView: NSView {
    var counter: UInt16 = 0
    /// Pixels per point, so a cell is 32 pixels on any display.
    var cell: CGFloat { 32 / (window?.backingScaleFactor ?? 1) }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0 ..< cells {
            let on = i < 16 ? (counter >> UInt16(i)) & 1 == 1 : guardBits[i - 16]
            (on ? NSColor.white : NSColor.black).setFill()
            NSRect(x: CGFloat(i) * cell, y: 0, width: cell, height: cell).fill()
        }
    }

    func bump() {
        counter &+= 1
        // Draw now, not at the next run-loop pass, so the change reaches the screen first.
        display()
    }

    override func keyDown(with event: NSEvent) { bump() }
    override func mouseDown(with event: NSEvent) { bump() }
    override func rightMouseDown(with event: NSEvent) { bump() }
    override func scrollWheel(with event: NSEvent) { bump() }
}

/// Moving bars over the rest of the display, redrawn every display refresh.
final class MotionView: NSView {
    var phase: CGFloat = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        let bar: CGFloat = 48
        var x = -bar + phase.truncatingRemainder(dividingBy: bar * 2)
        var hue: CGFloat = 0
        while x < bounds.width {
            NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
            NSRect(x: x, y: 64, width: bar, height: bounds.height - 64).fill()
            x += bar * 2
            hue = (hue + 0.07).truncatingRemainder(dividingBy: 1)
        }
        let text = String(format: "%.0f", phase) as NSString
        text.draw(at: NSPoint(x: bounds.midX - 100, y: bounds.midY),
                  withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 96, weight: .bold),
                                   .foregroundColor: NSColor.white])
    }
}

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main!
let frame = screen.frame

var motion: MotionView?
if CommandLine.arguments.contains("--motion") {
    let back = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    let view = MotionView(frame: NSRect(origin: .zero, size: frame.size))
    back.contentView = view
    back.level = .floating
    back.orderFrontRegardless()
    motion = view
}

let marker = MarkerView(frame: .zero)
let window = KeyWindow(
    contentRect: NSRect(x: frame.minX, y: frame.maxY - 32 / screen.backingScaleFactor,
                        width: 32 * CGFloat(cells) / screen.backingScaleFactor,
                        height: 32 / screen.backingScaleFactor),
    styleMask: [.borderless], backing: .buffered, defer: false)
marker.frame = NSRect(origin: .zero, size: window.frame.size)
window.contentView = marker
// Above the menu bar, so pixel (0,0) is the marker.
window.level = .screenSaver
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(marker)
app.activate(ignoringOtherApps: true)

if let motion {
    let link = screen.displayLink(target: motion, selector: #selector(MotionView.step))
    link.add(to: .main, forMode: .common)
}

extension MotionView {
    @objc func step(_ link: CADisplayLink) {
        phase += 8
        needsDisplay = true
    }
}

app.run()
