import AppKit
import CmuxAppKitSupportUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Resolved icon rendering")
@MainActor
struct ResolvedIconRenderingTests {
    @Test
    func materializedTemplateHelperReturnsConcretePixels() throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        let image = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "folder.fill",
            pointSize: 14,
            weight: .regular
        ))

        #expect(image.isTemplate)
        #expect(image.representations.contains { $0 is NSBitmapImageRep })
        #expect(visiblePixelCount(in: image) > 0)
    }

    @Test
    func systemSymbolProducesVisibleNonTemplateBitmap() throws {
        let renderer = CmuxResolvedIconRenderer()
        let request = CmuxResolvedIconRequest(
            source: .systemSymbol(name: "folder.fill", accessibilityDescription: nil),
            size: NSSize(width: 16, height: 16),
            tintColor: .secondaryLabelColor
        )
        let appearance = try #require(NSAppearance(named: .aqua))

        guard case .success(let image) = renderer.render(for: request, appearance: appearance) else {
            Issue.record("A resolved SF Symbol must produce a visible bitmap")
            return
        }

        #expect(image.isTemplate == false)
        #expect(visiblePixelCount(in: image) > 0)
    }

    @Test
    func imageViewKeepsLastVisibleImageWhenARefreshDrawsBlank() throws {
        let view = CmuxResolvedIconImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.appearance = NSAppearance(named: .aqua)
        let representation = try #require(bitmap(color: .systemRed, pixels: 16))
        let sourceImage = NSImage(size: NSSize(width: 16, height: 16))
        sourceImage.addRepresentation(representation)
        let request = CmuxResolvedIconRequest(
            source: .image(sourceImage),
            size: NSSize(width: 16, height: 16)
        )

        view.apply(request)
        let firstImage = try #require(renderedImage(in: view))
        #expect(visiblePixelCount(in: firstImage) > 0)

        fill(representation, color: .clear, operation: .copy)
        view.apply(request)

        let preservedImage = try #require(renderedImage(in: view))
        #expect(preservedImage === firstImage)
        #expect(visiblePixelCount(in: preservedImage) > 0)
    }

    private func bitmap(color: NSColor, pixels: Int) -> NSBitmapImageRep? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
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
        representation.size = NSSize(width: pixels, height: pixels)
        fill(representation, color: color, operation: .copy)
        return representation
    }

    private func fill(
        _ representation: NSBitmapImageRep,
        color: NSColor,
        operation: NSCompositingOperation
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        color.setFill()
        NSRect(origin: .zero, size: representation.size).fill(using: operation)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func renderedImage(in view: CmuxResolvedIconImageView) -> NSImage? {
        view.subviews.compactMap { ($0 as? NSImageView)?.image }.first
    }

    private func visiblePixelCount(in image: NSImage) -> Int {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else {
            return 0
        }
        var count = 0
        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                if let color = representation.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    count += 1
                }
            }
        }
        return count
    }
}
