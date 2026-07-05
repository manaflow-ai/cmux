import AppKit
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SidebarTabDragPayloadProviderTests {
    @Test @MainActor
    func providerFulfillsDataRepresentationWhileMainActorIsSynchronouslyWaiting() throws {
        let workspaceId = UUID()
        let provider = SidebarTabDragPayload.provider(for: workspaceId)
        let completion = DispatchSemaphore(value: 0)
        let resultBox = SidebarTabDragPayloadProviderResultBox()

        #expect(provider.registeredTypeIdentifiers.contains(SidebarTabDragPayload.typeIdentifier))

        provider.loadDataRepresentation(forTypeIdentifier: SidebarTabDragPayload.typeIdentifier) { data, error in
            resultBox.record(data: data, error: error)
            completion.signal()
        }

        let waitResult = completion.wait(timeout: .now() + .milliseconds(500))
        guard waitResult == .success else {
            Issue.record("Workspace drag payload provider did not complete while the main actor was synchronously waiting")
            return
        }

        let result = resultBox.snapshot()
        #expect(result.errorDescription == nil)
        let data = try #require(result.data)
        #expect(String(data: data, encoding: .utf8) == "\(SidebarTabDragPayload.prefix)\(workspaceId.uuidString)")
    }
}

fileprivate final class SidebarTabDragPayloadProviderResultBox: @unchecked Sendable {
    fileprivate struct State: Sendable {
        var data: Data? = nil
        var errorDescription: String? = nil
    }

    // The NSItemProvider completion can run on a background queue while this
    // regression test intentionally blocks the main actor.
    private let state = OSAllocatedUnfairLock(initialState: State())

    func record(data: Data?, error: (any Error)?) {
        state.withLock {
            $0.data = data
            $0.errorDescription = error.map { String(describing: $0) }
        }
    }

    func snapshot() -> State {
        state.withLock { $0 }
    }
}
