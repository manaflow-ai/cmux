#if os(iOS)
import CoreImage
import IOSurface
import QuartzCore
import UIKit

/// Reads the pixels Ghostty's Metal renderer last presented for a view.
///
/// Ghostty draws into an IOSurface and sets it as the `contents` of the layer
/// it adds under the surface's UIView (its IOSurfaceLayer), so the frame can
/// be copied without the view being on screen: the card shows exactly what
/// the live terminal shows (theme, ANSI/256/truecolor, bold, dim, inverse,
/// cursor, wide glyphs).
@MainActor
struct GhosttySnapshot {
    private static let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])

    /// The renderer's last frame, scaled to `width` pixels (keeping its
    /// aspect), or nil when Ghostty has not presented a frame yet.
    /// Identity of the presented frame (surface and its modification seed),
    /// to tell a new frame from the previous one.
    static func frameID(of view: UIView) -> (UInt32, UInt32)? {
        guard let surface = presentedSurface(in: view.layer) else { return nil }
        return (IOSurfaceGetID(surface), IOSurfaceGetSeed(surface))
    }

    static func image(of view: UIView, maxPixelWidth: CGFloat? = nil) -> CGImage? {
        guard let surface = presentedSurface(in: view.layer) else { return nil }
        var image = CIImage(ioSurface: surface)
        guard image.extent.width >= 1, image.extent.height >= 1 else { return nil }
        if let maxPixelWidth, image.extent.width > maxPixelWidth {
            let s = maxPixelWidth / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        return context.createCGImage(image, from: image.extent.integral)
    }

    private static func presentedSurface(in layer: CALayer) -> IOSurfaceRef? {
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            return unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        }
        for sub in layer.sublayers ?? [] {
            if let found = presentedSurface(in: sub) { return found }
        }
        return nil
    }
}
#endif
