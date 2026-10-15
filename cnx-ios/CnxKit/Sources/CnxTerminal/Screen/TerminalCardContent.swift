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
    /// The blank band at the image's bottom (the page's toolbar inset, under
    /// the composer), left below the card's edge.
    public var bottomTrim: CGFloat

    public init(width: CGFloat, imageHeight: CGFloat, bottomTrim: CGFloat = 0) {
        self.width = width
        self.imageHeight = imageHeight
        self.bottomTrim = bottomTrim
    }

    /// The part of the card view TabsKit shows.
    public var visibleHeight: CGFloat { width * Self.cardAspect }
    /// The image's top in the card view (0 or negative).
    public var imageTop: CGFloat { min(0, visibleHeight - (imageHeight - max(0, bottomTrim))) }
}

/// When the page's frame is saved for the next cold launch after output is
/// drawn (D11): never in the same turn as the output (Ghostty has not
/// presented it yet: 0.5 s), and at most every 3 s.
public enum TerminalFrameSaveSchedule {
    public static let settle: Double = 0.5
    public static let interval: Double = 3

    /// Round 8 (rig frame log): the save renders the page on the main
    /// thread (about 370 ms under load), so while output streams it waits
    /// for the output to pause, up to `maxWait`: every 3 s it was a 370 ms
    /// hitch while following.
    public static let maxWait: Double = 15

    public static func delay(sinceLastSave elapsed: Double) -> Double {
        max(settle, interval - elapsed)
    }

    /// Nil: save now. Otherwise how much longer to wait, given the time
    /// since the last drawn output and since the save was first wanted.
    public static func remainingWait(sinceLastOutput quiet: Double, sinceRequested waited: Double) -> Double? {
        if quiet >= settle || waited >= maxWait { return nil }
        return min(settle - quiet, maxWait - waited)
    }
}
