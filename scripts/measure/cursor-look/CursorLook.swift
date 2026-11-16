// cursor-look: macOS's own cursor next to the screen-sharing viewer's drawing of it.
//
// A window with one column per cursor (arrow, I-beam, pointing hand, or the
// names given). Top row: an empty view whose cursor rect is that cursor, so the
// window server draws its real pointer there. Bottom row: the cursor's NSCursor
// image drawn the way the iOS viewer draws a stream cursor
// (CmuxScreenKitUI ScreenViewController.updateCursor): at its point size, hotspot
// on the cell's center, with ScreenCursorShape.shadow (black at 0.45, layer
// shadow radius blur / 2, offset 1 pt down). For each column it moves the
// pointer onto the top cell and captures the window with the pointer
// (`screencapture -C`), then writes one image of all columns, enlarged.
//
// It needs a logged-in console and Screen Recording for the process that runs
// it: a display step (`cmux-ci run --display`), see scripts/measure/cursor-look.sh.
//
// usage: CursorLook OUT_DIR [--dark] [--zoom N] [cursor...]
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The viewer's shadow, in the Mac's points (ScreenCursorShape.shadow).
let shadowOpacity: Float = 0.45
let shadowBlur: CGFloat = 2
let shadowOffsetDown: CGFloat = 1

let named: [String: NSCursor] = [
    "arrow": .arrow, "ibeam": .iBeam, "hand": .pointingHand, "closedhand": .closedHand, "openhand": .openHand,
    "crosshair": .crosshair, "resize-lr": .resizeLeftRight, "resize-ud": .resizeUpDown, "not-allowed": .operationNotAllowed,
]

var arguments = Array(CommandLine.arguments.dropFirst())
guard let outPath = arguments.first else {
    FileHandle.standardError.write(Data("usage: CursorLook OUT_DIR [--dark] [--zoom N] [cursor...]\n".utf8))
    exit(2)
}
arguments.removeFirst()
var dark = false
var zoom = 4
var names: [String] = []
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--dark": dark = true
    case "--zoom": zoom = Int(arguments.removeFirst()) ?? zoom
    default: names.append(argument)
    }
}
if names.isEmpty { names = ["arrow", "ibeam", "hand"] }
for name in names where named[name] == nil {
    FileHandle.standardError.write(Data("cursor-look: no cursor \(name); known: \(named.keys.sorted().joined(separator: ", "))\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: outPath, isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let cell = CGSize(width: 120, height: 100)
/// The window content's top left, in global points from the top left (CGEvent space).
let contentOrigin = CGPoint(x: 120, y: 160)

final class RealCell: NSView {
    let cursor: NSCursor
    init(frame: NSRect, cursor: NSCursor) { self.cursor = cursor; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("unused") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
}

final class Look: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var cells: [RealCell] = []
    var report: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = CGSize(width: cell.width * CGFloat(names.count), height: cell.height * 2)
        let primary = NSScreen.screens[0].frame
        let frame = NSRect(x: contentOrigin.x, y: primary.height - contentOrigin.y - size.height, width: size.width, height: size.height)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "cursor-look"
        window.level = .floating
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
        let scale = window.backingScaleFactor
        for (index, name) in names.enumerated() {
            let cursor = named[name]!
            let real = RealCell(frame: NSRect(x: CGFloat(index) * cell.width, y: cell.height, width: cell.width, height: cell.height), cursor: cursor)
            content.addSubview(real)
            cells.append(real)
            let imageSize = cursor.image.size
            var rect = NSRect(origin: .zero, size: imageSize)
            report.append(["cursor": name, "points": [imageSize.width, imageSize.height],
                           "hotspot": [cursor.hotSpot.x, cursor.hotSpot.y], "backingScale": scale])
            guard let image = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)]) else { continue }
            let layer = CALayer()
            layer.contents = image
            layer.contentsScale = scale
            let center = CGPoint(x: CGFloat(index) * cell.width + cell.width / 2, y: cell.height / 2)
            // Layers here are bottom left based; the hotspot is from the image's top left.
            layer.frame = CGRect(x: center.x - cursor.hotSpot.x, y: center.y - (imageSize.height - cursor.hotSpot.y),
                                 width: imageSize.width, height: imageSize.height)
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = shadowOpacity
            layer.shadowRadius = shadowBlur / 2
            layer.shadowOffset = CGSize(width: 0, height: -shadowOffsetDown)
            content.layer?.addSublayer(layer)
        }
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.capture(0, size: size) }
    }

    /// Moves the pointer onto column `index`'s top cell, then captures the window region with it.
    func capture(_ index: Int, size: CGSize) {
        guard index < cells.count else { return finish(size: size) }
        let center = CGPoint(x: contentOrigin.x + CGFloat(index) * cell.width + cell.width / 2, y: contentOrigin.y + cell.height / 2)
        CGWarpMouseCursorPosition(center)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        cells[index].cursor.set()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.cells[index].cursor.set()
            let file = out.appendingPathComponent("column-\(index).png").path
            let region = "\(Int(contentOrigin.x)),\(Int(contentOrigin.y)),\(Int(size.width)),\(Int(size.height))"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-C", "-R", region, file]
            do { try process.run(); process.waitUntilExit() } catch {}
            if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: file) {
                FileHandle.standardError.write(Data("cursor-look: screencapture failed (\(process.terminationStatus)); Screen Recording?\n".utf8))
                exit(1)
            }
            self.capture(index + 1, size: size)
        }
    }

    /// One image: column i from capture i (its real pointer over its drawn twin), enlarged `zoom` times.
    func finish(size: CGSize) {
        var columns: [CGImage] = []
        for index in cells.indices {
            let url = out.appendingPathComponent("column-\(index).png") as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(1) }
            let pixelsPerPoint = CGFloat(image.width) / size.width
            let crop = CGRect(x: CGFloat(index) * cell.width * pixelsPerPoint, y: 0, width: cell.width * pixelsPerPoint, height: CGFloat(image.height))
            guard let column = image.cropping(to: crop.integral) else { exit(1) }
            columns.append(column)
        }
        let width = columns.reduce(0) { $0 + $1.width } * zoom
        let height = (columns.map(\.height).max() ?? 0) * zoom
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { exit(1) }
        context.interpolationQuality = .none
        var x = 0
        for column in columns {
            context.draw(column, in: CGRect(x: x, y: height - column.height * zoom, width: column.width * zoom, height: column.height * zoom))
            x += column.width * zoom
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(out.appendingPathComponent("cursor-look.png") as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { exit(1) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { exit(1) }
        let json = try? JSONSerialization.data(withJSONObject: ["dark": dark, "zoom": zoom, "rows": ["top: macOS pointer", "bottom: viewer drawing"],
                                                                "cursors": report], options: [.prettyPrinted, .sortedKeys])
        try? json?.write(to: out.appendingPathComponent("cursor-look.json"))
        print("cursor-look: \(out.appendingPathComponent("cursor-look.png").path)")
        exit(0)
    }
}

let app = NSApplication.shared
let look = Look()
app.delegate = look
app.setActivationPolicy(.regular)
DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
    FileHandle.standardError.write(Data("cursor-look: timed out\n".utf8))
    exit(1)
}
app.run()
