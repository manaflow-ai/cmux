#!/usr/bin/env swift
// Builds the DEV, RC and NIGHTLY app icon sets from the stable AppIcon set.
//
// macOS 14 and 15 draw an asset-catalog app icon exactly as shipped: no mask,
// no padding. The stable icon follows Apple's macOS icon grid (an 824 pt
// rounded rectangle centred in the 1024 pt canvas). The old channel icons drew
// their banner across the full canvas, and the NIGHTLY set was an opaque white
// square, so the Dock showed them larger than every other app. This script
// keeps each channel icon inside the stable icon's shape: the banner is clipped
// to the stable artwork's alpha, so the silhouette and the size stay the same.
//
// It first rebuilds every size of the stable AppIcon set, light and dark,
// from its 1024 px master (512@2x.png, the cmux logo; the same art as
// web/public/brand/app-icon-light.png and app-icon-dark.png). The smaller
// files were older renders: 512.png (= 256@2x.png) had a dotted rim and a
// lighter chevron, and macOS 26 and later judge an asset-catalog icon by its
// 512 pt image, so they drew the stable icon shrunk inside a grey square.
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

private let files = ["16.png", "16@2x.png", "32.png", "32@2x.png", "128.png", "128@2x.png",
                     "256.png", "256@2x.png", "512.png", "512@2x.png"]

/// Pixel width of each file in `files`.
private let pixels = [16, 32, 32, 64, 128, 256, 256, 512, 512, 1024]

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let assets = root.appendingPathComponent("Assets.xcassets")

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

/// The bounding box (bottom-left origin) of the pixels whose alpha is at least half.
private func artBounds(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    let ctx = context(w, h)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let row = ctx.bytesPerRow
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w where data[y * row + x * 4 + 3] >= 128 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // Memory row 0 is the top of the image; convert to the bottom-left origin CG draws in.
    return CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

private func render(base: CGImage, channel: Channel) -> CGImage {
    let w = base.width, h = base.height
    let full = CGRect(x: 0, y: 0, width: w, height: h)
    let art = artBounds(base)
    let bannerHeight = (art.height * 0.18).rounded()
    let banner = CGRect(x: art.minX, y: art.minY, width: art.width, height: bannerHeight)
    let (r, g, b) = channel.color

    // The banner, cut to the stable icon's silhouette.
    let bannerCtx = context(w, h)
    bannerCtx.setFillColor(CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1))
    bannerCtx.fill(banner)
    bannerCtx.setBlendMode(.destinationIn)
    bannerCtx.draw(base, in: full)
    let clippedBanner = bannerCtx.makeImage()!

    let ctx = context(w, h)
    ctx.interpolationQuality = .high
    ctx.draw(base, in: full)
    ctx.draw(clippedBanner, in: full)

    // White label centred in the banner, at most 70% of the artwork width.
    if w >= 32 {
        var size = bannerHeight * 0.62
        func line(_ size: CGFloat) -> CTLine {
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            return CTLineCreateWithAttributedString(NSAttributedString(string: channel.label, attributes: attributes))
        }
        var text = line(size)
        while CTLineGetTypographicBounds(text, nil, nil, nil) > Double(art.width * 0.7) {
            size *= 0.95
            text = line(size)
        }
        let glyphs = CTLineGetImageBounds(text, ctx)
        ctx.textPosition = CGPoint(x: banner.midX - glyphs.width / 2 - glyphs.minX,
                                   y: banner.midY - glyphs.height / 2 - glyphs.minY)
        CTLineDraw(text, ctx)
    }
    return ctx.makeImage()!
}

private func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

private func resized(_ image: CGImage, to size: Int) -> CGImage {
    let ctx = context(size, size)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

let stable = assets.appendingPathComponent("AppIcon.appiconset")
for suffix in ["", "_dark"] {
    let master = load(stable.appendingPathComponent("512@2x\(suffix).png"))
    for (file, size) in zip(files, pixels) where size < master.width {
        let name = file.replacingOccurrences(of: ".png", with: "\(suffix).png")
        write(resized(master, to: size), to: stable.appendingPathComponent(name))
    }
}
print("wrote AppIcon")

for channel in channels {
    for file in files {
        let base = load(assets.appendingPathComponent("AppIcon.appiconset/\(file)"))
        write(render(base: base, channel: channel),
              to: assets.appendingPathComponent("\(channel.set).appiconset/\(file)"))
    }
    print("wrote \(channel.set)")
}
