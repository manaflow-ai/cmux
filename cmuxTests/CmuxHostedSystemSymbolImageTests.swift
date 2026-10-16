import AppKit
import CmuxAppKitSupportUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Hosted symbols must go through the same path as the Vault icons: an
/// explicit tint baked into the AppKit bitmap by the shared renderer, plus a
/// same-symbol fallback for a transient blank draw. SwiftUI must not own any
/// pixel of the glyph (no `.foreground` mask over the hosted view), because
/// SwiftUI masks over hosted AppKit views go blank after a while on Intel
/// Macs running macOS 15.
@Suite("Hosted system symbol image")
struct CmuxHostedSystemSymbolImageTests {
    @Test @MainActor func iconRequestPreservesConfiguredSymbolGeometryAndTint() throws {
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
            weight: .regular,
            tintColor: .systemRed
        )

        #expect(request.size == materialized.size)
        #expect(request.symbolPointSize == 14)
        #expect(request.symbolWeight == .regular)
        #expect(request.tintColor == NSColor.systemRed)
        guard case .systemSymbol(let name, _) = request.source else {
            Issue.record("expected a system symbol source")
            return
        }
        #expect(name == "person.crop.circle")
        // The Vault icons retry the same symbol through the renderer's
        // fallback slot when the first draw comes back blank.
        guard case .systemSymbol(let fallbackName, _)? = request.fallbackSource else {
            Issue.record("expected a same-symbol fallback source")
            return
        }
        #expect(fallbackName == "person.crop.circle")
        #expect(request.fallbackTintColor == nil)
    }

    @Test @MainActor func hostedRendererDrawsTintedSymbolAtNaturalSize() throws {
        let materialized = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "questionmark.circle",
            pointSize: 14,
            weight: .regular
        ))
        let request = CmuxHostedSystemSymbolImage.iconRequest(
            systemName: "questionmark.circle",
            pointSize: 14,
            imageSize: materialized.size,
            weight: .regular,
            tintColor: .systemRed
        )
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let rendered = try #require(CmuxResolvedIconRenderer().image(for: request, appearance: appearance))

        #expect(rendered.size == materialized.size)
        let renderedBitmap = try #require(rendered.representations.first as? NSBitmapImageRep)
        let materializedBitmap = try #require(materialized.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .first { $0.pixelsWide == renderedBitmap.pixelsWide })
        let renderedPixels = Self.visiblePixels(in: renderedBitmap)
        let materializedPixels = Self.visiblePixels(in: materializedBitmap)
        #expect(renderedPixels.count > 0)
        #expect(abs(renderedPixels.count - materializedPixels.count) <= materializedPixels.count / 10)

        // Every opaque pixel carries the requested tint, so the NSImageView
        // shows the final color without any SwiftUI compositing. (Edge pixels
        // are anti-aliased; un-premultiplying them loses precision.)
        let expected = try #require(NSColor.systemRed.usingColorSpace(.deviceRGB))
        let opaquePixels = renderedPixels.filter { $0.alphaComponent > 0.9 }
        #expect(opaquePixels.count > 0)
        for color in opaquePixels {
            #expect(abs(color.redComponent - expected.redComponent) < 0.05)
            #expect(abs(color.greenComponent - expected.greenComponent) < 0.05)
            #expect(abs(color.blueComponent - expected.blueComponent) < 0.05)
        }
    }

    @Test @MainActor func systemSymbolImageBridgesSwiftUITintToDynamicAppKitColor() throws {
        let tint = CmuxSystemSymbolImage.hostedTintColor(for: .secondary)
        let expected = NSColor.secondaryLabelColor
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var resolved: NSColor?
            var resolvedExpected: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = tint.usingColorSpace(.deviceRGB)
                resolvedExpected = expected.usingColorSpace(.deviceRGB)
            }
            let actual = try #require(resolved)
            let wanted = try #require(resolvedExpected)
            #expect(abs(actual.redComponent - wanted.redComponent) < 0.05, "\(name.rawValue)")
            #expect(abs(actual.alphaComponent - wanted.alphaComponent) < 0.05, "\(name.rawValue)")
        }
    }

    private static func visiblePixels(in bitmap: NSBitmapImageRep) -> [NSColor] {
        var pixels: [NSColor] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.alphaComponent > 0.01 {
                    pixels.append(color)
                }
            }
        }
        return pixels
    }
}
