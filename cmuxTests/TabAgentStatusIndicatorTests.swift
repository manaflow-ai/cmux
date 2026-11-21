import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Tab agent status indicator")
struct TabAgentStatusIndicatorTests {
    @Test("A terminal with no agent state shows no indicator")
    func noStatesShowsNothing() {
        #expect(TabAgentStatusIndicator.resolve([]) == nil)
        #expect(TabAgentStatusIndicator.resolve([.idle, .unknown]) == nil)
    }

    @Test("Needs input outranks running, which outranks background work")
    func precedence() {
        #expect(TabAgentStatusIndicator.resolve([.backgroundWorkPending, .running, .needsInput])?.symbolName == nil)
        #expect(TabAgentStatusIndicator.resolve([.backgroundWorkPending, .running, .needsInput])?.pulses == false)
        #expect(TabAgentStatusIndicator.resolve([.backgroundWorkPending, .running, .idle])?.pulses == true)
        #expect(TabAgentStatusIndicator.resolve([.backgroundWorkPending, .idle])?.symbolName == "hourglass")
    }

    @Test("Needs input uses the sidebar's amber; running and waiting use the neutral color")
    func colorsMatchSidebar() {
        let needsInput = TabAgentStatusIndicator.resolve([.needsInput])
        #expect(needsInput?.color != nil)
        #expect(TabAgentStatusIndicator.resolve([.running])?.color == nil)
        #expect(TabAgentStatusIndicator.resolve([.backgroundWorkPending])?.color == nil)
    }
}
