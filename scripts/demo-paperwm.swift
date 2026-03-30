#!/usr/bin/env swift
// PaperWM-style terminal canvas demo
// Usage: swift scripts/demo-paperwm.swift
//
// Demonstrates: multiple "terminal" surfaces arranged in a horizontal strip
// with perspective transforms and smooth 120fps scrolling via Core Animation.
// Replace the colored placeholder layers with real IOSurface-backed layers
// from ghostty to get actual terminal content.

import AppKit
import QuartzCore

// MARK: - PaperWM Strip View

class PaperStripView: NSView {
    private var rootLayer = CATransformLayer()
    private var panels: [CALayer] = []
    private var scrollOffset: CGFloat = 0
    private var targetOffset: CGFloat = 0
    private var focusedIndex: Int = 0
    private var displayLink: CVDisplayLink?
    private var lastTimestamp: Double = 0

    // Layout
    let panelWidth: CGFloat = 700
    let panelHeight: CGFloat = 450
    let panelGap: CGFloat = 30
    let perspectiveZ: CGFloat = -120  // how far unfocused panels recede
    let edgeRotation: CGFloat = .pi / 14  // rotation for off-screen panels

    // Terminal placeholder colors (dark themes)
    static let themes: [(bg: NSColor, accent: NSColor, name: String)] = [
        (.init(red: 0.11, green: 0.11, blue: 0.14, alpha: 1), .systemCyan, "neovim"),
        (.init(red: 0.10, green: 0.12, blue: 0.10, alpha: 1), .systemGreen, "htop"),
        (.init(red: 0.13, green: 0.11, blue: 0.15, alpha: 1), .systemPurple, "claude"),
        (.init(red: 0.12, green: 0.10, blue: 0.08, alpha: 1), .systemOrange, "cargo build"),
        (.init(red: 0.08, green: 0.11, blue: 0.14, alpha: 1), .systemBlue, "ssh prod"),
        (.init(red: 0.14, green: 0.10, blue: 0.10, alpha: 1), .systemRed, "git log"),
        (.init(red: 0.10, green: 0.13, blue: 0.12, alpha: 1), .systemTeal, "docker ps"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer = CALayer()
        layer!.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor

        // Sublayer transform with perspective
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 1200
        layer!.sublayerTransform = perspective

        rootLayer.frame = bounds
        layer!.addSublayer(rootLayer)

        createPanels()
        startDisplayLink()
    }

    private func createPanels() {
        for (i, theme) in Self.themes.enumerated() {
            let panel = CALayer()
            panel.frame = CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
            panel.cornerRadius = 10
            panel.masksToBounds = true
            panel.backgroundColor = theme.bg.cgColor
            panel.borderColor = theme.accent.withAlphaComponent(0.3).cgColor
            panel.borderWidth = 1
            panel.shadowColor = NSColor.black.cgColor
            panel.shadowOpacity = 0.6
            panel.shadowRadius = 20
            panel.shadowOffset = CGSize(width: 0, height: -5)
            panel.masksToBounds = false

            // Title bar
            let titleBar = CALayer()
            titleBar.frame = CGRect(x: 0, y: panelHeight - 32, width: panelWidth, height: 32)
            titleBar.backgroundColor = theme.bg.blended(withFraction: 0.15, of: .white)?.cgColor
            panel.addSublayer(titleBar)

            // Title text
            let title = CATextLayer()
            title.frame = CGRect(x: 12, y: panelHeight - 28, width: panelWidth - 24, height: 20)
            title.string = theme.name
            title.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            title.fontSize = 12
            title.foregroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
            title.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            panel.addSublayer(title)

            // Fake terminal content lines
            let contentLayer = CALayer()
            contentLayer.frame = CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight - 32)
            panel.addSublayer(contentLayer)

            for line in 0..<18 {
                let textLine = CATextLayer()
                let y = panelHeight - 32 - CGFloat(line + 1) * 22 - 8
                textLine.frame = CGRect(x: 14, y: y, width: panelWidth - 28, height: 18)
                textLine.fontSize = 13
                textLine.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                textLine.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

                if line == 0 {
                    // Prompt line
                    let prompt = NSMutableAttributedString()
                    prompt.append(NSAttributedString(string: "~ ", attributes: [
                        .foregroundColor: theme.accent,
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                    ]))
                    prompt.append(NSAttributedString(string: randomCommand(i, line), attributes: [
                        .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    ]))
                    textLine.string = prompt
                } else {
                    let alpha = max(0.15, 0.6 - Double(line) * 0.03)
                    textLine.string = NSAttributedString(string: randomOutput(i, line), attributes: [
                        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    ])
                }
                panel.addSublayer(textLine)
            }

            // Cursor blink layer
            if i == 0 {
                let cursor = CALayer()
                cursor.frame = CGRect(x: 50, y: panelHeight - 32 - 22 - 8, width: 8, height: 16)
                cursor.backgroundColor = theme.accent.cgColor
                let blink = CABasicAnimation(keyPath: "opacity")
                blink.fromValue = 1.0
                blink.toValue = 0.0
                blink.duration = 0.6
                blink.autoreverses = true
                blink.repeatCount = .infinity
                cursor.add(blink, forKey: "blink")
                panel.addSublayer(cursor)
            }

            panels.append(panel)
            rootLayer.addSublayer(panel)
        }
    }

