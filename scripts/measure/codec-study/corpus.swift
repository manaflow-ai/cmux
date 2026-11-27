// The codec study's corpus (README.md): cmux-like screens drawn offscreen at 2x, so a run needs no
// Screen Recording grant, plus the repo's committed screenshots, each written as an opaque sRGB PNG.
//
//   swiftc -O -o codec-study-corpus corpus.swift
//   codec-study-corpus render OUT_DIR             8 scenes: terminal, chat, web, code; light and dark
//   codec-study-corpus prepare IN OUT [LONG_EDGE]  an opaque sRGB copy of IN, scaled down so its long
//                                                  edge is LONG_EDGE (exit 3 when IN is already smaller)
//
// The scenes are deterministic (one seeded generator), at 1512 x 982 pt, the default scaled size of
// a 14-inch MacBook Pro, so a frame is 3024 x 1964 px.

import AppKit
import Foundation
import ImageIO

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("codec-study-corpus: \(message)\n".utf8))
    exit(code)
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// An opaque 8-bit sRGB context (no alpha), so every codec sees the same RGB pixels.
func context(_ width: Int, _ height: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fail("no \(width)x\(height) context") }
    return ctx
}

func writePNG(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { fail("cannot write \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot finish \(path)") }
}

// MARK: prepare

func prepare(_ input: String, _ output: String, _ longEdge: Int?) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("not an image: \(input)") }
    var width = image.width, height = image.height
    if let longEdge {
        let long = max(width, height)
        if long <= longEdge { exit(3) }
        let scale = Double(longEdge) / Double(long)
        width = max(1, Int((Double(width) * scale).rounded()))
        height = max(1, Int((Double(height) * scale).rounded()))
    }
    let ctx = context(width, height)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) // a transparent screenshot over white
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    writePNG(ctx.makeImage()!, output)
}

// MARK: scenes

var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
func next(_ bound: Int) -> Int {
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
    return Int(rng % UInt64(bound))
}
func pick<T>(_ items: [T]) -> T { items[next(items.count)] }

struct Theme {
    let dark: Bool
    var background: NSColor { dark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : .white }
    var sidebar: NSColor { dark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1) : NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1) }
    var panel: NSColor { dark ? NSColor(srgbRed: 0.19, green: 0.19, blue: 0.21, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1) }
    var text: NSColor { dark ? NSColor(srgbRed: 0.90, green: 0.90, blue: 0.91, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1) }
    var dim: NSColor { dark ? NSColor(srgbRed: 0.58, green: 0.58, blue: 0.62, alpha: 1) : NSColor(srgbRed: 0.45, green: 0.45, blue: 0.48, alpha: 1) }
    var accent: NSColor { NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1) }
    var green: NSColor { dark ? NSColor(srgbRed: 0.45, green: 0.85, blue: 0.45, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.55, blue: 0.15, alpha: 1) }
    var red: NSColor { dark ? NSColor(srgbRed: 1.0, green: 0.45, blue: 0.42, alpha: 1) : NSColor(srgbRed: 0.78, green: 0.12, blue: 0.10, alpha: 1) }
    var yellow: NSColor { dark ? NSColor(srgbRed: 0.95, green: 0.80, blue: 0.35, alpha: 1) : NSColor(srgbRed: 0.60, green: 0.42, blue: 0.0, alpha: 1) }
    var purple: NSColor { dark ? NSColor(srgbRed: 0.80, green: 0.55, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.55, green: 0.15, blue: 0.70, alpha: 1) }
    var teal: NSColor { dark ? NSColor(srgbRed: 0.40, green: 0.82, blue: 0.85, alpha: 1) : NSColor(srgbRed: 0.05, green: 0.45, blue: 0.50, alpha: 1) }
}

let size = NSSize(width: 1512, height: 982)
let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
let monoSmall = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
let body = NSFont.systemFont(ofSize: 14)
let small = NSFont.systemFont(ofSize: 12)

