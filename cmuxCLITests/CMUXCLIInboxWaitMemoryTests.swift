import AppKit
import Foundation
import Testing

@Suite
struct CMUXCLIInboxWaitMemoryTests {
    @Test("Claude inbox poll iterations drain Objective-C temporaries")
    func pollIterationDrainsObjectiveCTemporaries() {
        weak var releasedObject: NSObject?

        AgentInboxPollIteration.withAgentInboxPollIteration {
            let object = NSObject()
            releasedObject = object
            _ = Unmanaged.passRetained(object).autorelease()
        }

        #expect(releasedObject == nil)
    }
    @Test("The bundled CLI uses a prohibited activation policy")
    func bundledCLIUsesProhibitedActivationPolicy() {
        var observed: NSApplication.ActivationPolicy?
        let applied = CLIApplicationPolicy.apply {
            observed = $0
            return true
        }
        #expect(applied)
        #expect(observed == .prohibited)
    }

}
