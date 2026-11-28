// A window of scrolling text and a moving gradient, at 60 Hz, for scripts/measure/screen-share-replay.sh to
// record: screen-share-like content (text edges, flat areas, large moving regions) with no person's data on it.
//   screen-share-replay-motion SECONDS     opens a 1280x720 window at the main display's top-left, animates it,
//                                          prints `READY` when it is on screen and exits after SECONDS.
import AppKit

final class MotionView: NSView {
    var tick = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        bounds.fill()
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1)]
        // Text scrolls up two pixels a frame, lines numbered from the tick so no two frames repeat.
        let lineHeight: CGFloat = 20
        let offset = CGFloat(tick * 2).truncatingRemainder(dividingBy: lineHeight)
        let first = (tick * 2) / Int(lineHeight)
        var y = -offset
        var n = first
        while y < bounds.height {
            let text = String(format: "%06d  let frame_%d = decode(sample[%d]).present(at: %d) // %08x", n, n, n * 7 % 1013, n * 16, (n &* 2654435761) & 0xffffffff)
            (text as NSString).draw(at: NSPoint(x: 24, y: y), withAttributes: attrs)
            y += lineHeight
            n += 1
        }
        // A gradient bar sweeping across, the large moving region of a window drag or a video.
        let x = CGFloat((tick * 9) % Int(bounds.width + 400)) - 400
        let sweep = NSGradient(colors: [NSColor.systemBlue.withAlphaComponent(0), NSColor.systemBlue.withAlphaComponent(0.6), NSColor.systemPink.withAlphaComponent(0)])
        sweep?.draw(in: NSRect(x: x, y: 0, width: 400, height: bounds.height), angle: 0)
    }
}

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 8) : 8
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let view = MotionView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
let window = NSWindow(contentRect: NSRect(x: screen.minX, y: screen.maxY - 720, width: 1280, height: 720),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = view
window.level = .floating
window.makeKeyAndOrderFront(nil)
Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
    view.tick += 1
    view.needsDisplay = true
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("READY"); fflush(stdout) }
DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.5) { exit(0) }
app.run()