/// Draws `text` with its top-left at (x, y) in a flipped (top-down) space.
func draw(_ text: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor) {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: NSPoint(x: x, y: y))
}

func draw(_ runs: [(String, NSColor)], _ x: CGFloat, _ y: CGFloat, _ font: NSFont) {
    let line = NSMutableAttributedString()
    for (text, color) in runs { line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])) }
    line.draw(at: NSPoint(x: x, y: y))
}

func fill(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    radius > 0 ? NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill() : rect.fill()
}

let words = ["stream", "encoder", "frame", "bitrate", "viewer", "host", "decode", "latency", "pixel", "buffer",
             "display", "capture", "packet", "queue", "workspace", "session", "pane", "surface", "socket", "render"]
func sentence(_ count: Int) -> String {
    var parts: [String] = []
    for i in 0 ..< count { parts.append(i == 0 ? pick(words).capitalized : pick(words)) }
    return parts.joined(separator: " ") + "."
}

/// The window chrome every scene shares: a workspace sidebar and a tab bar. Returns the content rect.
func chrome(_ theme: Theme, title: String) -> NSRect {
    fill(NSRect(origin: .zero, size: size), theme.background)
    fill(NSRect(x: 0, y: 0, width: 230, height: size.height), theme.sidebar)
    for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        fill(NSRect(x: 14 + CGFloat(i) * 20, y: 14, width: 12, height: 12), color, radius: 6)
    }
    let names = ["cmux", "cmux-platform", "cmuxterm-hq", "web", "ios", "codec-study", "fleet", "notes"]
    for (i, name) in names.enumerated() {
        let y = 52 + CGFloat(i) * 46
        if i == 5 { fill(NSRect(x: 8, y: y - 4, width: 214, height: 40), theme.panel, radius: 6) }
        draw(name, 20, y, NSFont.systemFont(ofSize: 13, weight: .semibold), theme.text)
        draw("\(next(9) + 1) panes - \(pick(["idle", "running", "waiting", "done"]))", 20, y + 18, small, theme.dim)
    }
    fill(NSRect(x: 230, y: 0, width: size.width - 230, height: 36), theme.sidebar)
    for (i, tab) in [title, "zsh", "README.md", "agent"].enumerated() {
        let x = 240 + CGFloat(i) * 170
        if i == 0 { fill(NSRect(x: x, y: 6, width: 160, height: 26), theme.background, radius: 6) }
        draw(tab, x + 12, 11, small, i == 0 ? theme.text : theme.dim)
    }
    return NSRect(x: 230, y: 36, width: size.width - 230, height: size.height - 36)
}

