/// Matches one query token against one field and scores it by tier:
/// exact > prefix > word start > initials > substring > subsequence.
/// Pure and allocation-light; runs off the main actor.
public struct SearchMatcher: Sendable {
    public init() {}

    /// - Parameter fuzzy: allow the initials and subsequence tiers. Off for
    ///   long text (feed bodies, preview lines) where they only add noise.
    public func match(_ query: SearchText, in field: SearchText, fuzzy: Bool = true) -> SearchMatch? {
        let q = query.units
        let t = field.units
        guard !q.isEmpty, q.count <= t.count else { return nil }
        if q == t { return make(.exact, 0, field, [0..<t.count]) }
        if t.starts(with: q) {
            return make(.prefix, min(99, t.count - q.count), field, [0..<q.count])
        }
        var firstOccurrence: Int?
        var wordStartOccurrence: Int?
        var index = 0
        let last = t.count - q.count
        while index <= last {
            if t[index] == q[0], Self.matches(q, in: t, at: index) {
                if firstOccurrence == nil { firstOccurrence = index }
                if field.wordStarts[index] {
                    wordStartOccurrence = index
                    break
                }
            }
            index += 1
        }
        if let start = wordStartOccurrence {
            return make(.wordStart, min(99, start), field, [start..<(start + q.count)])
        }
        if fuzzy, let initials = initials(q, field) { return initials }
        if let start = firstOccurrence {
            return make(.substring, min(99, start), field, [start..<(start + q.count)])
        }
        guard fuzzy else { return nil }
        return subsequence(q, field)
    }

    // MARK: Tiers

    /// Each query unit at a successive word start (`nt` in `New Task`).
    private func initials(_ q: [Character], _ field: SearchText) -> SearchMatch? {
        var positions: [Int] = []
        var skipped = 0
        var next = 0
        for (index, unit) in field.units.enumerated() where field.wordStarts[index] {
            guard next < q.count else { break }
            if unit == q[next] {
                positions.append(index)
                next += 1
            } else if next > 0 {
                skipped += 1
            }
        }
        guard next == q.count, q.count > 1 else { return nil }
        return make(.initials, min(99, skipped * 10 + min(positions[0], 9)), field, Self.ranges(positions))
    }

    /// The tightest in-order placement of every query unit.
    private func subsequence(_ q: [Character], _ field: SearchText) -> SearchMatch? {
        let t = field.units
        var best: (span: Int, positions: [Int])?
        for start in t.indices where t[start] == q[0] {
            var positions = [start]
            var cursor = start + 1
            for unit in q.dropFirst() {
                while cursor < t.count, t[cursor] != unit { cursor += 1 }
                guard cursor < t.count else { break }
                positions.append(cursor)
                cursor += 1
            }
            guard positions.count == q.count else { break }
            let span = positions[positions.count - 1] - start + 1
            if best == nil || span < best!.span { best = (span, positions) }
            if span == q.count { break }
        }
        guard let best else { return nil }
        let penalty = min(299, (best.span - q.count) * 8 + min(best.positions[0], 20))
        return make(.subsequence, penalty, field, Self.ranges(best.positions))
    }

    // MARK: Helpers

    private func make(_ tier: SearchMatchTier, _ penalty: Int, _ field: SearchText, _ unitRanges: [Range<Int>]) -> SearchMatch {
        let span = tier == .subsequence ? 299 : 99
        let score = tier == .exact ? tier.base : tier.base + span - penalty
        return SearchMatch(tier: tier, score: score, ranges: Self.merge(unitRanges.map(field.characterRange(units:))))
    }

    private static func matches(_ q: [Character], in t: [Character], at start: Int) -> Bool {
        for offset in 1..<max(1, q.count) where t[start + offset] != q[offset] { return false }
        return true
    }

    /// Unit positions to contiguous unit ranges.
    static func ranges(_ positions: [Int]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for position in positions {
            if let last = result.last, last.upperBound == position {
                result[result.count - 1] = last.lowerBound..<(position + 1)
            } else {
                result.append(position..<(position + 1))
            }
        }
        return result
    }

    /// Sorted, overlapping or touching ranges merged.
    static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
