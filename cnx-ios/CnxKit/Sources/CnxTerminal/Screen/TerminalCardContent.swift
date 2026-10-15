import CoreGraphics

/// What a terminal tab's grid card shows.
public enum TerminalCardContent: Equatable, Sendable {
    /// The connecting placeholder over the last frame (the session started).
    case connecting
    /// The page's snapshot (or a saved frame).
    case snapshot
    /// The Mac's screen as text, fetched for a tab not opened in this launch.
    case screenText
    /// The static labeled placeholder.
    case placeholder

    public static func choose(sessionStarted: Bool, connecting: Bool, hasSnapshot: Bool, screenText: String?) -> Self {
        if sessionStarted {
            if connecting { return .connecting }
            return hasSnapshot ? .snapshot : .placeholder
        }
        // Not opened in this launch: a saved frame may be from long ago (or a
        // blank first frame); the Mac's screen now is the truth.
        if let screenText, screenText.contains(where: { !$0.isWhitespace }) { return .screenText }
        return hasSnapshot ? .snapshot : .placeholder
    }
}

/// Where a terminal card's snapshot sits in its page-sized card view.
/// TabsKit lays a card out at page size, top-aligned, and shows only the
/// top `width * 249.3 / 177` points (its card aspect, `OverviewLayout`);
/// the snapshot moves up so its bottom, the newest rows and the prompt, is
/// the card's bottom edge (VERIFY-round5 V5-6; the kit's hook for this is
/// UPSTREAM-REQUESTS U4).
public struct TerminalCardCrop: Equatable, Sendable {
    public static let cardAspect: CGFloat = 249.3 / 177.0
    public var width: CGFloat
    public var imageHeight: CGFloat

    public init(width: CGFloat, imageHeight: CGFloat) {
        self.width = width
        self.imageHeight = imageHeight
    }

    /// The part of the card view TabsKit shows.
    public var visibleHeight: CGFloat { width * Self.cardAspect }
    /// The image's top in the card view (0 or negative).
    public var imageTop: CGFloat { min(0, visibleHeight - imageHeight) }
}
