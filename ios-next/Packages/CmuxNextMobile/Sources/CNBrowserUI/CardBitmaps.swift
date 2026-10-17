#if os(iOS)
import CNDesign
import Observation
import SwiftUI
import UIKit

/// How a card's snapshot is composited (see `ScaledPage`, which draws the
/// same thing live): the page laid out at `pageSize`, scaled to the card's
/// width, top aligned, clipped to the card's rounded rect.
struct CardBitmapSpec: Hashable, Sendable {
    /// Card size in points.
    var size: CGSize
    var scale: CGFloat
    var radius: CGFloat
    /// Full page size the snapshot is laid out at (points).
    var pageSize: CGSize
    /// Page points above the image (a terminal's status-bar gap).
    var topInset: CGFloat
    /// Page background behind and below the image.
    var background: RGBA
    /// Page points the image moves up (its content anchor, `ScaledPage`).
    var contentOffset: CGFloat = 0

    struct RGBA: Hashable, Sendable {
        var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

        init(_ color: UIColor, style: UIUserInterfaceStyle) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    }
}

/// Tab cards pre-composited off the main thread into one bitmap each, at the
/// card's pixel size, with the rounded corners in the bitmap.
///
/// A grid card used to be the page laid out at full screen size (a full
/// resolution screenshot) scaled down and clipped to a continuous rounded
/// rect with a shadow: every frame of a scroll the render server rendered
/// each visible card offscreen to clip it and again for its shadow, and the
/// GPU sampled every full-size texture (device trace, Tabs grid scroll:
/// 54 to 89 offscreen passes per frame, render 5.4 ms + GPU 6.0 ms at the
/// median, so the display fell from 120 Hz to 80 Hz). A baked card is one
/// plain image layer at its own pixel size.
@MainActor
@Observable
final class CardBitmaps {
    private struct Published {
        var spec: CardBitmapSpec
        var image: UIImage
    }

    private struct Request {
        var source: UIImage
        var spec: CardBitmapSpec
    }

    private var published: [String: Published] = [:]
    @ObservationIgnored private var requested: [String: Request] = [:]

    /// The baked card for `id` showing `source` as `spec` describes. Returns
    /// the last bitmap baked for the card (possibly of the previous snapshot
    /// or size while the new one bakes), or nil when there is none yet (draw
    /// the card live meanwhile). Safe to call from a view body: the
    /// result is published asynchronously.
    func image(for id: String, source: UIImage, spec: CardBitmapSpec) -> UIImage? {
        if let r = requested[id], r.source === source, r.spec == spec {
            // Already baked or baking.
        } else {
            requested[id] = Request(source: source, spec: spec)
            Task.detached(priority: .userInitiated) { [weak self] in
                let baked = Self.render(source, spec: spec)
                await self?.publish(id, source: source, spec: spec, image: baked)
            }
        }
        // While a new size bakes (a reflow into or out of the lone-tab
        // layout), the last bitmap stretches with the card's animating frame:
        // its corners are proportional to the width, so it looks the same.
        // Returning nil there swapped the card to the live view mid-reflow,
        // which jumped (lone-trans.mp4). Only a card never baked draws live.
        return published[id]?.image
    }

    /// Drops cards that are not in the grid any more.
    func retain(_ ids: Set<String>) {
        for id in requested.keys where !ids.contains(id) { requested[id] = nil }
        for id in published.keys where !ids.contains(id) { published[id] = nil }
    }

    private func publish(_ id: String, source: UIImage, spec: CardBitmapSpec, image: UIImage) {
        // A newer request for this card wins; this one is dropped.
        guard let r = requested[id], r.source === source, r.spec == spec else { return }
        published[id] = Published(spec: spec, image: image)
    }

    nonisolated static func render(_ source: UIImage, spec: CardBitmapSpec) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = spec.scale
        format.opaque = false
        format.preferredRange = .standard
        let size = spec.size
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: spec.radius).addClip()
            spec.background.uiColor.setFill()
            context.fill(rect)
            guard source.size.width > 0, spec.pageSize.width > 0 else { return }
            let s = size.width / spec.pageSize.width
            context.cgContext.interpolationQuality = .high
            source.draw(in: CGRect(x: 0, y: (spec.topInset - spec.contentOffset) * s, width: size.width,
                                   height: size.width * source.size.height / source.size.width))
        }
    }
}

/// A card's drop shadow as a stretchable image (drawn once per radius):
/// one plain image layer, where a SwiftUI `.shadow` on the clipped card
/// cost an offscreen pass per card on every scroll frame. Matches
/// `.shadow(color: .black.opacity(0.08), radius: 10, y: 3)`.
struct CardShadow: View {
    var radius: CGFloat
    @Environment(\.displayScale) private var displayScale

    static let blurRadius: CGFloat = 10
    static let opacity: CGFloat = 0.08
    static let y: CGFloat = 3
    /// Room around the card for the blur.
    static let margin: CGFloat = 2.5 * blurRadius

    var body: some View {
        let (image, cap) = Self.image(radius: radius, scale: displayScale)
        Image(uiImage: image)
            .resizable(capInsets: EdgeInsets(top: cap, leading: cap, bottom: cap, trailing: cap), resizingMode: .stretch)
            .padding(-Self.margin)
            .offset(y: Self.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @MainActor private static var cache: [CGFloat: (UIImage, CGFloat)] = [:]

    @MainActor static func image(radius: CGFloat, scale: CGFloat) -> (UIImage, CGFloat) {
        let key = (radius * 100).rounded() + scale / 10
        if let hit = cache[key] { return hit }
        // The shape's straight edges must be longer than the blur reaches
        // past a corner, so the stretched middle has the straight-edge profile.
        let k = (radius + 2 * blurRadius).rounded(.up)
        let side = 2 * k + 1
        let size = CGSize(width: side + 2 * margin, height: side + 2 * margin)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let shape = UIBezierPath(roundedRect: CGRect(x: margin, y: margin, width: side, height: side), cornerRadius: radius)
            // CALayer's shadowRadius is half of Core Graphics' blur.
            cg.setShadow(offset: .zero, blur: 2 * blurRadius, color: UIColor.black.withAlphaComponent(opacity).cgColor)
            UIColor.black.setFill()
            shape.fill()
            // Keep only the shadow: the card covers its own rect.
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.setBlendMode(.clear)
            shape.fill()
        }
        let entry = (image, margin + k)
        cache[key] = entry
        return entry
    }
}
#endif
