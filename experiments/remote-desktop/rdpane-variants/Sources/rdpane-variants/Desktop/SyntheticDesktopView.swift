import AppKit

/// The fake remote desktop "frame": a Linux-style desktop with a terminal,
/// an editor and a file browser, drawn at the view's size (1:1, no scaling).
/// Fixture content, so its text is not localized.
final class SyntheticDesktopView: NSView {
    /// Ended sessions keep the last frame, desaturated under a dim layer.
    var desaturated = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        paintWallpaper()
        paintTopBar()
        paintFiles(NSRect(x: 110, y: 420, width: 400, height: 210))
        paintTerminal(NSRect(x: 36, y: 64, width: 600, height: 340))
        paintEditor(NSRect(x: 560, y: 150, width: 500, height: 360))
        paintDock()
        if desaturated {
            NSColor.gray.setFill()
            bounds.fill(using: .saturation)
        }
    }

    private func paintWallpaper() {
        let gradient = NSGradient(colors: [NSColor(hex: 0x56645B), NSColor(hex: 0x2F3934), NSColor(hex: 0x1D2320)])
        gradient?.draw(in: bounds, angle: 70)
        NSColor.white.withAlphaComponent(0.035).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width * 0.55, y: -bounds.height * 0.4, width: bounds.width * 0.9, height: bounds.width * 0.9)).fill()
        NSColor.black.withAlphaComponent(0.08).setFill()
        NSBezierPath(ovalIn: NSRect(x: -bounds.width * 0.3, y: bounds.height * 0.5, width: bounds.width * 0.8, height: bounds.width * 0.6)).fill()
    }

    private func paintTopBar() {
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: 26)
        NSColor(hex: 0x121413, alpha: 0.92).setFill()
        bar.fill()
        let text = NSColor(hex: 0xE6E6E6)
        MockWindowPainter.text("Applications", at: NSPoint(x: 14, y: 5), size: 12, weight: .medium, color: text)
        MockWindowPainter.text("Places", at: NSPoint(x: 112, y: 5), size: 12, weight: .medium, color: text)
        let clock = "Fri 2 Oct  14:32"
        let width = MockWindowPainter.textWidth(clock, size: 12, weight: .semibold)
        MockWindowPainter.text(clock, at: NSPoint(x: bar.midX - width / 2, y: 5), size: 12, weight: .semibold, color: text)
        let right = "en   ◐   lawrence"
        let rightWidth = MockWindowPainter.textWidth(right, size: 12)
        MockWindowPainter.text(right, at: NSPoint(x: bar.maxX - rightWidth - 14, y: 5), size: 12, color: text)
    }

    private func paintTerminal(_ frame: NSRect) {
        let content = MockWindowPainter.paint(frame, title: "lawrence@build-linux: ~/src/rd", style: .linuxDark, active: false)
        let plain = NSColor(hex: 0xD4D4D4)
        let prompt = NSColor(hex: 0x9CC56E)
        let dim = NSColor(hex: 0x8A8F94)
        let warn = NSColor(hex: 0xE5C07B)
        MockWindowPainter.lines([
            ("$ make -C host release", prompt),
            ("cc -O2 -c capture_x11.c -o build/capture_x11.o", dim),
            ("cc -O2 -c encode_h264.c -o build/encode_h264.o", dim),
            ("cc -O2 -c pacer.c -o build/pacer.o", dim),
            ("ld build/*.o -o build/rd-host", dim),
            ("build ok in 41.27 s", plain),
            ("$ ./build/rd-host --display :1 --fps 60", prompt),
            ("rd: listening on 10.250.91.1:4102 (overlay only)", plain),
            ("rd: virtual display 1920x1080 @ 2x", plain),
            ("rd: viewer lawrence connected, mode=control, path=direct", plain),
            ("rd: encoder h264 software, 2 cores, 60 fps", plain),
            ("rd: refine after 120 ms idle, qp 18", plain),
            ("warn: frame 18342 late by 3.1 ms (pacer)", warn),
            ("$ █", prompt),
        ], at: NSPoint(x: content.minX + 14, y: content.minY + 12), clip: content)
    }

    private func paintEditor(_ frame: NSRect) {
        let content = MockWindowPainter.paint(frame, title: "notes.md - Text Editor", style: .linuxLight, active: true)
        NSColor(hex: 0xF1F0EE).setFill()
        NSRect(x: content.minX, y: content.minY, width: 40, height: content.height).fill()
        let body = NSColor(hex: 0x2E2E2E)
        let heading = NSColor(hex: 0x7A4E2D)
        let muted = NSColor(hex: 0x8E8C88)
        let rows: [(String, NSColor)] = [
            ("# Remote desktop dogfood", heading),
            ("", body),
            ("- Text must stay sharp at 1:1.", body),
            ("- Idle desktop: 0 packets, 0 wakeups.", body),
            ("- Cursor drawn locally in control mode.", body),
            ("", body),
            ("## Checks", heading),
            ("1. Type in the terminal, watch the echo.", body),
            ("2. Drag a window, watch for smear.", body),
            ("3. Scroll a long page at 60 fps.", body),
            ("4. Stop from the host indicator.", body),
            ("", body),
            ("> RTT 4 ms, loss 0.0 %, G2G 31 ms", muted),
            ("", body),
            ("The quick brown fox jumps over the lazy dog.", body),
            ("0123456789  iIl1|  O0o  {}[]()", body),
            ("Small text: 11 px antialiasing test", muted),
        ]
        MockWindowPainter.lines(rows, at: NSPoint(x: content.minX + 52, y: content.minY + 12), size: 12.5, leading: 18.5, clip: content)
        let numbers = (1...rows.count).map { ("\($0)", muted) }
        MockWindowPainter.lines(numbers, at: NSPoint(x: content.minX + 12, y: content.minY + 12), size: 12.5, leading: 18.5, clip: content)
        NSColor(hex: 0x2E2E2E).setFill()
        NSRect(x: content.minX + 52 + 7.5 * 13, y: content.minY + 12 + 18.5 * 9, width: 1.5, height: 16).fill()
    }

    private func paintFiles(_ frame: NSRect) {
        let content = MockWindowPainter.paint(frame, title: "Files - /home/lawrence/src", style: .linuxLight, active: false)
        let entries = [("host", "4 items"), ("client", "9 items"), ("bench", "3 items"), ("PROTOCOL.md", "12.4 kB"),
                       ("results.csv", "88.1 kB"), ("trace-0930.json", "2.3 MB")]
        for (index, entry) in entries.enumerated() {
            let y = content.minY + 10 + CGFloat(index) * 27
            if index == 3 {
                NSColor(hex: 0x000000, alpha: 0.06).setFill()
                NSBezierPath(roundedRect: NSRect(x: content.minX + 6, y: y - 3, width: content.width - 12, height: 25), xRadius: 5, yRadius: 5).fill()
            }
            let isFolder = !entry.0.contains(".")
            (isFolder ? NSColor(hex: 0xC9A66B) : NSColor(hex: 0xB9B6B1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: content.minX + 16, y: y + 2, width: 16, height: 14), xRadius: 3, yRadius: 3).fill()
            MockWindowPainter.text(entry.0, at: NSPoint(x: content.minX + 42, y: y + 1), size: 12.5, color: NSColor(hex: 0x2E2E2E))
            let width = MockWindowPainter.textWidth(entry.1, size: 11.5)
            MockWindowPainter.text(entry.1, at: NSPoint(x: content.maxX - width - 16, y: y + 2), size: 11.5, color: NSColor(hex: 0x8E8C88))
        }
    }

    private func paintDock() {
        let dock = NSRect(x: bounds.midX - 170, y: bounds.maxY - 50, width: 340, height: 42)
        NSColor.black.withAlphaComponent(0.38).setFill()
        NSBezierPath(roundedRect: dock, xRadius: 13, yRadius: 13).fill()
        let colors: [UInt32] = [0x6E7B72, 0xB08D57, 0x8A6F86, 0x5E7A84, 0x9A9A8C, 0x7D6A5A]
        for (index, hex) in colors.enumerated() {
            NSColor(hex: hex).setFill()
            NSBezierPath(roundedRect: NSRect(x: dock.minX + 14 + CGFloat(index) * 53, y: dock.minY + 6, width: 30, height: 30), xRadius: 8, yRadius: 8).fill()
        }
    }
}
