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
//   ./cmux-rd-marker [--motion] [--tick]
//     --motion: animate the rest of the display every refresh: moving bars and a panel of text
//               that scrolls one line a refresh. It logs `motion-geometry {JSON}` (in points)
//               before `marker-origin`, so a viewer's frame can be scored against what was drawn.
//     --tick:   also count every display refresh, an fps probe: a viewer that shows every
//               frame sees the counter step by one each refresh (screen-share-vs.py). With
//               --motion the scene is then a function of the counter (bars at 8 pt per count,
//               the panel's first line is row COUNTER), drawn in the same refresh as the marker,
//               so one decoded frame says which source frame it should match.
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
    /// `--tick --motion`: the scene this marker's refresh redraws.
    var motion: MotionView?
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
        // Draw now, not at the next run-loop pass, and hand the layer tree to the window server
        // now too, so the change reaches the screen first.
        display()
        CATransaction.flush()
        // When the draw was committed, on the protocol clock (CLOCK_MONOTONIC, µs): the eval's rd
        // split measures input to commit and commit to the display time from it.
        if verbose { log("commit \(counter) \(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000)") }
    }

    override func keyDown(with event: NSEvent) { bump("key") }
    override func mouseDown(with event: NSEvent) { bump("click") }
    override func rightMouseDown(with event: NSEvent) { bump("right click") }
    override func scrollWheel(with event: NSEvent) { bump("scroll") }
}

/// The motion scene's layout in points (top-left origin); screen-share-vs.py's frame-score reads
/// the same numbers from the `motion-geometry` line, so keep the two in step.
let motionBar: CGFloat = 48
let motionStep: CGFloat = 8
let motionBarsTop: CGFloat = 64
let motionLines = 8
let motionLineHeight: CGFloat = 36
let motionFont: CGFloat = 28
let motionPad: CGFloat = 16
let motionPanelWidth: CGFloat = 720

/// Line N of the scrolling panel (screen-share-vs.py's motion_line).
func motionLine(_ n: Int) -> String {
    String(format: "row %05ld the quick brown fox %03ld", n % 100_000, (n * 7) % 1000)
}

/// Moving bars over the rest of the display and a panel of text scrolling a line a refresh.
final class MotionView: NSView {
    /// Refreshes drawn so far: bars move motionStep points and the panel one line per count.
    var count = 0
    override var isFlipped: Bool { true }

    var panel: NSRect {
        let height = motionPad * 2 + CGFloat(motionLines) * motionLineHeight
        return NSRect(x: (bounds.width - motionPanelWidth) / 2, y: (bounds.height - height) / 2,
                      width: motionPanelWidth, height: height).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        let phase = CGFloat(count) * motionStep
        var x = -motionBar + phase.truncatingRemainder(dividingBy: motionBar * 2)
        var hue: CGFloat = 0
        while x < bounds.width {
            NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
            NSRect(x: x, y: motionBarsTop, width: motionBar, height: bounds.height - motionBarsTop).fill()
            x += motionBar * 2
            hue = (hue + 0.07).truncatingRemainder(dividingBy: 1)
        }
        let box = panel
        NSColor.black.setFill()
        box.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: motionFont, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        for i in 0 ..< motionLines {
            (motionLine(count + i) as NSString).draw(
                at: NSPoint(x: box.minX + motionPad, y: box.minY + motionPad + CGFloat(i) * motionLineHeight),
                withAttributes: attributes)
        }
    }

    /// The layout for screen-share-vs.py, one JSON object.
    func geometry(streamWidth: CGFloat, tickDriven: Bool) -> String {
        let box = panel
        let object: [String: Any] = [
            "display_pt": [bounds.width, bounds.height], "stream_width_px": streamWidth,
            "bar_pt": motionBar, "step_pt": motionStep, "bars_top_pt": motionBarsTop,
            "panel_pt": [box.minX, box.minY, box.width, box.height], "lines": motionLines,
            "line_pt": motionLineHeight, "pad_pt": motionPad, "font_pt": motionFont,
            "tick_driven": tickDriven,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
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
let ticking = CommandLine.arguments.contains("--tick")
if let motion {
    log("motion-geometry " + motion.geometry(streamWidth: streamed, tickDriven: ticking))
}
log("marker-origin 0,\(originY) click-at \(32 * (cells + padCells / 2)),\(originY + 16)")
log("marker: stream width \(streamed) px, cell \(marker.cell) pt, display \(frame.size)")
log("refresh-hz \(screen.maximumFramesPerSecond)")
marker.frame = NSRect(origin: .zero, size: window.frame.size)
window.contentView = marker
// Above every app window, so test clicks land only on the marker.
window.level = .screenSaver
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(marker)
app.activate(ignoringOtherApps: true)

// With --tick the marker's refresh drives the scene too, so both change in the same frame.
if let motion, !ticking {
    let link = screen.displayLink(target: motion, selector: #selector(MotionView.step))
    link.add(to: .main, forMode: .common)
}
if ticking {
    marker.motion = motion
    let link = screen.displayLink(target: marker, selector: #selector(MarkerView.tick))
    link.add(to: .main, forMode: .common)
}

extension MotionView {
    @objc func step(_ link: CADisplayLink) {
        count += 1
        needsDisplay = true
    }
}

extension MarkerView {
    /// `--tick`: one count per display refresh, drawn at once.
    @objc func tick(_ link: CADisplayLink) {
        counter &+= 1
        if let motion {
            motion.count = Int(counter)
            motion.display()
        }
        display()
    }
}

app.run()
