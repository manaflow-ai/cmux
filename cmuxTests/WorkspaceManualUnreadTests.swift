import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceManualUnreadTests: XCTestCase {
    override func tearDown() {
        TerminalNotificationStore.shared.replaceNotificationsForTesting([])
        super.tearDown()
    }

}

