// The glass-to-glass marker for a macOS host (the Linux test app's counterpart; layout in
// src/marker.rs): 20 cells of 32x32 stream pixels in one row at the display's top-left. Cells
// 0..15 carry bit i of the counter, least significant first; cells 16..19 are the guard 1,0,1,0.
// Every key down, mouse down and scroll event increments the counter and redraws at once.
// Cells are sized in the pixels the host streams (the display fitted to 3840x2160, as
// src/mac/capture.rs does), so the bench reads them on any display. The window takes the first
// click even when another app is in front, so click input never reaches another app. Clicks
// go to the gray pad right of cell 19 (cells 20 to 23, never read): the host draws the cursor
// into its frames, and over a read cell it would change the counter the viewer reads.
//
//   swiftc -O -o cmux-rd-marker main.swift
//   ./cmux-rd-marker [--motion]     --motion: animate the rest of the display every refresh
//
// Test hosts only: it covers the menu bar corner and takes key focus on the host Mac.

import AppKit

let cells = 20
/// Cells of gray click pad after the read cells.
let padCells = 4
let guardBits = [true, false, true, false]
/// `--verbose`: log every counted event.
let verbose = CommandLine.arguments.contains("--verbose")

/// Unbuffered, so a log file shows each line at once.
func log(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

final class MarkerView: NSView {
    var counter: UInt16 = 0
    /// One cell in points: 32 stream pixels.
    var cell: CGFloat = 16

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0 ..< cells {
            let on = i < 16 ? (counter >> UInt16(i)) & 1 == 1 : guardBits[i - 16]
            (on ? NSColor.white : NSColor.black).setFill()
            NSRect(x: CGFloat(i) * cell, y: 0, width: cell, height: cell).fill()
        }
        NSColor.gray.setFill()
        NSRect(x: CGFloat(cells) * cell, y: 0, width: CGFloat(padCells) * cell, height: cell).fill()
    }

    func bump(_ what: String) {
        counter &+= 1
        if verbose { log("\(what) -> \(counter)") }
        // Draw now, not at the next run-loop pass, so the change reaches the screen first.
        display()
    }

    override func keyDown(with event: NSEvent) { bump("key") }
    override func mouseDown(with event: NSEvent) { bump("click") }
    override func rightMouseDown(with event: NSEvent) { bump("right click") }
    override func scrollWheel(with event: NSEvent) { bump("scroll") }
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

/// The width the host streams this display at: its native pixels fitted to 3840x2160, even.
func streamWidth(of screen: NSScreen) -> CGFloat {
    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    let mode = CGDisplayCopyDisplayMode(id)
    let (w, h) = (CGFloat(mode?.pixelWidth ?? Int(screen.frame.width)),
                  CGFloat(mode?.pixelHeight ?? Int(screen.frame.height)))
    let scale = min(3840 / w, 2160 / h, 1)
    return CGFloat(Int((w * scale).rounded()) & ~1)
}

/// `--stream-width N`: the host's `--max-width` (the stream is narrower than the display).
func argument(_ name: String) -> String? {
    CommandLine.arguments.firstIndex(of: name).flatMap { i in
        i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
    }
}
let streamed = min(streamWidth(of: screen), argument("--stream-width").flatMap(Double.init).map { CGFloat($0) } ?? .infinity)
let marker = MarkerView(frame: .zero)
marker.cell = 32 * frame.width / streamed
// Just below the menu bar (on a display with a camera housing the menu bar would cover it).
let top = screen.visibleFrame.maxY
let window = KeyWindow(
    contentRect: NSRect(x: frame.minX, y: top - marker.cell,
                        width: marker.cell * CGFloat(cells + padCells), height: marker.cell),
    styleMask: [.borderless], backing: .buffered, defer: false)
let pixelsPerPoint = streamed / frame.width
// The marker's top-left in stream pixels: the bench's --marker-origin.
let originY = Int(((frame.maxY - top) * pixelsPerPoint).rounded())
log("marker-origin 0,\(originY) click-at \(32 * (cells + padCells / 2)),\(originY + 16)")
log("marker: stream width \(streamed) px, cell \(marker.cell) pt, display \(frame.size)")
marker.frame = NSRect(origin: .zero, size: window.frame.size)
window.contentView = marker
// Above every app window, so test clicks land only on the marker.
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
