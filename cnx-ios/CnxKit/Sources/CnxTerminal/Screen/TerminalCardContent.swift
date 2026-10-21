import CoreGraphics
import Foundation

/// What a terminal tab's grid card shows.
public enum TerminalCardContent: Equatable, Sendable {
    /// The connecting placeholder over the last frame (the session started).
    case connecting
    /// The page's snapshot (the session started in this launch).
    case snapshot
    /// The Mac's screen as text, fetched for a tab not opened in this launch.
    case screenText
    /// A frame saved in an earlier launch, for a tab not opened in this
    /// launch, until the Mac's screen arrives: drawn dimmed, never as the
    /// current screen (VERIFY-round8 Claim 8: old Codex output shown while
    /// the Mac had moved on).
    case savedFrame
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
        return hasSnapshot ? .savedFrame : .placeholder
    }

    /// Whether the card stands for the terminal's screen now.
    public var isCurrent: Bool {
        switch self {
        case .snapshot, .screenText: true
        case .connecting, .savedFrame, .placeholder: false
        }
    }
}

/// When a grid card of a tab not opened in this launch asks the Mac for its
/// screen (`read-screen`): at most every `interval` per tab while cards are
/// rebuilt, always when the grid opens (T-TABS-01: the first grid open after
/// a launch showed a card asked for before the link was up), and again at
/// the next build after a read that brought nothing.
public struct TerminalCardScreenRefresh: Sendable {
    public static let interval: Double = 3
    /// A read that has not answered after this long no longer blocks a new one.
    public static let staleAfter: Double = 10

    /// One read, numbered from 1: replies are kept only for the newest
    /// request (round 11 A6).
    public typealias Request = Int

    private var latest: [String: (request: Request, at: Date)] = [:]
    private var inFlight: Set<String> = []
    private var sequence = 0

    public init() {}

    /// A new read to send, or nil: one is still out (unless the grid is
    /// opening), or the last one was asked for under `interval` ago.
    public mutating func begin(_ id: String, now: Date, gridOpening: Bool = false) -> Request? {
        if !gridOpening, let last = latest[id] {
            let age = now.timeIntervalSince(last.at)
            if inFlight.contains(id), age < Self.staleAfter { return nil }
            if age < Self.interval { return nil }
        }
        sequence += 1
        latest[id] = (sequence, now)
        inFlight.insert(id)
        return sequence
    }

    /// A reply arrived; true when it is the newest read's (apply it).
    public mutating func finished(_ id: String, request: Request) -> Bool {
        guard latest[id]?.request == request else { return false }
        inFlight.remove(id)
        return true
    }

    /// The read brought nothing; only the newest read's failure allows an
    /// early retry (an old failure keeps the newer read's time).
    public mutating func failed(_ id: String, request: Request) {
        guard latest[id]?.request == request else { return }
        inFlight.remove(id)
        latest[id] = nil
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

/// The Mac's screen text on a card (qa11 card-a-grid): TabsKit shows only the
/// top `width * cardAspect` points of the page-sized card view, so a full
/// screen drawn from its top lost its last rows and the prompt. The card
/// shows the last rows that fit (trailing blank rows are the empty screen
/// below the prompt); a short screen stays at the top like the page.
struct TerminalCardScreenLines {
    static func shown(_ text: String, capacity: Int) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let last = lines.lastIndex(where: { $0.contains(where: { !$0.isWhitespace }) }) else { return [] }
        return lines[...last].suffix(max(1, capacity)).map(String.init)
    }

    /// Rows that fit below `topInset` in the card's visible height (6 pt left at the bottom edge).
    static func capacity(visibleHeight: CGFloat, topInset: CGFloat, lineHeight: CGFloat) -> Int {
        guard lineHeight > 0 else { return 1 }
        return max(1, Int((visibleHeight - topInset - 6) / lineHeight))
    }
}