func terminal(_ theme: Theme) {
    let area = chrome(theme, title: "zsh - cmux")
    var y = area.minY + 10
    let x = area.minX + 14, step: CGFloat = 17
    func line(_ runs: [(String, NSColor)]) { draw(runs, x, y, mono); y += step }
    while y < area.maxY - step {
        switch next(5) {
        case 0:
            line([("leo@mini ", theme.green), ("~/cmux ", theme.teal), ("(feat-cmux-next) ", theme.purple), ("$ git log --oneline -6", theme.text)])
            for _ in 0 ..< 6 {
                let hash = String(format: "%07lx", next(0xFFFFFFF))
                line([(hash + " ", theme.yellow), (sentence(5 + next(5)) + " (#\(30000 + next(9000)))", theme.text)])
            }
        case 1:
            line([("leo@mini ", theme.green), ("~/cmux ", theme.teal), ("$ cargo build -p cmux-rd-host", theme.text)])
            for _ in 0 ..< 5 {
                line([("   Compiling ", theme.green), ("\(pick(words))-\(pick(words)) v0.\(next(9)).\(next(20)) (/cmux-tui/crates/\(pick(words)))", theme.text)])
            }
            line([("    Finished ", theme.green), ("`dev` profile [unoptimized + debuginfo] target(s) in \(next(60)).\(next(99))s", theme.text)])
        case 2:
            line([("leo@mini ", theme.green), ("~/cmux ", theme.teal), ("$ ls -la scripts/measure", theme.text)])
            for _ in 0 ..< 5 {
                let name = "\(pick(words))-\(pick(words)).\(pick(["sh", "py", "swift"]))"
                line([("-rw-r--r--  1 leo  staff  \(String(format: "%6ld", next(40000)))  Nov  \(next(9) + 1) 1\(next(9)):\(String(format: "%02ld", next(60)))  ", theme.dim), (name, theme.text)])
            }
        case 3:
            line([("leo@mini ", theme.green), ("~/cmux ", theme.teal), ("$ swift test --filter \(pick(words).capitalized)Tests", theme.text)])
            for _ in 0 ..< 4 {
                let ok = next(6) != 0
                line([(ok ? "  passed " : "  FAILED ", ok ? theme.green : theme.red), ("\(pick(words).capitalized)Tests.test\(pick(words).capitalized)\(pick(words).capitalized) (\(next(900)) ms)", theme.text)])
            }
        default:
            line([("leo@mini ", theme.green), ("~/cmux ", theme.teal), ("$ rg -n \"\(pick(words))\" Packages", theme.text)])
            for _ in 0 ..< 4 {
                line([("Packages/macOS/\(pick(words).capitalized)/\(pick(words).capitalized).swift", theme.purple), (":\(next(900)):", theme.green), ("    let \(pick(words)) = \(pick(words)).\(pick(words))(\(next(4096)))", theme.text)])
            }
        }
    }
}

func chat(_ theme: Theme) {
    let area = chrome(theme, title: "agent")
    var y = area.minY + 20
    let left = area.minX + 60, width = area.width - 120
    while y < area.maxY - 140 {
        // A user turn: a right-aligned bubble.
        let ask = sentence(8 + next(8))
        let askWidth = min(560, CGFloat(ask.count) * 7.4 + 28)
        fill(NSRect(x: left + width - askWidth, y: y, width: askWidth, height: 34), theme.accent.withAlphaComponent(theme.dark ? 0.35 : 0.14), radius: 14)
        draw(ask, left + width - askWidth + 14, y + 9, body, theme.text)
        y += 52
        // The agent's turn: prose, a tool card and sometimes a code block.
        for _ in 0 ..< 2 + next(3) {
            draw(sentence(10 + next(8)) + " " + sentence(6 + next(6)), left, y, body, theme.text)
            y += 22
        }
        fill(NSRect(x: left, y: y + 4, width: 520, height: 30), theme.panel, radius: 8)
        draw([("Ran ", theme.dim), ("cmux-ci run --script scripts/measure/\(pick(words)).sh", theme.text), ("  \(next(90)) s", theme.dim)], left + 12, y + 11, monoSmall)
        y += 46
        if next(2) == 0 {
            let lines = 3 + next(4)
            fill(NSRect(x: left, y: y, width: width * 0.7, height: CGFloat(lines) * 17 + 16), theme.panel, radius: 8)
            for i in 0 ..< lines {
                draw([("let ", theme.purple), ("\(pick(words)) ", theme.text), ("= ", theme.dim), ("\(pick(words)).\(pick(words))(", theme.teal), ("\"\(pick(words))\"", theme.red), (", at: \(next(60)))", theme.text)],
                     left + 14, y + 8 + CGFloat(i) * 17, mono)
            }
            y += CGFloat(lines) * 17 + 30
        }
    }
    // The composer.
    fill(NSRect(x: left, y: area.maxY - 80, width: width, height: 56), theme.panel, radius: 14)
    draw("Ask the agent, or type / for commands", left + 18, area.maxY - 61, body, theme.dim)
}