    private func randomCommand(_ panel: Int, _ line: Int) -> String {
        let commands = ["nvim src/main.zig", "htop -t", "claude", "cargo build --release",
                        "ssh prod-web-03", "git log --oneline -20", "docker ps -a"]
        return commands[panel % commands.count]
    }

    private func randomOutput(_ panel: Int, _ line: Int) -> String {
        let seed = panel * 100 + line
        let outputs = [
            "  const std = @import(\"std\");",
            "  pub fn main() !void {",
            "      const allocator = std.heap.page_allocator;",
            "  PID  USER  PR  NI  VIRT   RES   SHR S %CPU",
            "  1284 root  20  0  45.2g  1.2g  840m S 12.3",
            "  Compiling ghostty v0.15.2",
            "     Running `target/release/ghostty`",
            "  9746942 Add r/cmux to social skill subreddit list",
            "  608d687 Add merge guardrails to community-prs skill",
            "  CONTAINER ID  IMAGE         STATUS        PORTS",
            "  a1b2c3d4e5f6  nginx:latest  Up 3 days     80/tcp",
            "  Last login: Tue Mar 25 14:22:01 2026 from 10.0.1.5",
            "  root@prod-web-03:~#",
            "  [user] Let me check the crash logs...",
            "  Analyzing 1043 upstream commits...",
            "      try stdout.print(\"hello\\n\", .{});",
            "  }",
            "      var buf: [4096]u8 = undefined;",
        ]
        return outputs[seed % outputs.count]
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        rootLayer.frame = bounds
        updateLayout(animated: false)
    }

    private func updateLayout(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.02)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        }

        let centerX = bounds.midX
        let centerY = bounds.midY

        for (i, panel) in panels.enumerated() {
            let stripX = CGFloat(i) * (panelWidth + panelGap)
            let relativeX = stripX - scrollOffset

            // Position relative to center of view
            let screenX = centerX + relativeX - panelWidth / 2

            // Depth: panels further from center recede
            let distFromCenter = abs(relativeX) / (panelWidth + panelGap)
            let zOffset = -abs(distFromCenter) * perspectiveZ
            let scale = max(0.75, 1.0 - distFromCenter * 0.08)

            // Subtle rotation for panels going off-screen
            let rotation = -relativeX / (bounds.width * 1.5) * edgeRotation

            // Opacity falloff
            let opacity = max(0.3, 1.0 - distFromCenter * 0.25)

            var transform = CATransform3DIdentity
            transform = CATransform3DTranslate(transform, screenX + panelWidth / 2 - centerX, 0, zOffset)
            transform = CATransform3DRotate(transform, rotation, 0, 1, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)

            panel.transform = transform
            panel.position = CGPoint(x: centerX, y: centerY)
            panel.opacity = Float(opacity)
            panel.zPosition = -abs(relativeX)

            // Highlight focused panel border
            let isFocused = i == focusedIndex
            panel.borderWidth = isFocused ? 2 : 1
            panel.borderColor = isFocused
                ? Self.themes[i % Self.themes.count].accent.withAlphaComponent(0.8).cgColor
                : Self.themes[i % Self.themes.count].accent.withAlphaComponent(0.2).cgColor
        }

        CATransaction.commit()
    }

    // MARK: - Scrolling

    override func scrollWheel(with event: NSEvent) {
        // Horizontal scroll (trackpad or shift+scroll)
        var dx = event.scrollingDeltaX
        if event.isDirectionInvertedFromDevice { dx = -dx }

        // Also support vertical scroll as horizontal
        var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dy = -dy }

        let delta = abs(dx) > abs(dy) ? dx : dy
        targetOffset += delta * 2.5

        // Clamp
        let maxOffset = CGFloat(panels.count - 1) * (panelWidth + panelGap)
        targetOffset = max(0, min(maxOffset, targetOffset))

        // Update focused index
        focusedIndex = Int(round(targetOffset / (panelWidth + panelGap)))
        focusedIndex = max(0, min(panels.count - 1, focusedIndex))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // left arrow
            focusedIndex = max(0, focusedIndex - 1)
            targetOffset = CGFloat(focusedIndex) * (panelWidth + panelGap)
        case 124: // right arrow
            focusedIndex = min(panels.count - 1, focusedIndex + 1)
            targetOffset = CGFloat(focusedIndex) * (panelWidth + panelGap)
        default:
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Display Link (120fps)

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let view = Unmanaged<PaperStripView>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async { view.tick() }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback,
            Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    private func tick() {
        // Smooth spring-like interpolation
        let stiffness: CGFloat = 0.15
        let damping: CGFloat = 0.85
        let diff = targetOffset - scrollOffset
        scrollOffset += diff * stiffness
        scrollOffset = scrollOffset * damping + targetOffset * (1 - damping)

        // Snap when close enough
        if abs(diff) < 0.5 {
            scrollOffset = targetOffset
        }

        updateLayout(animated: false)
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
}

// MARK: - App Setup

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main!.frame
        let windowRect = NSRect(
            x: screen.midX - 700,
            y: screen.midY - 300,
            width: 1400,
            height: 600
        )

        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PaperWM Terminal Canvas"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 800, height: 400)

        let stripView = PaperStripView(frame: window.contentView!.bounds)
        stripView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(stripView)
        window.makeFirstResponder(stripView)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
