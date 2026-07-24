import AppKit
import ObjectiveC.runtime
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserScreenshotCropTests {
    private typealias FocusImplementation = @convention(c) (AnyObject, Selector) -> Void
    private static let imageFocusBackingScaleKey =
        "cmux.browserScreenshotCropTests.imageFocusBackingScale"
    private static let imageFocusOverrideInstalled: Bool = {
        let lockSelector = #selector(NSImage.lockFocus)
        let unlockSelector = #selector(NSImage.unlockFocus)
        guard let lockMethod = class_getInstanceMethod(NSImage.self, lockSelector),
              let unlockMethod = class_getInstanceMethod(NSImage.self, unlockSelector) else {
            return false
        }
        let originalLock = unsafeBitCast(
            method_getImplementation(lockMethod),
            to: FocusImplementation.self
        )
        let originalUnlock = unsafeBitCast(
            method_getImplementation(unlockMethod),
            to: FocusImplementation.self
        )
        let lockBlock: @convention(block) (NSImage) -> Void = { image in
            guard let scale = Thread.current.threadDictionary[imageFocusBackingScaleKey] as? Int else {
                originalLock(image, lockSelector)
                return
            }
            let size = image.size
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                Issue.record("Could not create the controlled image-focus context")
                originalLock(image, lockSelector)
                return
            }
            bitmap.size = size
            image.addRepresentation(bitmap)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
        }
        let unlockBlock: @convention(block) (NSImage) -> Void = { image in
            guard Thread.current.threadDictionary[imageFocusBackingScaleKey] is Int else {
                originalUnlock(image, unlockSelector)
                return
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        // Keep the replacement IMPs alive for the test process: parallel test
        // threads may already be executing the forwarding path.
        method_setImplementation(lockMethod, imp_implementationWithBlock(lockBlock))
        method_setImplementation(unlockMethod, imp_implementationWithBlock(unlockBlock))
        return true
    }()

    @Test
    func encodedCropUsesOnePixelPerSnapshotCoordinate() throws {
        let source = try makePatternedBitmapImage()

        let cropped = try withImageFocusBackingScale(2) {
            try BrowserScreenshotCrop.croppedImage(
                from: source,
                selectionInView: NSRect(x: 50, y: 25, width: 100, height: 50),
                viewBounds: NSRect(x: 0, y: 0, width: 200, height: 150)
            )
        }
        let pngData = try BrowserScreenshotPasteboardWriter.pngData(for: cropped)
        let bitmap = try #require(NSBitmapImageRep(data: pngData))

        #expect(bitmap.pixelsWide == 200)
        #expect(bitmap.pixelsHigh == 100)
        try expectColor(.red, atX: 25, y: 25, in: bitmap)
        try expectColor(.green, atX: 175, y: 25, in: bitmap)
        try expectColor(.blue, atX: 25, y: 75, in: bitmap)
        try expectColor(.yellow, atX: 175, y: 75, in: bitmap)
    }

    @Test
    func pngEncodingBoundsLargeImagePixelCount() throws {
        let width = 2_050
        let height = 2_050
        let bitmap = try #require(NSBitmapImageRep(
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
        ))
        bitmap.size = NSSize(width: width, height: height)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)

        let pngData = try BrowserScreenshotPasteboardWriter.pngData(for: image)
        let encoded = try #require(NSBitmapImageRep(data: pngData))

        #expect(encoded.pixelsWide * encoded.pixelsHigh <= 4_194_304)
    }

    /// Makes the legacy `NSImage.lockFocus()` path deterministically rasterize
    /// at Retina scale while forwarding unrelated threads to AppKit unchanged.
    private func withImageFocusBackingScale<T>(
        _ scale: Int,
        operation: () throws -> T
    ) throws -> T {
        guard Self.imageFocusOverrideInstalled else {
            Issue.record("Could not install the controlled image-focus context")
            return try operation()
        }
        Thread.current.threadDictionary[Self.imageFocusBackingScaleKey] = scale
        defer {
            Thread.current.threadDictionary.removeObject(
                forKey: Self.imageFocusBackingScaleKey
            )
        }

        return try operation()
    }

    private func makePatternedBitmapImage() throws -> NSImage {
        let width = 400
        let height = 300
        let bitmap = try #require(NSBitmapImageRep(
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
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.red.setFill()
        NSRect(x: 100, y: 50, width: 100, height: 50).fill()
        NSColor.green.setFill()
        NSRect(x: 200, y: 50, width: 100, height: 50).fill()
        NSColor.blue.setFill()
        NSRect(x: 100, y: 100, width: 100, height: 50).fill()
        NSColor.yellow.setFill()
        NSRect(x: 200, y: 100, width: 100, height: 50).fill()
        NSGraphicsContext.restoreGraphicsState()

        let size = NSSize(width: width, height: height)
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private func expectColor(
        _ expected: NSColor,
        atX x: Int,
        y: Int,
        in bitmap: NSBitmapImageRep
    ) throws {
        let actualRGB = try #require(
            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        )
        let expectedRGB = try #require(expected.usingColorSpace(.deviceRGB))
        let tolerance = 0.02

        #expect(abs(actualRGB.redComponent - expectedRGB.redComponent) < tolerance)
        #expect(abs(actualRGB.greenComponent - expectedRGB.greenComponent) < tolerance)
        #expect(abs(actualRGB.blueComponent - expectedRGB.blueComponent) < tolerance)
        #expect(abs(actualRGB.alphaComponent - expectedRGB.alphaComponent) < tolerance)
    }
}
