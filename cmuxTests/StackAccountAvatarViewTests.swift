import AppKit
import CmuxAppKitSupportUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The signed-in avatar must use the same hosted-renderer contract as the
/// Vault agent icons: the decoded picture as the primary source and a
/// tinted system symbol as the fallback for a transient blank draw, so the
/// sidebar account button never ends up empty.
@Suite("Stack account avatar view")
struct StackAccountAvatarViewTests {
    @Test @MainActor func hostedRequestUsesPictureWithTintedSymbolFallback() throws {
        let picture = NSImage(size: NSSize(width: 22, height: 22))
        let request = StackAccountAvatarView.hostedRequest(image: picture, size: 22)

        #expect(request.size == NSSize(width: 22, height: 22))
        #expect(request.tintColor == nil)
        guard case .image(let source) = request.source else {
            Issue.record("expected the decoded picture as the primary source")
            return
        }
        #expect(source === picture)
        guard case .systemSymbol(let fallbackName, _)? = request.fallbackSource else {
            Issue.record("expected a system symbol fallback source")
            return
        }
        #expect(fallbackName == StackAccountAvatarView.fallbackSymbolName)
        #expect(request.fallbackTintColor == NSColor.secondaryLabelColor)
    }

    @Test @MainActor func hostedRequestRendersPictureThroughSharedRenderer() throws {
        let data = try #require(Self.pngData(width: 30, height: 30) { _, _ in .green })
        let picture = try #require(StackAccountAvatarImageLoader.circularImage(from: data, pointSize: 22, scale: 2))
        let request = StackAccountAvatarView.hostedRequest(image: picture, size: 22)
        let appearance = try #require(NSAppearance(named: .aqua))
        let rendered = try #require(CmuxResolvedIconRenderer().image(for: request, appearance: appearance))
        let bitmap = try #require(rendered.representations.first as? NSBitmapImageRep)

        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(center.greenComponent > 0.8)
        #expect(center.alphaComponent > 0.99)
        let corner = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(corner.alphaComponent < 0.01)
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
