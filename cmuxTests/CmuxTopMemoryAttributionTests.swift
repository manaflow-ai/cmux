import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CmuxTopMemoryAttributionTests {
    private let firstWorkspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondWorkspaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func commandGroupSpanningWorkspacesHasNoSingleOwner() throws {
        let payload = memoryDiagnosticPayload()
        let children = try #require(payload["children"] as? [String: Any])
        let groups = try #require(children["groups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let groupAttribution = try #require(group["group_attribution"] as? [String: Any])

        #expect(groupAttribution["kind"] as? String == "multiple")
        #expect(groupAttribution["workspace_count"] as? Int == 2)
        #expect(groupAttribution["owner"] is NSNull)
    }

    @Test func taskManagerDoesNotNavigateMultiWorkspaceGroupToTopMember() throws {
        let snapshot = CmuxTaskManagerSnapshot(payload: [
            "memory_diagnostic": memoryDiagnosticPayload()
        ])
        let row = try #require(snapshot.childMemoryRows.first)

        #expect(row.workspaceId == nil)
        #expect(row.surfaceId == nil)
        #expect(!row.detail.contains(firstWorkspaceID.uuidString))
        #expect(!row.detail.contains(secondWorkspaceID.uuidString))
    }

    @Test func commonOwnerPreservesMatchingSurfaceWithoutPaneMetadata() throws {
        let surfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let first = owner(workspaceID: firstWorkspaceID, surfaceID: surfaceID)
        let second = owner(workspaceID: firstWorkspaceID, surfaceID: surfaceID)

        let common = try #require(first.commonOwner(with: second))

        #expect(common.workspaceID == firstWorkspaceID)
        #expect(common.surfaceID == surfaceID)
    }

    @Test func commonOwnerWidensDifferentSurfacesToWorkspace() throws {
        let first = owner(
            workspaceID: firstWorkspaceID,
            surfaceID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let second = owner(
            workspaceID: firstWorkspaceID,
            surfaceID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )

        let common = try #require(first.commonOwner(with: second))

        #expect(common.workspaceID == firstWorkspaceID)
        #expect(common.paneID == nil)
        #expect(common.surfaceID == nil)
    }

    private func memoryDiagnosticPayload() -> [String: Any] {
        let appPID = 100
        let firstHelperPID = 101
        let secondHelperPID = 102
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(pid: appPID, parentPID: 1, name: "cmux", residentBytes: 32 * 1024 * 1024),
                process(pid: firstHelperPID, parentPID: appPID, name: "cmux", residentBytes: 12 * 1024 * 1024),
                process(pid: secondHelperPID, parentPID: appPID, name: "cmux", residentBytes: 11 * 1024 * 1024)
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )

        return snapshot.memoryDiagnosticPayload(
            appPID: appPID,
            attributionByPID: [
                firstHelperPID: attribution(workspaceID: firstWorkspaceID, workspaceRef: "workspace:1"),
                secondHelperPID: attribution(workspaceID: secondWorkspaceID, workspaceRef: "workspace:2")
            ]
        )
    }

    private func process(
        pid: Int,
        parentPID: Int,
        name: String,
        residentBytes: Int64
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: name,
            path: "/Applications/cmux.app/Contents/Resources/bin/cmux",
            ttyDevice: nil,
            cmuxWorkspaceID: nil,
            cmuxSurfaceID: nil,
            cmuxAttributionReason: nil,
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: residentBytes,
            virtualBytes: residentBytes,
            threadCount: 1
        )
    }

    private func attribution(
        workspaceID: UUID,
        workspaceRef: String
    ) -> CmuxTopProcessAttribution {
        CmuxTopProcessAttribution(
            workspaceID: workspaceID,
            workspaceRef: workspaceRef,
            paneID: nil,
            paneRef: nil,
            surfaceID: nil,
            surfaceRef: nil,
            surfaceType: nil,
            reason: "surface-process-tree"
        )
    }

    private func owner(
        workspaceID: UUID,
        surfaceID: UUID
    ) -> CmuxTopProcessOwner {
        CmuxTopProcessOwner(
            workspaceID: workspaceID,
            workspaceRef: nil,
            paneID: nil,
            paneRef: nil,
            surfaceID: surfaceID,
            surfaceRef: nil,
            surfaceType: "terminal"
        )
    }
}
