@testable import CNTerminalUI
import Testing

/// The pool never releases the renderer of a terminal on screen or being
/// zoomed (the Tabs grid's zoom blinked when it did).
struct TerminalRendererCapTests {
    private let cap = TerminalRendererCap(max: 2)

    @Test func keepsTheMostRecentWithinTheCap() {
        let evict = cap.evictions(recent: ["a", "b", "c"], alive: ["a", "b", "c"], protected: [])
        #expect(evict == ["a"])
    }

    @Test func neverReleasesAProtectedTerminalEvenOverTheCap() {
        // "a" is being zoomed (oldest in recency, still in the window).
        let evict = cap.evictions(recent: ["a", "b", "c"], alive: ["a", "b", "c"], protected: ["a"])
        #expect(!evict.contains("a"))
        #expect(evict.isEmpty)
        // Three protected renderers stay even with a cap of two.
        #expect(cap.evictions(recent: ["a", "b", "c", "d"], alive: ["a", "b", "c", "d"], protected: ["a", "b", "c"]) == [])
    }

    @Test func ignoresTerminalsWithoutRenderers() {
        let evict = cap.evictions(recent: ["a", "b", "c", "d"], alive: ["b", "c", "d"], protected: ["d"])
        #expect(evict == ["b"])
    }
}
