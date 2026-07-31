import AppKit
import ObjectiveC.runtime
import Testing
import UniformTypeIdentifiers

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
    func extremeAspectRatioBoundIsConstantTimeAndWithinPixelLimit() throws {
        let size = try BrowserScreenshotCaptureBounds.boundedOutputSize(
            for: NSSize(width: 100_000_000, height: 1),
            maximumPixelCount: 4_194_304
        )
        #expect(size == NSSize(width: 4_194_304, height: 1))
    }

    @Test
    func encodedCropUsesOnePixelPerSnapshotCoordinate() async throws {
        let source = try makePatternedBitmapImage()

        let cropped = try withImageFocusBackingScale(2) {
            try BrowserScreenshotCrop.croppedImage(
                from: source,
                selectionInView: NSRect(x: 50, y: 25, width: 100, height: 50),
                viewBounds: NSRect(x: 0, y: 0, width: 200, height: 150)
            )
        }
        let pngData = try await BrowserScreenshotPasteboardWriter().pngData(for: cropped)
        let bitmap = try #require(NSBitmapImageRep(data: pngData))

        #expect(bitmap.pixelsWide == 200)
        #expect(bitmap.pixelsHigh == 100)
        try expectColor(testRed, atX: 25, y: 25, in: bitmap)
        try expectColor(testGreen, atX: 175, y: 25, in: bitmap)
        try expectColor(testBlue, atX: 25, y: 75, in: bitmap)
        try expectColor(testYellow, atX: 175, y: 75, in: bitmap)
    }

    @Test
    func pasteboardEncodingBoundsLargeImagePixelCount() async throws {
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

        let item = try await BrowserScreenshotPasteboardWriter(
            maximumPixelCount: BrowserScreenshotPasteboardWriter.maximumDesignModeArtifactPixelCount,
            oversizedImagePolicy: .downscale
        ).pasteboardItem(for: image)
        for type in [UTType.png, UTType.tiff] {
            let data = try #require(item.data(
                forType: NSPasteboard.PasteboardType(type.identifier)
            ))
            let encoded = try #require(NSBitmapImageRep(data: data))
            #expect(encoded.pixelsWide * encoded.pixelsHigh <= 4_194_304)
        }
    }

    @Test
    func ordinaryScreenshotClipboardKeepsNativeResolution() async throws {
        let width = 2_050
        let height = 2_050
        let image = try makeBlankBitmapImage(width: width, height: height)
        let pasteboard = NSPasteboard(
            name: .init("cmux-browser-native-resolution-\(UUID().uuidString)")
        )
        pasteboard.clearContents()

        _ = try await BrowserScreenshotPipeline.captureAndWrite(
            mode: .fullPage,
            snapshot: { image },
            pasteboard: pasteboard
        )

        for type in [UTType.png, UTType.tiff] {
            let data = try #require(pasteboard.data(
                forType: NSPasteboard.PasteboardType(type.identifier)
            ))
            let encoded = try #require(NSBitmapImageRep(data: data))
            #expect(encoded.pixelsWide == width)
            #expect(encoded.pixelsHigh == height)
        }
    }

    @Test
    func ordinaryScreenshotRejectsUnsafeEncodingInsteadOfDownscaling() async throws {
        let image = try makeBlankBitmapImage(width: 11, height: 10)

        do {
            _ = try await BrowserScreenshotPasteboardWriter(
                maximumPixelCount: 100
            ).pasteboardItem(for: image)
            Issue.record("Expected unsafe ordinary screenshot encoding to be rejected")
        } catch BrowserScreenshotError.captureAreaTooLarge {
            // Expected: ordinary screenshots stay native or fail explicitly.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func verifiedCaptureRetriesAFrameWithMultipleBlankTextProbes() async throws {
        var captureCount = 0
        let probes = textProbeSet()
        let image = try makeBlankBitmapImage(width: 100, height: 100)
        let service = BrowserScreenshotCaptureService(
            maximumAttempts: 3,
            synchronize: {},
            collectProbes: { probes },
            snapshot: {
                captureCount += 1
                return image
            },
            makePixelSource: { _ in
                if captureCount == 1 {
                    return SolidPixelSource(
                        pixelSize: probes.viewportSize,
                        color: .black
                    )
                }
                return TextPaintPixelSource(
                    pixelSize: probes.viewportSize,
                    textRects: probes.probes.map(\.rect)
                )
            }
        )

        _ = try await service.capture()

        #expect(captureCount == 2)
    }

    @Test
    func verifiedCaptureFailsLoudlyAfterBoundedRetries() async throws {
        var captureCount = 0
        let probes = textProbeSet()
        let image = try makeBlankBitmapImage(width: 100, height: 100)
        let service = BrowserScreenshotCaptureService(
            maximumAttempts: 3,
            synchronize: {},
            collectProbes: { probes },
            snapshot: {
                captureCount += 1
                return image
            },
            makePixelSource: { _ in
                SolidPixelSource(pixelSize: probes.viewportSize, color: .black)
            }
        )

        do {
            _ = try await service.capture()
            Issue.record("Expected a rendered-content mismatch")
        } catch let BrowserScreenshotError.renderedContentMismatch(
            text,
            rect,
            attempts,
            mismatchCount
        ) {
            #expect(text == "Balance")
            #expect(rect == probes.probes[0].rect)
            #expect(attempts == 3)
            #expect(mismatchCount == 2)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(captureCount == 3)
    }

    @Test
    func verifiedCaptureDefaultsToOneRetry() async throws {
        var captureCount = 0
        let probes = textProbeSet()
        let image = try makeBlankBitmapImage(width: 100, height: 100)
        let service = BrowserScreenshotCaptureService(
            synchronize: {},
            collectProbes: { probes },
            snapshot: {
                captureCount += 1
                return image
            },
            makePixelSource: { _ in
                SolidPixelSource(pixelSize: probes.viewportSize, color: .black)
            }
        )

        do {
            _ = try await service.capture()
            Issue.record("Expected a rendered-content mismatch")
        } catch let BrowserScreenshotError.renderedContentMismatch(
            _,
            _,
            attempts,
            _
        ) {
            #expect(attempts == 2)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(captureCount == 2)
    }

    @Test
    func verifiedCaptureAcceptsPagesWithoutTextProbes() async throws {
        var captureCount = 0
        let image = try makeBlankBitmapImage(width: 100, height: 100)
        let service = BrowserScreenshotCaptureService(
            maximumAttempts: 3,
            synchronize: {},
            collectProbes: {
                BrowserScreenshotFrameVerifier.ProbeSet(
                    viewportSize: NSSize(width: 100, height: 100),
                    probes: []
                )
            },
            snapshot: {
                captureCount += 1
                return image
            },
            makePixelSource: { _ in
                SolidPixelSource(
                    pixelSize: NSSize(width: 100, height: 100),
                    color: .black
                )
            }
        )

        _ = try await service.capture()

        #expect(captureCount == 1)
    }

    @Test
    func verifierTreatsOneDisagreeingProbeAsInconclusive() {
        let probes = textProbeSet()
        let oneProbe = BrowserScreenshotFrameVerifier.ProbeSet(
            viewportSize: probes.viewportSize,
            probes: [probes.probes[0]]
        )
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: oneProbe,
            after: oneProbe,
            pixels: SolidPixelSource(
                pixelSize: probes.viewportSize,
                color: .black
            )
        )

        #expect(outcome == .accepted)
    }

    @Test
    func verifierIgnoresTextThatMovesDuringCapture() {
        let before = textProbeSet()
        let after = BrowserScreenshotFrameVerifier.ProbeSet(
            viewportSize: before.viewportSize,
            probes: before.probes.map {
                BrowserScreenshotFrameVerifier.Probe(
                    identifier: $0.identifier,
                    text: $0.text,
                    rect: $0.rect.offsetBy(dx: 3, dy: 0),
                    foreground: $0.foreground,
                    background: $0.background
                )
            }
        )
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: before,
            after: after,
            pixels: SolidPixelSource(
                pixelSize: before.viewportSize,
                color: .black
            )
        )

        #expect(outcome == .accepted)
    }

    @Test
    func bitmapPixelSourceUsesTopLeftCoordinates() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 10,
            pixelsHigh: 10,
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
        testRed.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 5).fill()
        testBlue.setFill()
        NSRect(x: 0, y: 5, width: 10, height: 5).fill()
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 10, height: 10)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)

        let source = try #require(BrowserScreenshotBitmapPixelSource(image: image))
        let top = try #require(source.color(at: NSPoint(x: 5, y: 1)))
        let bottom = try #require(source.color(at: NSPoint(x: 5, y: 8)))

        #expect(top.blue > 0.9)
        #expect(top.red < 0.1)
        #expect(bottom.red > 0.9)
        #expect(bottom.blue < 0.1)
    }

    private func textProbeSet() -> BrowserScreenshotFrameVerifier.ProbeSet {
        BrowserScreenshotFrameVerifier.ProbeSet(
            viewportSize: NSSize(width: 100, height: 100),
            probes: [
                .init(
                    identifier: "balance",
                    text: "Balance",
                    rect: NSRect(x: 10, y: 10, width: 10, height: 12),
                    foreground: .white,
                    background: .black
                ),
                .init(
                    identifier: "primary-action",
                    text: "Add funds",
                    rect: NSRect(x: 60, y: 60, width: 10, height: 12),
                    foreground: .white,
                    background: .black
                ),
            ]
        )
    }

    private struct SolidPixelSource: BrowserScreenshotFrameVerifier.PixelSource {
        let pixelSize: NSSize
        let color: BrowserScreenshotFrameVerifier.RGBA

        func color(at point: NSPoint) -> BrowserScreenshotFrameVerifier.RGBA? {
            guard NSRect(origin: .zero, size: pixelSize).contains(point) else {
                return nil
            }
            return color
        }
    }

    private struct TextPaintPixelSource: BrowserScreenshotFrameVerifier.PixelSource {
        let pixelSize: NSSize
        let textRects: [NSRect]

        func color(at point: NSPoint) -> BrowserScreenshotFrameVerifier.RGBA? {
            guard NSRect(origin: .zero, size: pixelSize).contains(point) else {
                return nil
            }
            return textRects.contains(where: { $0.contains(point) }) ? .white : .black
        }
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
        testRed.setFill()
        NSRect(x: 100, y: 50, width: 100, height: 50).fill()
        testGreen.setFill()
        NSRect(x: 200, y: 50, width: 100, height: 50).fill()
        testBlue.setFill()
        NSRect(x: 100, y: 100, width: 100, height: 50).fill()
        testYellow.setFill()
        NSRect(x: 200, y: 100, width: 100, height: 50).fill()
        NSGraphicsContext.restoreGraphicsState()

        let size = NSSize(width: width, height: height)
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makeBlankBitmapImage(width: Int, height: Int) throws -> NSImage {
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
        return image
    }

    private var testRed: NSColor { NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1) }
    private var testGreen: NSColor { NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) }
    private var testBlue: NSColor { NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1) }
    private var testYellow: NSColor { NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1) }

    private func expectColor(
        _ expected: NSColor,
        atX x: Int,
        y: Int,
        in bitmap: NSBitmapImageRep
    ) throws {
        let actualRGB = try #require(
            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        )
        let expectedRGB = try #require(expected.usingColorSpace(.sRGB))
        // AppKit and ImageIO attach different display-independent profiles to
        // bitmap-backed images. Keep this strict enough to reject a swapped
        // quadrant while allowing their expected color-space conversion.
        let tolerance = 0.25

        #expect(abs(actualRGB.redComponent - expectedRGB.redComponent) < tolerance)
        #expect(abs(actualRGB.greenComponent - expectedRGB.greenComponent) < tolerance)
        #expect(abs(actualRGB.blueComponent - expectedRGB.blueComponent) < tolerance)
        #expect(abs(actualRGB.alphaComponent - expectedRGB.alphaComponent) < tolerance)
    }
}
