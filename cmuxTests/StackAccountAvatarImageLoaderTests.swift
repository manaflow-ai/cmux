import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The avatar loader must hand the hosted renderer a square bitmap that
/// keeps the center of the profile picture and is already clipped to a
/// circle. The circle lives in the bitmap so the hosted `NSImageView` needs
/// no SwiftUI `clipShape`: SwiftUI masks over hosted AppKit views go blank
/// after a while on Intel Macs running macOS 15.
@Suite("Stack account avatar image loader")
struct StackAccountAvatarImageLoaderTests {
    @Test @MainActor func circularImageCenterCropsWideSourceAtRequestedScale() throws {
        // 40x20 source: red | green | blue columns, 10/20/10 wide.
        let data = try #require(Self.pngData(width: 40, height: 20) { x, _ in
            x < 10 ? .red : (x < 30 ? .green : .blue)
        })
        let image = try #require(StackAccountAvatarImageLoader.circularImage(from: data, pointSize: 10, scale: 2))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)

        #expect(image.size == NSSize(width: 10, height: 10))
        #expect(bitmap.pixelsWide == 20)
        #expect(bitmap.pixelsHigh == 20)
        // Only the green center band survives the crop.
        for x in [1, 10, 18] {
            let color = try #require(bitmap.colorAt(x: x, y: 10)?.usingColorSpace(.deviceRGB))
            #expect(color.greenComponent > 0.8, "x=\(x)")
            #expect(color.redComponent < 0.2, "x=\(x)")
            #expect(color.blueComponent < 0.2, "x=\(x)")
        }
    }

    @Test @MainActor func circularImageCenterCropsTallSource() throws {
        // 20x40 source: red top band, green middle, blue bottom band.
        let data = try #require(Self.pngData(width: 20, height: 40) { _, y in
            y < 10 ? .red : (y < 30 ? .green : .blue)
        })
        let image = try #require(StackAccountAvatarImageLoader.circularImage(from: data, pointSize: 8, scale: 1))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)

        #expect(bitmap.pixelsWide == 8)
        #expect(bitmap.pixelsHigh == 8)
        for y in [0, 4, 7] {
            let color = try #require(bitmap.colorAt(x: 4, y: y)?.usingColorSpace(.deviceRGB))
            #expect(color.greenComponent > 0.8, "y=\(y)")
        }
    }

    @Test @MainActor func circularImageClipsCornersInsideTheBitmap() throws {
        let data = try #require(Self.pngData(width: 30, height: 30) { _, _ in .green })
        let image = try #require(StackAccountAvatarImageLoader.circularImage(from: data, pointSize: 20, scale: 2))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)

        #expect(bitmap.pixelsWide == 40)
        #expect(bitmap.pixelsHigh == 40)
        let center = try #require(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        #expect(center.alphaComponent > 0.99)
        #expect(center.greenComponent > 0.8)
        // The square source is fully opaque; only the circular clip can make
        // the corners transparent.
        for (x, y) in [(0, 0), (39, 0), (0, 39), (39, 39), (2, 2), (37, 37)] {
            let corner = try #require(bitmap.colorAt(x: x, y: y))
            #expect(corner.alphaComponent < 0.01, "corner (\(x), \(y))")
        }
        // Points just inside the circle stay opaque.
        for (x, y) in [(20, 1), (1, 20), (38, 20), (20, 38)] {
            let edge = try #require(bitmap.colorAt(x: x, y: y))
            #expect(edge.alphaComponent > 0.5, "edge (\(x), \(y))")
        }
    }

    @Test @MainActor func circularImageRejectsUndecodableDataAndInvalidSizes() throws {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        #expect(StackAccountAvatarImageLoader.circularImage(from: garbage, pointSize: 10) == nil)

        let data = try #require(Self.pngData(width: 4, height: 4) { _, _ in .green })
        #expect(StackAccountAvatarImageLoader.circularImage(from: data, pointSize: 0) == nil)
        #expect(StackAccountAvatarImageLoader.circularImage(from: data, pointSize: .nan) == nil)
    }

    private static func pngData(width: Int, height: Int, color: (Int, Int) -> NSColor) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        for y in 0..<height {
            for x in 0..<width {
                bitmap.setColor(color(x, y).usingColorSpace(.deviceRGB) ?? .black, atX: x, y: y)
            }
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
