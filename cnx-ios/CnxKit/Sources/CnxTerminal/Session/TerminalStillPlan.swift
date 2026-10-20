import CoreGraphics

/// What a still of the terminal page holds (the grid card's snapshot and the
/// frame saved for the next cold launch): the terminal's rows on its
/// background, nothing else. qa11 grid-composer-in-card: composing the
/// page's chrome layers (composer, key bar, status bar band) drew the
/// composer across a card's middle over rows. The rows shown are the ones a
/// person reads on the page: below the top inset, above the composer card.
struct TerminalStillPlan {
    /// Chrome layers are never part of a still.
    static let drawsChromeLayers = false

    /// The page's rows area in the page's points.
    static func rowsClip(bounds: CGRect, topInset: CGFloat, composerTop: CGFloat) -> CGRect {
        let top = min(max(bounds.minY, bounds.minY + topInset), bounds.maxY)
        let bottom = min(max(top, composerTop), bounds.maxY)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: bottom - top)
    }
}
