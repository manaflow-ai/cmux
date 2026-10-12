import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) @MainActor
struct SessionSnapshotLimitTests {
    @Test func selectedWorkspace129IsRetainedWithin130WorkspaceBound() throws {
        let retention = SessionPersistencePolicy.boundedWorkspaceRetention(
            restorableWorkspaceCount: 130,
            selectedRestorableWorkspaceIndex: 129
        )
        #expect(retention.retainedIndices.count == 128)
        #expect(retention.retainedIndices.last == 129)
        #expect(retention.selectedWorkspaceIndex == 127)
        #expect(retention.omittedWorkspaceCount == 2)
    }

    @Test func mixedTabsFilterBeforeApplyingTheSameBound() {
        let restorableRawIndices = Array(1...129)
        let retention = SessionPersistencePolicy.boundedWorkspaceRetention(
            restorableWorkspaceCount: restorableRawIndices.count,
            selectedRestorableWorkspaceIndex: restorableRawIndices.count - 1
        )
        let retainedRawIndices = retention.retainedIndices.map { restorableRawIndices[$0] }
        #expect(retainedRawIndices.count == 128)
        #expect(retainedRawIndices.last == 129)
        #expect(retention.selectedWorkspaceIndex == 127)
        #expect(retention.omittedWorkspaceCount == 1)
    }

    @Test func omissionSignalRoundTripsForRestoreNotice() throws {
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 127,
            workspaces: [],
            omittedWorkspaceCount: 2
        )
        let decoded = try JSONDecoder().decode(
            SessionTabManagerSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded.omittedWorkspaceCount == 2)
    }

    @Test func oldSnapshotWithoutOmissionFieldsStillDecodes() throws {
        let legacy = Data(#"{"selectedWorkspaceIndex":null,"workspaces":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: legacy)
        #expect(decoded.selectedWorkspaceIndex == nil)
        #expect(decoded.workspaces.isEmpty)
    }
}
