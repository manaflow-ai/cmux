import AppKit
import Foundation
import Testing

@Suite @MainActor
struct SidebarActionAuthorizationTests {
    @Test func cancelledOperationCannotCommit() async {
        var mutations = 0
        let authorization = SidebarActionAuthorization(isCurrent: { true })
        let operation = Task { @MainActor in authorization.perform { mutations += 1 } }
        operation.cancel()
        _ = await operation.value
        #expect(mutations == 0)
    }

    @Test func capturedEpochDoesNotBecomeValidAfterRegrant() {
        var revision = 1
        let captured = revision
        let authorization = SidebarActionAuthorization(isCurrent: { revision == captured })
        #expect(authorization.isValid)
        revision = 2
        revision = 3
        var mutations = 0
        authorization.perform { mutations += 1 }
        #expect(mutations == 0)
    }

    @Test func alreadyRevokedMenuIsNotPresented() {
        let authorization = SidebarActionAuthorization(isCurrent: { false })
        var presentations = 0
        SidebarAuthorizedMenuDispatch(authorization: authorization).present(NSMenu()) { _ in presentations += 1 }
        #expect(presentations == 0)
    }
}
