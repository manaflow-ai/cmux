import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Renderable system symbols")
struct RenderableSystemSymbolTests {
    private struct PixelFootprint {
        let alphaCoverage: Double
        let centroidX: Double
        let centroidY: Double
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int

        init?(bitmap: NSBitmapImageRep) {
            var alphaCoverage = 0.0
            var weightedX = 0.0
            var weightedY = 0.0
            var minX = bitmap.pixelsWide
            var maxX = -1
            var minY = bitmap.pixelsHigh
            var maxY = -1

            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let alpha = Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                    guard alpha > 0.001 else { continue }
                    alphaCoverage += alpha
                    weightedX += Double(x) * alpha
                    weightedY += Double(y) * alpha
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }

            guard alphaCoverage > 0 else { return nil }
            self.alphaCoverage = alphaCoverage
            centroidX = weightedX / alphaCoverage
            centroidY = weightedY / alphaCoverage
            self.minX = minX
            self.maxX = maxX
            self.minY = minY
            self.maxY = maxY
        }
    }

    @Test func rasterPointSizeClampsInvalidInputs() {
        #expect(RenderableSystemSymbol.clampedRasterPointSize(0) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(-8) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(11) == 11)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(.nan) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(.infinity) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(-.infinity) == 1)
    }

    @Test func resolvedRasterPointSizeAppliesGlobalFontMagnificationWhenRequested() {
        #expect(RenderableSystemSymbol.resolvedRasterPointSize(
            10,
            globalFontPercent: 150,
            appliesGlobalFontMagnification: true
        ) == 15)
        #expect(RenderableSystemSymbol.resolvedRasterPointSize(
            10,
            globalFontPercent: 150,
            appliesGlobalFontMagnification: false
        ) == 10)
        #expect(RenderableSystemSymbol.resolvedRasterPointSize(
            0,
            globalFontPercent: 200,
            appliesGlobalFontMagnification: true
        ) == 2)
    }

    @Test @MainActor func configuredAppKitImageUsesTemplateImageWithClampedSize() throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        let image = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "questionmark.circle",
            pointSize: 0,
            weight: .medium
        ))
        #expect(image.isTemplate)
        // pointSize 0 is clamped to 1pt before rasterizing. The raster size AppKit hands back
        // for a 1pt symbol is a platform detail (2x2 on macOS 15.7 and 26.5), so compare
        // against a 1pt configuration rather than hardcoding it. Without the clamp the 0pt
        // configuration rasterizes at the symbol's default 16x16 and this still fails.
        let clampedBase = try #require(NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil))
        let clampedConfiguration = NSImage.SymbolConfiguration(pointSize: 1, weight: .medium)
        let clampedImage = try #require(clampedBase.withSymbolConfiguration(clampedConfiguration))
        #expect(clampedImage.size.width > 0 && clampedImage.size.height > 0)
        #expect(image.size == clampedImage.size)
    }

    @Test @MainActor func configuredAppKitImageIsEagerlyMaterializedForLayout() throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()

        let image = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "folder.fill",
            pointSize: 14,
            weight: .regular
        ))

        #expect(image.isTemplate)
        #expect(image.representations.count == 2)
        #expect(image.representations.allSatisfy { $0 is NSBitmapImageRep })
        #expect(image.tiffRepresentation != nil)
    }

    @MainActor
    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func configuredAppKitImageMatchesDirectAppKitRasterGeometryAtBackingScale(
        pixelScale: CGFloat
    ) throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()

        let systemName = "plus"
        let pointSize: CGFloat = 14
        let weight = NSFont.Weight.regular
        let baseImage = try #require(NSImage(systemSymbolName: systemName, accessibilityDescription: nil))
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let directImage = try #require(baseImage.withSymbolConfiguration(configuration))
        let materializedImage = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: systemName,
            pointSize: pointSize,
            weight: .regular
        ))
        #expect(materializedImage.size == directImage.size)

        let actualBitmap = try #require(Self.renderedBitmap(
            materializedImage,
            size: directImage.size,
            pixelScale: pixelScale
        ))
        let expectedBitmap = try #require(Self.renderedBitmap(
            directImage,
            size: directImage.size,
            pixelScale: pixelScale
        ))
        let actual = try #require(PixelFootprint(bitmap: actualBitmap))
        let expected = try #require(PixelFootprint(bitmap: expectedBitmap))

        // The returned image should match AppKit's own direct draw within a pixel at
        // each native backing scale. Creating the graphics context before assigning
        // the bitmap's point size shifts and shrinks the glyph dramatically.
        let centroidTolerance = 1.0
        #expect(abs(actual.centroidX - expected.centroidX) <= centroidTolerance)
        #expect(abs(actual.centroidY - expected.centroidY) <= centroidTolerance)
        #expect(abs(actual.minX - expected.minX) <= 1)
        #expect(abs(actual.maxX - expected.maxX) <= 1)
        #expect(abs(actual.minY - expected.minY) <= 1)
        #expect(abs(actual.maxY - expected.maxY) <= 1)
        #expect(abs(actual.alphaCoverage - expected.alphaCoverage) <= expected.alphaCoverage * 0.05)
    }

    @Test @MainActor func configuredAppKitImagePreservesConfiguredSizeForNonSquareSymbols() throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        let baseImage = try #require(NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil))
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let configuredImage = try #require(baseImage.withSymbolConfiguration(configuration))
        let image = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "arrow.left.and.right",
            pointSize: 16,
            weight: .regular
        ))
        #expect(image.size == configuredImage.size)
    }

    @Test func symbolImageSizePreservesValidConfiguredDimensions() {
        #expect(RenderableSystemSymbol.symbolImageSize(
            NSSize(width: 20, height: 10),
            fallbackDimension: 16
        ) == NSSize(width: 20, height: 10))
        #expect(RenderableSystemSymbol.symbolImageSize(
            NSSize(width: 0, height: 10),
            fallbackDimension: 16
        ) == NSSize(width: 16, height: 16))
    }

    @Test @MainActor func configuredAppKitImageReusesCachedImage() throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        let first = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "questionmark.circle",
            pointSize: 11,
            weight: .medium
        ))
        let second = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "questionmark.circle",
            pointSize: 11,
            weight: .medium
        ))
        #expect(first === second)
    }

    @Test @MainActor func configuredAppKitImageRejectsUnknownSymbols() {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        #expect(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "not.an.sf.symbol",
            pointSize: 11,
            weight: .regular
        ) == nil)
        #expect(RenderableSystemSymbol.isRenderable("not.an.sf.symbol") == false)
    }

    @Test func failedSymbolLookupRetriesAfterNegativeCacheExpires() {
        var now = Date(timeIntervalSince1970: 1_000)
        var resolveCount = 0
        var cache = RenderableSystemSymbol.RenderabilityCache(
            limit: 8,
            negativeRetryInterval: 60,
            now: { now },
            resolve: { _ in
                resolveCount += 1
                return false
            }
        )

        #expect(cache.isRenderable("not.an.sf.symbol") == false)
        #expect(resolveCount == 1)
        #expect(cache.isRenderable("not.an.sf.symbol") == false)
        #expect(resolveCount == 1)

        now = now.addingTimeInterval(61)
        #expect(cache.isRenderable("not.an.sf.symbol") == false)
        #expect(resolveCount == 2)
    }

    @MainActor
    private static func renderedBitmap(
        _ image: NSImage,
        size: NSSize,
        pixelScale: CGFloat
    ) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(ceil(size.width * pixelScale))),
            pixelsHigh: max(1, Int(ceil(size.height * pixelScale))),
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
        // Set the point-space size before creating the context. This is the reference
        // setup used to compare the materialized image with AppKit's direct rendering.
        bitmap.size = size
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        graphicsContext.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        return bitmap
    }
}
