import Foundation
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CmuxTopMemoryAttributionTests {
    private let firstWorkspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondWorkspaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @MainActor
    @Test func detachedSameTTYProcessIsNotAProvenSurfaceOwner() throws {
        let workspaceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let surfaceID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            if masterFD >= 0 { Darwin.close(masterFD) }
            if slaveFD >= 0 { Darwin.close(slaveFD) }
        }

        guard let ttyCString = ttyname(slaveFD) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENXIO)
        }
        var ttyStat = stat()
        guard fstat(slaveFD, &ttyStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let ttyName = String(cString: ttyCString)
        let ttyDevice = Int64(ttyStat.st_rdev)
        let scopedPID = 100
        let scopedHelperPID = 300
        let detachedPID = 200
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(
                    pid: scopedPID,
                    parentPID: 1,
                    name: "zsh",
                    residentBytes: 8 * 1024 * 1024,
                    ttyDevice: ttyDevice,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    attributionReason: "cmux-environment"
                ),
                process(
                    pid: scopedHelperPID,
                    parentPID: 1,
                    name: "cmux",
                    residentBytes: 16 * 1024 * 1024,
                    ttyDevice: ttyDevice,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    attributionReason: "cmux-hook-arguments"
                ),
                process(
                    pid: detachedPID,
                    parentPID: 1,
                    name: "python3",
                    residentBytes: 2 * 1024 * 1024 * 1024,
                    ttyDevice: ttyDevice,
                    processGroupID: detachedPID,
                    terminalProcessGroupID: scopedPID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        var windows: [[String: Any]] = [[
            "kind": "window",
            "id": "window:detached-tty",
            "key": true,
            "app_process_pids": [],
            "workspaces": [[
                "kind": "workspace",
                "id": workspaceID.uuidString,
                "ref": "workspace:detached-tty",
                "title": "detached tty",
                "panes": [[
                    "kind": "pane",
                    "id": "pane:detached-tty",
                    "ref": "pane:detached-tty",
                    "surfaces": [[
                        "kind": "surface",
                        "id": surfaceID.uuidString,
                        "type": "terminal",
                        "tty": ttyName,
                        "webviews": []
                    ] as [String: Any]]
                ] as [String: Any]],
                "tags": []
            ] as [String: Any]]
        ]]

        _ = TerminalController.shared.v2AnnotateTopWindows(
            &windows,
            processSnapshot: snapshot,
            browserPIDOccurrences: [:],
            includeProcesses: true
        )

        let surface = try #require(
            (((windows.first?["workspaces"] as? [[String: Any]])?.first?["panes"] as? [[String: Any]])?.first?["surfaces"] as? [[String: Any]])?.first
        )
        let resources = try #require(surface["resources"] as? [String: Any])
        let diagnostic = TerminalController.shared.v2TopMemoryDiagnosticPayload(
            processSnapshot: snapshot,
            annotatedWindows: windows
        )
        let diagnosticChildren = try #require(diagnostic["children"] as? [String: Any])
        let unattributedTTY = try #require(diagnosticChildren["unattributed_tty"] as? [String: Any])

        #expect(intArray(surface["cmux_process_pids"]) == [scopedPID, scopedHelperPID])
        #expect(intArray(surface["tty_process_pids"]) == [scopedPID, detachedPID, scopedHelperPID].sorted())
        #expect(intArray(surface["tty_unattributed_process_pids"]) == [detachedPID])
        #expect(intArray(resources["pids"]) == [scopedPID, scopedHelperPID].sorted())
        #expect(!intArray(surface["root_pids"]).contains(detachedPID))
        #expect(intArray(unattributedTTY["pids"]) == [detachedPID])
        #expect(int64(diagnosticChildren["recursive_rss_bytes"]) == 24 * 1024 * 1024)
    }

    @Test func detachedTTYMemoryIsSeparatedFromProvenChildRSS() throws {
        let appPID = 500
        let helperPID = 501
        let detachedPID = 502
        let helperBytes: Int64 = 24 * 1024 * 1024
        let detachedBytes: Int64 = 2 * 1024 * 1024 * 1024
        let workspaceID = firstWorkspaceID
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(pid: appPID, parentPID: 1, name: "cmux", residentBytes: 64 * 1024 * 1024),
                process(pid: helperPID, parentPID: 1, name: "cmux", residentBytes: helperBytes),
                process(pid: detachedPID, parentPID: 1, name: "python3", residentBytes: detachedBytes)
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        let helperAttribution = attribution(
            workspaceID: workspaceID,
            workspaceRef: "workspace:1",
            reason: "cmux-hook-arguments"
        )

        let payload = snapshot.memoryDiagnosticPayload(
            appPID: appPID,
            attributionByPID: [helperPID: helperAttribution],
            unattributedTTYProcessIDs: [detachedPID]
        )
        let children = try #require(payload["children"] as? [String: Any])
        let unattributed = try #require(children["unattributed_tty"] as? [String: Any])

        #expect(int64(children["recursive_rss_bytes"]) == helperBytes)
        #expect(intArray(children["pids"]) == [helperPID])
        #expect(int64(unattributed["rss_bytes"]) == detachedBytes)
        #expect(intArray(unattributed["pids"]) == [detachedPID])
        #expect(unattributed["ownership"] as? String == "ambiguous")
        #expect(unattributed["reason"] as? String == CmuxTopProcessOwnershipReason.sameTTYUnproven.rawValue)
        #expect((payload["summary"] as? String)?.contains("ownership unproven") == true)

        let taskManager = CmuxTaskManagerSnapshot(payload: ["memory_diagnostic": payload])
        let row = try #require(taskManager.childMemoryRows.last)
        #expect(row.title == "Unattributed same-TTY processes")
        #expect(row.workspaceId == nil)
        #expect(row.surfaceId == nil)
        #expect(!row.canKillProcess)
        #expect(row.detail.contains(CmuxTopProcessOwnershipReason.sameTTYUnproven.rawValue))
    }

    @Test func knownCMUXHelperNeedsAProvenProcessGroup() {
        let surfaceID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let ttyDevice: Int64 = 0x1600_0003
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(
                    pid: 600,
                    parentPID: 1,
                    name: "zsh",
                    residentBytes: 1,
                    ttyDevice: ttyDevice,
                    workspaceID: firstWorkspaceID,
                    surfaceID: surfaceID,
                    attributionReason: "cmux-environment",
                    processGroupID: 700,
                    terminalProcessGroupID: 700
                ),
                process(
                    pid: 601,
                    parentPID: 1,
                    name: "cmux",
                    residentBytes: 1,
                    ttyDevice: ttyDevice,
                    processGroupID: 700
                ),
                process(
                    pid: 602,
                    parentPID: 1,
                    name: "python3",
                    residentBytes: 1,
                    ttyDevice: ttyDevice,
                    processGroupID: 700
                ),
                process(
                    pid: 603,
                    parentPID: 1,
                    name: "cmux",
                    residentBytes: 1,
                    ttyDevice: ttyDevice,
                    processGroupID: 603,
                    terminalProcessGroupID: 700
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )

        let ownership = snapshot.terminalProcessOwnership(
            surfaceID: surfaceID,
            ttyDevice: ttyDevice,
            applicationPID: -1
        )

        #expect(ownership.ownedTTYProcessIDs == Set([600, 601]))
        #expect(ownership.ambiguousTTYProcessIDs == Set([602, 603]))
        #expect(ownership.reasonByProcessID[601] == CmuxTopProcessOwnershipReason.processGroup.rawValue)
        #expect(ownership.reasonByProcessID[602] == CmuxTopProcessOwnershipReason.sameTTYUnproven.rawValue)
        #expect(ownership.reasonByProcessID[603] == CmuxTopProcessOwnershipReason.sameTTYUnproven.rawValue)
    }

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

    @Test func commandGroupCombinesDifferentReasonsForSameOwner() throws {
        let appPID = 200
        let firstHelperPID = 201
        let secondHelperPID = 202
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(pid: appPID, parentPID: 1, name: "cmux", residentBytes: 32 * 1024 * 1024),
                process(pid: firstHelperPID, parentPID: appPID, name: "cmux", residentBytes: 12 * 1024 * 1024),
                process(pid: secondHelperPID, parentPID: appPID, name: "cmux", residentBytes: 11 * 1024 * 1024)
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        let payload = snapshot.memoryDiagnosticPayload(
            appPID: appPID,
            attributionByPID: [
                firstHelperPID: attribution(
                    workspaceID: firstWorkspaceID,
                    workspaceRef: "workspace:1",
                    reason: "surface-process-tree"
                ),
                secondHelperPID: attribution(
                    workspaceID: firstWorkspaceID,
                    workspaceRef: "workspace:1",
                    reason: "cmux-process-scope"
                )
            ]
        )
        let children = try #require(payload["children"] as? [String: Any])
        let groups = try #require(children["groups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let groupAttribution = try #require(group["group_attribution"] as? [String: Any])
        let attributions = try #require(group["attributions"] as? [[String: Any]])
        let combined = try #require(attributions.first)

        #expect(attributions.count == 1)
        #expect(combined["process_count"] as? Int == 2)
        #expect(combined["pids"] as? [Int] == [firstHelperPID, secondHelperPID])
        #expect(groupAttribution["reason"] as? String == "multiple-evidence")
        let owner = try #require(groupAttribution["owner"] as? [String: Any])
        #expect(owner["reason"] as? String == "multiple-evidence")
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

    @Test func commonOwnerCarriesMetadataWhenIdentifiersOverlap() throws {
        let complete = owner(
            workspaceID: firstWorkspaceID,
            workspaceRef: "workspace:1"
        )
        let idOnly = owner(workspaceID: firstWorkspaceID)
        let refOnly = owner(workspaceRef: "workspace:1")

        let commonByID = try #require(idOnly.commonOwner(with: complete))
        let commonByRef = try #require(refOnly.commonOwner(with: complete))

        #expect(commonByID.workspaceID == firstWorkspaceID)
        #expect(commonByID.workspaceRef == "workspace:1")
        #expect(commonByRef.workspaceID == firstWorkspaceID)
        #expect(commonByRef.workspaceRef == "workspace:1")
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
        residentBytes: Int64,
        ttyDevice: Int64? = nil,
        workspaceID: UUID? = nil,
        surfaceID: UUID? = nil,
        attributionReason: String? = nil,
        processGroupID: Int? = nil,
        terminalProcessGroupID: Int? = nil
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: name,
            path: name == "cmux" ? "/Applications/cmux.app/Contents/Resources/bin/cmux" : nil,
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: surfaceID,
            cmuxAttributionReason: attributionReason,
            processGroupID: processGroupID,
            terminalProcessGroupID: terminalProcessGroupID,
            cpuPercent: 0,
            residentBytes: residentBytes,
            virtualBytes: residentBytes,
            threadCount: 1
        )
    }

    private func attribution(
        workspaceID: UUID,
        workspaceRef: String,
        reason: String = "surface-process-tree"
    ) -> CmuxTopProcessAttribution {
        CmuxTopProcessAttribution(
            workspaceID: workspaceID,
            workspaceRef: workspaceRef,
            paneID: nil,
            paneRef: nil,
            surfaceID: nil,
            surfaceRef: nil,
            surfaceType: nil,
            reason: reason
        )
    }

    private func owner(
        workspaceID: UUID? = nil,
        workspaceRef: String? = nil,
        surfaceID: UUID? = nil
    ) -> CmuxTopProcessOwner {
        CmuxTopProcessOwner(
            workspaceID: workspaceID,
            workspaceRef: workspaceRef,
            paneID: nil,
            paneRef: nil,
            surfaceID: surfaceID,
            surfaceRef: nil,
            surfaceType: surfaceID == nil ? nil : "terminal"
        )
    }

    private func int64(_ raw: Any?) -> Int64 {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        if let value = raw as? String { return Int64(value) ?? 0 }
        return 0
    }

    private func intArray(_ raw: Any?) -> [Int] {
        if let values = raw as? [Int] { return values }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { value in
            if let value = value as? Int { return value }
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return Int(value) }
            return nil
        }
    }
}
