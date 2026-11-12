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
}