func web(_ theme: Theme) {
    let area = chrome(theme, title: "docs - browser")
    // The address bar and the site's nav.
    fill(NSRect(x: area.minX, y: area.minY, width: area.width, height: 40), theme.sidebar)
    fill(NSRect(x: area.minX + 90, y: area.minY + 7, width: area.width - 180, height: 26), theme.background, radius: 13)
    draw("https://docs.example.com/guides/\(pick(words))-\(pick(words))", area.minX + 110, area.minY + 13, small, theme.dim)
    let top = area.minY + 40
    fill(NSRect(x: area.minX, y: top, width: area.width, height: 56), theme.background)
    draw("Example Docs", area.minX + 40, top + 16, NSFont.systemFont(ofSize: 20, weight: .bold), theme.text)
    for (i, item) in ["Guides", "API", "Pricing", "Blog", "Changelog"].enumerated() {
        draw(item, area.minX + 420 + CGFloat(i) * 96, top + 20, NSFont.systemFont(ofSize: 14, weight: .medium), theme.dim)
    }
    // A photographic hero: smooth gradients with grain, the content lossless codecs pay most for.
    let hero = NSRect(x: area.minX + 40, y: top + 70, width: area.width - 80, height: 250)
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.saveGState()
        ctx.clip(to: hero)
        let colors = [CGColor(srgbRed: 0.10, green: 0.25, blue: 0.55, alpha: 1), CGColor(srgbRed: 0.55, green: 0.20, blue: 0.55, alpha: 1),
                      CGColor(srgbRed: 0.95, green: 0.55, blue: 0.30, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: srgb, colors: colors, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: hero.minX, y: hero.minY), end: CGPoint(x: hero.maxX, y: hero.maxY), options: [])
        for _ in 0 ..< 9000 {
            let shade = CGFloat(next(1000)) / 1000
            ctx.setFillColor(CGColor(gray: shade, alpha: 0.08))
            ctx.fill(CGRect(x: hero.minX + CGFloat(next(Int(hero.width))), y: hero.minY + CGFloat(next(Int(hero.height))), width: 1.5, height: 1.5))
        }
        ctx.restoreGState()
    }
    draw("Stream every \(pick(words)) to every \(pick(words))", hero.minX + 40, hero.minY + 90, NSFont.systemFont(ofSize: 34, weight: .bold), .white)
    draw(sentence(12), hero.minX + 40, hero.minY + 140, NSFont.systemFont(ofSize: 17), NSColor(white: 1, alpha: 0.9))
    // A left nav and the article.
    var y = hero.maxY + 30
    for i in 0 ..< 14 where y + CGFloat(i) * 26 < area.maxY - 20 {
        draw("\(pick(words).capitalized) \(pick(words))", area.minX + 40, y + CGFloat(i) * 26, NSFont.systemFont(ofSize: 13), i == 2 ? theme.accent : theme.dim)
    }
    let article = area.minX + 260
    draw("\(pick(words).capitalized) and \(pick(words)) in practice", article, y, NSFont.systemFont(ofSize: 24, weight: .semibold), theme.text)
    y += 44
    while y < area.maxY - 140 {
        for _ in 0 ..< 3 {
            draw(sentence(14 + next(6)) + " " + sentence(8), article, y, NSFont.systemFont(ofSize: 15), theme.text)
            y += 24
        }
        y += 14
    }
    // A table.
    let columns: [CGFloat] = [0, 220, 380, 540]
    for row in 0 ..< 4 {
        let rowY = y + CGFloat(row) * 28
        if rowY > area.maxY - 24 { break }
        if row == 0 { fill(NSRect(x: article - 8, y: rowY - 4, width: 700, height: 26), theme.panel) }
        for (c, offset) in columns.enumerated() {
            let cell = row == 0 ? ["Codec", "Encode", "Decode", "Bytes"][c] : (c == 0 ? pick(words) : "\(next(900)) \(c == 3 ? "KB" : "ms")")
            draw(cell, article + offset, rowY, NSFont.systemFont(ofSize: 13, weight: row == 0 ? .semibold : .regular), theme.text)
        }
    }
}

