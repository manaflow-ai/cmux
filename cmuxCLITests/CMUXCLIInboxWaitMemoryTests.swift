import Foundation
import Testing

@testable import cmux_cli

@Suite
struct CMUXCLIInboxWaitMemoryTests {
    @Test("Claude inbox poll iterations drain Objective-C temporaries")
    func pollIterationDrainsObjectiveCTemporaries() {
        weak var releasedObject: NSObject?

        CMUXCLI.withAgentInboxPollIteration {
            let object = NSObject()
            releasedObject = object
            _ = Unmanaged.passRetained(object).autorelease()
        }

        #expect(releasedObject == nil)
    }
}
