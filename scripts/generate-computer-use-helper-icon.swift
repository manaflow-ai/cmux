#!/usr/bin/env swift
// Regenerates Resources/ComputerUseHelperIcon.icns — the static icon macOS
// shows for the "cmux Computer Use" helper in System Settings.
//
// The artwork MUST stay in sync with ComputerUseHelperIconRenderer and
// ComputerUseCursorArtwork in Sources/App/AgentCursorPointerView.swift: the
// cmux app-icon tile (vertical #313131→#141414 gradient with a soft top rim
// highlight) carrying the live cursor's kite and brand gradient. An .icns
// cannot adapt per appearance, so this bakes the dark tile — the
// brand-defining cmux variant.
//
// Usage: swift scripts/generate-computer-use-helper-icon.swift
// Writes the .icns beside this script's repo root and prints the path.

import AppKit

let plateCornerRadius: CGFloat = 224
let cursorTranslation = CGPoint(x: 293.4, y: 293.4)
let cursorScale: CGFloat = 44.8
let rimWidth: CGFloat = 14
let canvas = CGRect(x: 0, y: 0, width: 1_024, height: 1_024)

func cursorPath() -> CGPath {
    let kite = CGMutablePath()
    kite.move(to: CGPoint(x: 0.68, y: 1.83))
    kite.addLine(to: CGPoint(x: 3.63, y: 9.78))
    kite.addQuadCurve(to: CGPoint(x: 5.3, y: 9.66), control: CGPoint(x: 4.67, y: 12.59))
    kite.addLine(to: CGPoint(x: 5.44, y: 9.01))
    kite.addQuadCurve(to: CGPoint(x: 9.01, y: 5.44), control: CGPoint(x: 6.08, y: 6.08))
    kite.addLine(to: CGPoint(x: 9.66, y: 5.3))
    kite.addQuadCurve(to: CGPoint(x: 9.78, y: 3.63), control: CGPoint(x: 12.59, y: 4.67))
    kite.addLine(to: CGPoint(x: 1.83, y: 0.68))
    kite.addQuadCurve(to: CGPoint(x: 0.68, y: 1.83), control: CGPoint(x: 0, y: 0))
    kite.closeSubpath()
    return kite
}

func render() -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: Int(canvas.width),
        height: Int(canvas.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    // Flip to y-down so the shared SVG geometry keeps the cursor's up-left
    // direction, exactly like the runtime renderer.
    context.translateBy(x: 0, y: canvas.height)
    context.scaleBy(x: 1, y: -1)

    let plate = CGPath(
        roundedRect: canvas,
        cornerWidth: plateCornerRadius,
        cornerHeight: plateCornerRadius,
        transform: nil
    )

    context.saveGState()
    context.addPath(plate)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(gray: 0x31 / 255.0, alpha: 1.0),
            CGColor(gray: 0x14 / 255.0, alpha: 1.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: canvas.midX, y: 0),
            end: CGPoint(x: canvas.midX, y: canvas.height),
            options: []
        )
    }
    context.restoreGState()

    let rim = plate.copy(
        strokingWithWidth: rimWidth * 2,
        lineCap: .butt,
        lineJoin: .miter,
        miterLimit: 10
    )
    context.saveGState()
    context.addPath(plate)
    context.clip()
    context.addPath(rim)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(gray: 1.0, alpha: 0.34),
            CGColor(gray: 1.0, alpha: 0.05),
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: canvas.midX, y: 0),
            end: CGPoint(x: canvas.midX, y: canvas.height),
            options: []
        )
    }
    context.restoreGState()

    context.saveGState()
    context.translateBy(x: cursorTranslation.x, y: cursorTranslation.y)
    context.scaleBy(x: cursorScale, y: cursorScale)
    let kite = cursorPath()
    context.addPath(kite)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [0x12 / 255.0, 0xC7 / 255.0, 0xF5 / 255.0, 1.0])!,
            CGColor(colorSpace: colorSpace, components: [0x2D / 255.0, 0x8C / 255.0, 0xFF / 255.0, 1.0])!,
            CGColor(colorSpace: colorSpace, components: [0x6C / 255.0, 0x5C / 255.0, 0xFF / 255.0, 1.0])!,
        ] as CFArray,
        locations: [0.0, 0.5, 1.0]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0.68, y: 0.68),
            end: CGPoint(x: 11.0, y: 11.0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    context.restoreGState()

    return context.makeImage()
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outputURL = repoRoot.appendingPathComponent("Resources/ComputerUseHelperIcon.icns")

guard let master = render() else {
    FileHandle.standardError.write(Data("error: failed to render icon\n".utf8))
    exit(1)
}

let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("ComputerUseHelperIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, side: Int, name: String) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw NSError(domain: "icon", code: 1) }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let scaled = context.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let url = iconsetURL.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else { throw NSError(domain: "icon", code: 3) }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "icon", code: 4) }
}

for side in [16, 32, 128, 256, 512] {
    try writePNG(master, side: side, name: "icon_\(side)x\(side).png")
    try writePNG(master, side: side * 2, name: "icon_\(side)x\(side)@2x.png")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetURL)
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("error: iconutil failed\n".utf8))
    exit(1)
}
print(outputURL.path)
