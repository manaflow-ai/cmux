/// Which terminal renderers a pool releases to stay within its cap
/// (platform neutral so the rule is unit-tested).
///
/// Rule: keep the `max` most recently on-screen renderers; never release one
/// that is on screen or protected (a terminal being zoomed between its card
/// and the page counts as on screen), even when that leaves more than `max`.
struct TerminalRendererCap: Equatable, Sendable {
    var max: Int

    /// `recent`: terminal ids, most recently on screen last. `alive`: ids
    /// with a renderer. `protected`: ids on screen or otherwise in use.
    func evictions(recent: [String], alive: Set<String>, protected: Set<String>) -> [String] {
        let candidates = recent.filter { alive.contains($0) }
        let keep = Set(candidates.suffix(Swift.max(1, max))).union(protected)
        return candidates.filter { !keep.contains($0) }
    }
}
