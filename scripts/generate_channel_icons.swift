#!/usr/bin/env swift
// Builds every macOS app icon of cmux-next from the cmux logo in AppIcon.icon.
//
// The cmux logo is the chevron layer of the Icon Composer document
// AppIcon.icon. This script draws it full-bleed: the logo on an opaque 1024 pt
// background, edge to edge. macOS 26 and later mask such an icon to their
// rounded-rectangle shape at full size. An icon that already has the shape
// with a transparent margin is not full-bleed, and macOS 26 puts it, shrunk,
// inside a grey rounded square ("icon jail"). cmux-next requires macOS 26
// (LSMinimumSystemVersion 26.0 in the fleet and nightly builds).
//
// It writes:
//   - Assets.xcassets/AppIcon.appiconset: light and dark, every size.
//   - AppIcon-Debug / -RC / -Nightly.appiconset: the light icon with the DEV,
//     RC or NIGHTLY banner across the bottom (the system mask rounds it).
// The fleet and nightly builds compile Assets.xcassets with the resources
// lane's actool, which takes no Icon Composer document, so these sets are the
// icon every cmux-next build ships.
//
// Usage: swift scripts/generate_channel_icons.swift   (from the repo root)

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct Channel {
    let set: String
    let label: String
    let color: (CGFloat, CGFloat, CGFloat)
}

private let channels = [
    Channel(set: "AppIcon-Debug", label: "DEV", color: (255, 107, 0)),
    Channel(set: "AppIcon-RC", label: "RC", color: (42, 170, 94)),
    Channel(set: "AppIcon-Nightly", label: "NIGHTLY", color: (140, 60, 220)),
]

/// File name and pixel size of each image in an app icon set.
private let files: [(String, Int)] = [("16.png", 16), ("16@2x.png", 32), ("32.png", 32), ("32@2x.png", 64),
                                      ("128.png", 128), ("128@2x.png", 256), ("256.png", 256),
                                      ("256@2x.png", 512), ("512.png", 512), ("512@2x.png", 1024)]

/// Background gradients, top to bottom, of the stable icon's art
/// (web/public/brand/app-icon-light.png and app-icon-dark.png).
private let lightBackground = (0xFFFFFF, 0xEEEEEE)
private let darkBackground = (0x424243, 0x191919)

private let canvas = 1024
private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let assets = root.appendingPathComponent("Assets.xcassets")
private let stableIcon = root.appendingPathComponent("AppIcon.icon")

private func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("cannot read \(url.path)")
    }
    return image
}

private func context(_ width: Int, _ height: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("no context")
    }
    return ctx
}

private func color(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

/// The logo layer of AppIcon.icon and where Icon Composer places it: its
/// centre is the canvas centre moved by translation-in-points (y down), at scale.
private struct Logo {
    let image: CGImage
    let rect: CGRect

    init() {
        let json = stableIcon.appendingPathComponent("icon.json")
        guard let doc = try? JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any],
              let groups = doc["groups"] as? [[String: Any]],
              let layer = (groups.first?["layers"] as? [[String: Any]])?.first,
              let name = layer["image-name"] as? String else { fatalError("bad \(json.path)") }
        image = load(stableIcon.appendingPathComponent("Assets/\(name)"))
        let position = layer["position"] as? [String: Any]
        let scale = position?["scale"] as? CGFloat ?? 1
        let offset = position?["translation-in-points"] as? [CGFloat] ?? [0, 0]
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        let mid = CGFloat(canvas) / 2
        rect = CGRect(x: mid + offset[0] - w / 2, y: mid - offset[1] - h / 2, width: w, height: h)
    }
}

/// The full-bleed 1024 px icon: background gradient, then the logo.
private func master(_ logo: Logo, background: (Int, Int)) -> CGImage {
    let ctx = context(canvas, canvas)
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(background.0), color(background.1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas), end: .zero, options: [])
    ctx.interpolationQuality = .high
    ctx.draw(logo.image, in: logo.rect)
    return ctx.makeImage()!
}

/// A channel banner across the bottom 18% of the canvas, label centred a
/// little high: the system mask's rounded corners take more of its lower edge.
private func drawBanner(_ channel: Channel, in ctx: CGContext) {
    let side = CGFloat(canvas)
    let banner = CGRect(x: 0, y: 0, width: side, height: (side * 0.18).rounded())
    let (r, g, b) = channel.color
    ctx.setFillColor(CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1))
    ctx.fill(banner)
    let font = NSFont.systemFont(ofSize: banner.height * 0.55, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let text = CTLineCreateWithAttributedString(NSAttributedString(string: channel.label, attributes: attributes))
    let glyphs = CTLineGetImageBounds(text, ctx)
    ctx.textPosition = CGPoint(x: banner.midX - glyphs.width / 2 - glyphs.minX,
                               y: banner.midY + banner.height * 0.04 - glyphs.height / 2 - glyphs.minY)
    CTLineDraw(text, ctx)
}

private func withBanner(_ base: CGImage, _ channel: Channel) -> CGImage {
    let ctx = context(canvas, canvas)
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    drawBanner(channel, in: ctx)
    return ctx.makeImage()!
}

private func resized(_ image: CGImage, _ size: Int) -> CGImage {
    if size == image.width { return image }
    let ctx = context(size, size)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

private func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

private func writeSet(_ set: String, _ image: CGImage, suffix: String = "") {
    for (file, size) in files {
        let name = suffix.isEmpty ? file : file.replacingOccurrences(of: ".png", with: "\(suffix).png")
        write(resized(image, size), to: assets.appendingPathComponent("\(set).appiconset/\(name)"))
    }
}

private let logo = Logo()
private let light = master(logo, background: lightBackground)
writeSet("AppIcon", light)
writeSet("AppIcon", master(logo, background: darkBackground), suffix: "_dark")
print("wrote AppIcon")
for channel in channels {
    writeSet(channel.set, withBanner(light, channel))
    print("wrote \(channel.set)")
}
