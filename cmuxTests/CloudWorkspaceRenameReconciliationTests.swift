import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the cloud workspace rename fence and its stable binding.
@MainActor
@Suite
struct CloudWorkspaceRenameReconciliationTests {
    private final class Provider: SurfaceProvider {
        let machine: SurfaceMachineID
        var info: SurfaceMachineInfo

        init(machine: SurfaceMachineID, workspaces: [SurfaceRemoteWorkspace]) {
            self.machine = machine
            info = SurfaceMachineInfo(
                id: machine,
                name: machine.rawValue,
                status: "running",
                image: nil,
                hasDesktop: false,
                memoryMb: nil,
                diskMb: nil,
                linkState: .connected,
                linkError: nil,
                cpuPercent: nil,
                memoryUsedMb: nil,
                diskUsedMb: nil,
                remoteWorkspaces: workspaces
            )
        }

        func refresh() async {}

        func materialize(
            _ resource: SurfaceResource,
            at destination: SurfaceDestination,
            focus: Bool
        ) async throws -> SurfaceProjection {
            SurfaceProjection(
                resource: resource.id,
                workspaceID: destination.workspaceID,
                panelID: UUID()
            )
        }

        func createTerminal(
            command: [String]?,
            cwd: String?,
            name: String?,
            remoteWorkspaceID: String?
        ) async throws -> SurfaceResource {
            SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .terminal, key: "created"),
                title: name ?? "terminal",
                detail: cwd,
                lifecycle: .running,
                agent: nil,
                remoteWorkspace: nil,
                port: nil,
                url: nil
            )
        }

        func projectionDidEnd(_ projection: SurfaceProjection) {}

        func discardMaterialization(_ projection: SurfaceProjection) -> Bool { false }
    }

    private func resource(
        _ machine: SurfaceMachineID,
        workspace: SurfaceRemoteWorkspace
    ) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(
                machine: machine,
                kind: .terminal,
                key: workspace.id + "-terminal"
            ),
            title: "shell",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: workspace,
            port: nil,
            url: nil
        )
    }

    private func info(
        _ machine: SurfaceMachineID,
        workspace: SurfaceRemoteWorkspace
    ) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machine,
            name: machine.rawValue,
            status: "running",
            image: nil,
            hasDesktop: false,
            memoryMb: nil,
            diskMb: nil,
            linkState: .connected,
            linkError: nil,
            cpuPercent: nil,
            memoryUsedMb: nil,
            remoteWorkspaces: [workspace]
        )
    }

    @Test("An old link response cannot replace a reconnect graph")
    func oldGenerationIsRejectedAfterReconnect() {
        let machine = SurfaceMachineID.cloud("rename-vm")
        let oldWorkspace = SurfaceRemoteWorkspace(
            id: "ws_same", name: "old", index: 0, focused: true
        )
        let newWorkspace = SurfaceRemoteWorkspace(
            id: "ws_same", name: "new", index: 0, focused: true
        )
        let catalog = SurfaceCatalog()
        catalog.register(Provider(machine: machine, workspaces: [oldWorkspace]))

        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: oldWorkspace)],
            on: machine,
            info: info(machine, workspace: oldWorkspace),
            cursor: CloudVMCursor(generation: "g-old", revision: 9)
        ))
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: newWorkspace)],
            on: machine,
            info: info(machine, workspace: newWorkspace),
            cursor: CloudVMCursor(generation: "g-new", revision: 1)
        ))

        #expect(!catalog.replaceCloudResources(
            [resource(machine, workspace: oldWorkspace)],
            on: machine,
            info: info(machine, workspace: oldWorkspace),
            cursor: CloudVMCursor(generation: "g-old", revision: 10)
        ))
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "new")
    }

    @Test("A reconnect retains a pending rename until the new graph confirms it")
    func reconnectRetainsPendingRename() throws {
        let machine = SurfaceMachineID.cloud("rename-vm")
        let before = SurfaceRemoteWorkspace(
            id: "ws_same", name: "before", index: 0, focused: true
        )
        let catalog = SurfaceCatalog()
        catalog.register(Provider(machine: machine, workspaces: [before]))
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: before)],
            on: machine,
            info: info(machine, workspace: before),
            cursor: CloudVMCursor(generation: "g1", revision: 4)
        ))

        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: before.id,
            name: "after"
        )
        catalog.commitCloudWorkspaceRename(
            token,
            receipt: CloudVMCursor(generation: "g1", revision: 5)
        )

        for (revision, name) in [(1, "before"), (2, "before")] {
            let workspace = SurfaceRemoteWorkspace(
                id: before.id, name: name, index: 0, focused: true
            )
            #expect(catalog.replaceCloudResources(
                [resource(machine, workspace: workspace)],
                on: machine,
                info: info(machine, workspace: workspace),
                cursor: CloudVMCursor(generation: "g2", revision: UInt64(revision))
            ))
            #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "after")
        }

        let confirmed = SurfaceRemoteWorkspace(
            id: before.id, name: "after", index: 0, focused: true
        )
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: confirmed)],
            on: machine,
            info: info(machine, workspace: confirmed),
            cursor: CloudVMCursor(generation: "g2", revision: 3)
        ))
        #expect(catalog.pendingCloudWorkspaceRenameName(
            machine: machine,
            workspaceID: before.id
        ) == nil)
    }

    @Test("A queued rename uses its predecessor receipt, not an external revision")
    func queuedRenameFence() throws {
        let machine = SurfaceMachineID.cloud("rename-vm")
        let workspace = SurfaceRemoteWorkspace(
            id: "ws_same", name: "before", index: 0, focused: true
        )
        let catalog = SurfaceCatalog()
        catalog.register(Provider(machine: machine, workspaces: [workspace]))
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: workspace)],
            on: machine,
            info: info(machine, workspace: workspace),
            cursor: CloudVMCursor(generation: "g", revision: 1)
        ))

        let first = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: workspace.id,
            name: "first"
        )
        let second = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: workspace.id,
            name: "second"
        )
        #expect(catalog.cloudWorkspaceRenameSubmissionCursor(first)
            == CloudVMCursor(generation: "g", revision: 1))
        catalog.commitCloudWorkspaceRename(
            first,
            receipt: CloudVMCursor(generation: "g", revision: 2)
        )
        #expect(catalog.cloudWorkspaceRenameSubmissionCursor(second)
            == CloudVMCursor(generation: "g", revision: 2))
        #expect(catalog.hasCloudWorkspaceRename(first))
        #expect(catalog.hasCloudWorkspaceRename(second))
    }

    @Test("Two failed queued edits restore the last canonical name")
    func queuedFailuresRestoreCanonicalName() throws {
        let machine = SurfaceMachineID.cloud("rename-vm")
        let workspace = SurfaceRemoteWorkspace(
            id: "ws_same", name: "canonical", index: 0, focused: true
        )
        let catalog = SurfaceCatalog()
        catalog.register(Provider(machine: machine, workspaces: [workspace]))
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: workspace)],
            on: machine,
            info: info(machine, workspace: workspace),
            cursor: CloudVMCursor(generation: "g", revision: 1)
        ))

        let first = try catalog.beginCloudWorkspaceRename(
            machine: machine, workspaceID: workspace.id, name: "first"
        )
        let second = try catalog.beginCloudWorkspaceRename(
            machine: machine, workspaceID: workspace.id, name: "second"
        )
        // The predecessor's completion is stale once the second intent exists;
        // only the newest lane may clear the optimistic overlay.
        catalog.rollbackCloudWorkspaceRename(first)
        #expect(catalog.pendingCloudWorkspaceRenameName(
            machine: machine, workspaceID: workspace.id
        ) == "second")
        catalog.rollbackCloudWorkspaceRename(second)
        #expect(catalog.pendingCloudWorkspaceRenameName(
            machine: machine, workspaceID: workspace.id
        ) == nil)
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "canonical")
    }

    @Test("A fresh daemon generation resolves a failed rename")
    func freshGenerationResolvesFailedRename() throws {
        let machine = SurfaceMachineID.cloud("rename-vm")
        let before = SurfaceRemoteWorkspace(
            id: "ws_same", name: "before", index: 0, focused: true
        )
        let catalog = SurfaceCatalog()
        catalog.register(Provider(machine: machine, workspaces: [before]))
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: before)],
            on: machine,
            info: info(machine, workspace: before),
            cursor: CloudVMCursor(generation: "g-old", revision: 4)
        ))
        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine, workspaceID: before.id, name: "after"
        )

        // A new generation is a fresh durable snapshot. If it still has the
        // old name, the mutation did not commit; retaining "after" would leave
        // the local and remote projections permanently divergent.
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: before)],
            on: machine,
            info: info(machine, workspace: before),
            cursor: CloudVMCursor(generation: "g-new", revision: 1)
        ))
        #expect(catalog.pendingCloudWorkspaceRenameName(
            machine: machine, workspaceID: before.id
        ) == nil)
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "before")
        catalog.resolveFailedCloudWorkspaceRename(token)
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "before")
    }

    @Test("A regressive mutation receipt cannot advance a queued edit")
    func regressiveReceiptDoesNotAdvanceQueue() throws {
        let machine = SurfaceMachineID.cloud("rename-vm")
        let workspace = SurfaceRemoteWorkspace(
            id: "ws_same", name: "before", index: 0, focused: true
        )
        let catalog = SurfaceCatalog()
        catalog.register(Provider(machine: machine, workspaces: [workspace]))
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: workspace)],
            on: machine,
            info: info(machine, workspace: workspace),
            cursor: CloudVMCursor(generation: "g", revision: 5)
        ))
        let first = try catalog.beginCloudWorkspaceRename(
            machine: machine, workspaceID: workspace.id, name: "first"
        )
        let second = try catalog.beginCloudWorkspaceRename(
            machine: machine, workspaceID: workspace.id, name: "second"
        )
        catalog.commitCloudWorkspaceRename(
            first, receipt: CloudVMCursor(generation: "g", revision: 4)
        )
        #expect(catalog.cloudWorkspaceRenameSubmissionCursor(second)
            == CloudVMCursor(generation: "g", revision: 5))
    }

    @Test("An intervening remote revision invalidates a pending rename fence")
    func remoteRevisionInvalidatesPendingRename() throws {
        let machine = SurfaceMachineID.cloud("rename-vm")
        let workspace = SurfaceRemoteWorkspace(
            id: "ws_same", name: "before", index: 0, focused: true
        )
        let catalog = SurfaceCatalog()
        catalog.register(Provider(machine: machine, workspaces: [workspace]))
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: workspace)],
            on: machine,
            info: info(machine, workspace: workspace),
            cursor: CloudVMCursor(generation: "g", revision: 1)
        ))
        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: workspace.id,
            name: "local"
        )
        let remote = SurfaceRemoteWorkspace(
            id: workspace.id, name: "remote", index: 0, focused: true
        )
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: remote)],
            on: machine,
            info: info(machine, workspace: remote),
            cursor: CloudVMCursor(generation: "g", revision: 2)
        ))
        #expect(!catalog.hasCloudWorkspaceRename(token))
        #expect(catalog.cloudWorkspaceRenameSubmissionCursor(token) == nil)
    }

    @Test("Duplicate workspace names remain independently addressable by id")
    func duplicateNamesDoNotCrossUpdate() throws {
        let machine = SurfaceMachineID.cloud("rename-vm")
        let first = SurfaceRemoteWorkspace(id: "ws_first", name: "same", index: 0, focused: true)
        let second = SurfaceRemoteWorkspace(id: "ws_second", name: "same", index: 1, focused: false)
        var machineInfo = info(machine, workspace: first)
        machineInfo.remoteWorkspaces = [first, second]
        let catalog = SurfaceCatalog()
        catalog.register(Provider(machine: machine, workspaces: [first, second]))
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: first), resource(machine, workspace: second)],
            on: machine,
            info: machineInfo,
            cursor: CloudVMCursor(generation: "g", revision: 1)
        ))
        _ = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: first.id,
            name: "first-only"
        )
        let snapshot = catalog.snapshot
        #expect(snapshot.machines.first?.remoteWorkspaces?.first { $0.id == first.id }?.name == "first-only")
        #expect(snapshot.machines.first?.remoteWorkspaces?.first { $0.id == second.id }?.name == "same")
        #expect(snapshot.resources.first { $0.id.key == second.id + "-terminal" }?.remoteWorkspace?.name == "same")
    }

    @Test("An uncertain failure rolls back only when the cursor proves no commit")
    func failedRenameResolutionUsesCursorFence() throws {
        let machine = SurfaceMachineID.cloud("rename-vm")
        let before = SurfaceRemoteWorkspace(id: "ws_same", name: "before", index: 0, focused: true)
        let catalog = SurfaceCatalog()
        catalog.register(Provider(machine: machine, workspaces: [before]))
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: before)],
            on: machine,
            info: info(machine, workspace: before),
            cursor: CloudVMCursor(generation: "g1", revision: 1)
        ))
        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: before.id,
            name: "after"
        )
        catalog.resolveFailedCloudWorkspaceRename(token)
        #expect(catalog.pendingCloudWorkspaceRenameName(machine: machine, workspaceID: before.id) == nil)
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "before")

        let secondToken = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: before.id,
            name: "after-again"
        )
        let newer = SurfaceRemoteWorkspace(id: before.id, name: "remote", index: 0, focused: true)
        #expect(catalog.replaceCloudResources(
            [resource(machine, workspace: newer)],
            on: machine,
            info: info(machine, workspace: newer),
            cursor: CloudVMCursor(generation: "g2", revision: 1)
        ))
        catalog.resolveFailedCloudWorkspaceRename(secondToken)
        #expect(catalog.pendingCloudWorkspaceRenameName(machine: machine, workspaceID: before.id) == "after-again")
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "after-again")
    }

    @Test("Cloud binding round trips and remains compatible with legacy manifests")
    func bindingRoundTrip() throws {
        let binding = SessionCloudVMBindingSnapshot(
            vmID: "rename-vm",
            isBase: true,
            remoteWorkspaceID: "ws_same"
        )
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(
            SessionCloudVMBindingSnapshot.self,
            from: data
        )
        #expect(decoded == binding)
        let legacy = try JSONDecoder().decode(
            SessionCloudVMBindingSnapshot.self,
            from: Data(#"{"vmID":"rename-vm","isBase":true}"#.utf8)
        )
        #expect(legacy.remoteWorkspaceID == nil)
    }

    @Test("The cloud tree row reads the catalog's canonical workspace name")
    func treeRowUsesCanonicalName() throws {
        let machine = SurfaceMachineID.cloud("rename-vm")
        let workspace = SurfaceRemoteWorkspace(
            id: "ws_same", name: "canonical", index: 0, focused: true
        )
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(machine, workspace: workspace)],
            resources: [resource(machine, workspace: workspace)],
            projections: []
        )
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [MachineSnapshot(
                id: machine.rawValue,
                provider: "freestyle",
                image: "devbox",
                isDesktop: false,
                activity: .ready,
                createdAt: nil,
                label: nil
            )],
            snapshot: snapshot,
            localWorkspaces: []
        )
        let workspaceNode = nodes
            .flatMap { $0.children }
            .flatMap { $0.children }
            .first { node in
                if case .workspace(_, let value, _, _) = node.kind {
                    return value.id == workspace.id
                }
                return false
            }
        guard let workspaceNode,
              case .workspace(_, let row, _, _) = workspaceNode.kind else {
            Issue.record("canonical workspace row was not built")
            return
        }
        #expect(row.name == "canonical")
    }
}
