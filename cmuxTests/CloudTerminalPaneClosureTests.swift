import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A cloud pane owns no process, so nothing local notices when its remote
/// shell exits. The graph is the signal, and these are the rules that turn a
/// published graph into pane closures.
@Suite
struct CloudTerminalPaneClosureTests {
    private let paneA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let paneB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    @Test
    func closesPanesWhoseTerminalLeftTheGraph() {
        let closing = CloudTerminalPaneClosure.panelsToClose(
            boundTerminals: [paneA: "term_alive", paneB: "term_exited"],
            liveTerminalKeys: ["term_alive"],
            freshness: .current
        )
        #expect(closing == [paneB])
    }

    @Test
    func keepsEveryPaneWhileTheGraphIsLive() {
        let closing = CloudTerminalPaneClosure.panelsToClose(
            boundTerminals: [paneA: "term_alive", paneB: "term_also_alive"],
            liveTerminalKeys: ["term_alive", "term_also_alive"],
            freshness: .current
        )
        #expect(closing.isEmpty)
    }

    @Test
    func aStaleGraphNeverClosesAPane() {
        // An unreachable machine reports no terminals. That is a lost link,
        // not an exited shell, and it must not take the user's panes with it.
        let closing = CloudTerminalPaneClosure.panelsToClose(
            boundTerminals: [paneA: "term_alive", paneB: "term_also_alive"],
            liveTerminalKeys: [],
            freshness: .stale
        )
        #expect(closing.isEmpty)
    }
}
