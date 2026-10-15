/// Which viewport a presented Ghostty frame shows (the rows' top row), read
/// from its pixels: the frame's row signatures are matched against the
/// previous frame's for candidate shifts. Ghostty renders on its own thread,
/// its viewport reports and frames reach the main thread in either order, and
/// a frame rendered before a request or a report can be presented after it.
/// Portable rule of `TerminalViewController.surfacePresented` (termqa D7).
public struct TerminalPresentMatch: Equatable, Sendable {
    /// The top row of the frame on screen until now.
    public var presentedTop: Int
    /// Ghostty's last viewport report.
    public var reportedTop: Int
    /// The last viewport asked for, and the ones before it.
    public var requestedTop: Int
    public var recentRequests: [Int]
    /// The active area's top (the bottom of the scrollback).
    public var activeTop: Int

    public init(presentedTop: Int, reportedTop: Int, requestedTop: Int, recentRequests: [Int], activeTop: Int) {
        self.presentedTop = presentedTop
        self.reportedTop = reportedTop
        self.requestedTop = requestedTop
        self.recentRequests = recentRequests
        self.activeTop = activeTop
    }

    /// Shifts from `presentedTop` to every viewport a frame in flight may
    /// show, in order of likelihood (ties go to the earlier one).
    public var candidateShifts: [Int] {
        var shifts: [Int] = []
        for top in [reportedTop, requestedTop, presentedTop] + recentRequests.reversed() + [activeTop]
            where !shifts.contains(top - presentedTop) {
            shifts.append(top - presentedTop)
        }
        // A frame Ghostty rendered a row or two before (or after) the one on
        // screen while it followed the output on its own: no request names
        // it (termqa D7). Last, so they win only on a strictly better match.
        for shift in [-1, 1, -2, 2] where !shifts.contains(shift) { shifts.append(shift) }
        return shifts
    }

    /// The frame's top row: the best matching candidate (at least 90 % of the
    /// non-blank rows equal), else the last report.
    public func top(previous: [UInt64], current: [UInt64]) -> Int {
        var best: (shift: Int, score: Double)?
        for shift in candidateShifts {
            let score = Self.score(previous, current, shift: shift)
            if score > (best?.score ?? -1) + 0.02 { best = (shift, score) }
        }
        if let best, best.score >= 0.9 { return presentedTop + best.shift }
        return reportedTop
    }

    /// Fraction of the new frame's non-blank rows equal to the previous
    /// frame's rows `shift` further down (1 = the same picture moved by `shift`).
    public static func score(_ previous: [UInt64], _ current: [UInt64], shift: Int) -> Double {
        let blank = current.isEmpty ? 0 : mostCommon(current)
        var compared = 0, equal = 0
        for index in current.indices {
            let other = index + shift
            guard other >= 0, other < previous.count, current[index] != blank else { continue }
            compared += 1
            if previous[other] == current[index] { equal += 1 }
        }
        return compared < 4 ? -1 : Double(equal) / Double(compared)
    }

    private static func mostCommon(_ values: [UInt64]) -> UInt64 {
        var counts: [UInt64: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }
}
