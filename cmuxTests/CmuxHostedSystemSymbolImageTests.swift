import AppKit
import CmuxAppKitSupportUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Hosted symbols must request the configured symbol's natural layout size
/// with an explicit point size, so the AppKit renderer draws the same glyph
/// geometry the SwiftUI symbol image used before.
@Suite("Hosted system symbol image")
struct CmuxHostedSystemSymbolImageTests {
    @Test @MainActor func iconRequestPreservesConfiguredSymbolGeometry() throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        let materialized = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "person.crop.circle",
            pointSize: 14,
            weight: .regular
        ))
        let request = CmuxHostedSystemSymbolImage.iconRequest(
            systemName: "person.crop.circle",
            pointSize: 14,
            imageSize: materialized.size,
            weight: .regular
        )

        #expect(request.size == materialized.size)
        #expect(request.symbolPointSize == 14)
        #expect(request.symbolWeight == .regular)
        #expect(request.tintColor == nil)
        guard case .systemSymbol(let name, _) = request.source else {
            Issue.record("expected a system symbol source")
            return
        }
        #expect(name == "person.crop.circle")
    }

    @Test @MainActor func hostedRendererDrawsRequestedSymbolAtNaturalSize() throws {
        let materialized = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "questionmark.circle",
            pointSize: 14,
            weight: .regular
        ))
        let request = CmuxHostedSystemSymbolImage.iconRequest(
            systemName: "questionmark.circle",
            pointSize: 14,
            imageSize: materialized.size,
            weight: .regular
        )
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let rendered = try #require(CmuxResolvedIconRenderer().image(for: request, appearance: appearance))

        #expect(rendered.size == materialized.size)
        let renderedBitmap = try #require(rendered.representations.first as? NSBitmapImageRep)
        let materializedBitmap = try #require(materialized.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .first { $0.pixelsWide == renderedBitmap.pixelsWide })
        let renderedPixels = Self.visiblePixelCount(in: renderedBitmap)
        let materializedPixels = Self.visiblePixelCount(in: materializedBitmap)
        #expect(renderedPixels > 0)
        #expect(abs(renderedPixels - materializedPixels) <= materializedPixels / 10)
    }

    private static func visiblePixelCount(in bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    count += 1
                }
            }
        }
        return count
    }
}
