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
}
