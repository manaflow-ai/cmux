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
        #expect(image.size == NSSize(width: 1, height: 1))
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
}
