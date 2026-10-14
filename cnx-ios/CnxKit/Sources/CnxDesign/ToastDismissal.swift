import CoreGraphics

/// How a toast follows the finger and when a drag dismisses it (`CnxToastDismiss`). A toast
/// leaves the way it came: one that entered from the top goes up or sideways, one that
/// entered from the bottom goes down or sideways. Pulling the other way rubber-bands.
public struct ToastDismissal: Equatable, Sendable {
    public enum Entry: Sendable, Equatable { case top, bottom }

    public var entry: Entry
    /// Distance past which a release dismisses.
    public var distance: CGFloat = 40
    /// A flick whose predicted end passes this dismisses even if the finger moved less.
    public var predictedDistance: CGFloat = 110
    /// The pull against the exit direction follows the finger at this fraction.
    public var resistance: CGFloat = 0.2

    public init(entry: Entry) {
        self.entry = entry
    }

    /// Vertical motion toward the exit (up for a top toast, down for a bottom one) is positive.
    private func outward(_ dy: CGFloat) -> CGFloat { entry == .top ? -dy : dy }

    /// Where the toast is drawn for a finger translation.
    public func offset(for translation: CGSize) -> CGSize {
        let out = outward(translation.height)
        let dy = out >= 0 ? translation.height : translation.height * resistance
        // Sideways only once the drag is mostly sideways, so a vertical flick stays straight.
        let dx = abs(translation.width) > abs(translation.height) ? translation.width : translation.width * resistance
        return CGSize(width: dx, height: dy)
    }

    /// Whether a release dismisses.
    public func dismisses(translation: CGSize, predictedEnd: CGSize) -> Bool {
        let sideways = max(abs(translation.width), 0)
        let predictedSideways = abs(predictedEnd.width)
        if outward(translation.height) >= distance || sideways >= distance * 1.5 { return true }
        return outward(predictedEnd.height) >= predictedDistance || predictedSideways >= predictedDistance * 1.5
    }

    /// Where the toast animates to when dismissed by a drag (off in the drag's direction).
    public func exitOffset(for translation: CGSize, size: CGSize) -> CGSize {
        if abs(translation.width) > abs(outward(translation.height)) {
            return CGSize(width: (translation.width >= 0 ? 1 : -1) * (size.width + 40), height: translation.height)
        }
        return CGSize(width: translation.width, height: (entry == .top ? -1 : 1) * (size.height + 80))
    }
}

/// Where a bottom toast sits: above whatever occupies the bottom of the screen right now
/// (the home indicator, a bottom toolbar, the keyboard and its key bar, a composer), with
/// a gap. All values are heights measured up from the bottom edge of the screen.
public struct ToastPlacement: Equatable, Sendable {
    public var safeAreaBottom: CGFloat
    public var bottomToolbar: CGFloat
    public var keyboard: CGFloat
    /// Chrome docked on top of the keyboard or the bottom (key bar, composer).
    public var dockedAccessory: CGFloat
    public var gap: CGFloat = 8

    public init(safeAreaBottom: CGFloat, bottomToolbar: CGFloat = 0, keyboard: CGFloat = 0, dockedAccessory: CGFloat = 0) {
        self.safeAreaBottom = safeAreaBottom
        self.bottomToolbar = bottomToolbar
        self.keyboard = keyboard
        self.dockedAccessory = dockedAccessory
    }

    /// The toast's bottom edge, above the bottom of the screen.
    public var bottomInset: CGFloat {
        // The keyboard replaces the safe area and the toolbar when it is up; an accessory
        // (key bar, composer) sits on top of whichever is higher.
        let base = max(safeAreaBottom + bottomToolbar, keyboard)
        return base + dockedAccessory + gap
    }
}