func code(_ theme: Theme) {
    let area = chrome(theme, title: "Perception.swift")
    let gutter = area.minX + 56, split = area.minX + area.width * 0.62
    fill(NSRect(x: area.minX, y: area.minY, width: 50, height: area.height), theme.sidebar)
    fill(NSRect(x: split, y: area.minY, width: 1, height: area.height), theme.panel)
    var y = area.minY + 8
    var number = 1 + next(400)
    let keywords = ["let", "var", "func", "guard", "return", "if", "struct", "private", "static"]
    while y < area.maxY - 16 {
        draw(String(format: "%4ld", number), area.minX + 6, y, mono, theme.dim)
        let indent = String(repeating: "    ", count: next(3))
        switch next(5) {
        case 0: draw([(indent + "// ", theme.dim), (sentence(6 + next(5)), theme.dim)], gutter, y, mono)
        case 1: draw([(indent + pick(keywords) + " ", theme.purple), (pick(words), theme.text), (": ", theme.dim), (pick(words).capitalized, theme.teal), (" = ", theme.dim), ("\"\(pick(words)) \(pick(words))\"", theme.red)], gutter, y, mono)
        case 2: draw([(indent + "func ", theme.purple), ("\(pick(words))\(pick(words).capitalized)", theme.text), ("(_ \(pick(words)): ", theme.dim), ("Int", theme.teal), (") -> ", theme.dim), ("CGImage?", theme.teal), (" {", theme.dim)], gutter, y, mono)
        case 3: draw([(indent + "guard ", theme.purple), ("let \(pick(words)) = \(pick(words)).\(pick(words))(\(next(4096)))", theme.text), (" else { ", theme.dim), ("return nil", theme.purple), (" }", theme.dim)], gutter, y, mono)
        default: draw([(indent + "\(pick(words)).\(pick(words)) += ", theme.text), ("\(next(512))", theme.yellow), (" // \(pick(words))", theme.dim)], gutter, y, mono)
        }
        y += 17
        number += 1
    }
    // The diff pane on the right: added and removed lines on tinted rows.
    y = area.minY + 8
    while y < area.maxY - 16 {
        let kind = next(4)
        let tint: NSColor? = kind == 0 ? theme.green.withAlphaComponent(0.16) : kind == 1 ? theme.red.withAlphaComponent(0.16) : nil
        if let tint { fill(NSRect(x: split + 1, y: y - 1, width: area.maxX - split - 1, height: 17), tint) }
        draw([(kind == 0 ? "+ " : kind == 1 ? "- " : "  ", kind == 0 ? theme.green : kind == 1 ? theme.red : theme.dim),
              ("\(pick(words)).\(pick(words))(\(next(100)), \(pick(words)))", theme.text)], split + 12, y, monoSmall)
        y += 17
    }
}

func render(_ outDir: String) {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let scenes: [(String, (Theme) -> Void)] = [("terminal", terminal), ("chat", chat), ("web", web), ("code", code)]
    for (name, scene) in scenes {
        for dark in [false, true] {
            let pixelsWide = Int(size.width) * 2, pixelsHigh = Int(size.height) * 2
            let ctx = context(pixelsWide, pixelsHigh)
            // Top-down points at 2x, as a Retina window draws.
            ctx.translateBy(x: 0, y: CGFloat(pixelsHigh))
            ctx.scaleBy(x: 2, y: -2)
            let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            scene(Theme(dark: dark))
            NSGraphicsContext.restoreGraphicsState()
            let path = "\(outDir)/synthetic-\(name)-\(dark ? "dark" : "light").png"
            writePNG(ctx.makeImage()!, path)
            print(path)
        }
    }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "render" where args.count == 3:
    render(args[2])
case "prepare" where args.count == 4 || args.count == 5:
    prepare(args[2], args[3], args.count == 5 ? Int(args[4]) : nil)
default:
    fail("usage: codec-study-corpus render OUT_DIR | prepare IN OUT [LONG_EDGE]")
}
