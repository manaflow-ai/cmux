import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Port retirement publication regression")
struct PortRetirementPublicationRegressionTests {
    @Test("Listener removal retires panel and workspace publications within one burst")
    func listenerRemovalRetiresPublicationsWithinBurst() throws {
        let port = 48_123
        let workspaceID = UUID()
        let panelKey = PortScanner.PanelKey(workspaceId: workspaceID, panelId: UUID())
        var panelSnapshot = PortScanSnapshotReconciler<PortScanner.PanelKey>()
        var workspaceSnapshot = PortScanSnapshotReconciler<UUID>()
        var buffer = PortScanPublicationBuffer()

        let initialPanelSnapshot = panelSnapshot.reconcile(
            scannedPorts: [panelKey: [port]],
            scannedKeys: [panelKey],
            trackedKeys: [panelKey],
            completeness: .complete
        )
        let initialWorkspaceSnapshot = workspaceSnapshot.reconcile(
            scannedPorts: [workspaceID: [port]],
            scannedKeys: [workspaceID],
            trackedKeys: [workspaceID],
            completeness: .complete
        )
        _ = buffer.enqueue(panelPublications: [PanelPortScanPublication(
            key: panelKey,
            ports: initialPanelSnapshot[panelKey] ?? [],
            revision: 1
        )])
        _ = buffer.enqueue(agentPublications: [AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: initialWorkspaceSnapshot[workspaceID] ?? [],
            revision: 1,
            requestID: 1,
            removesLifecycle: false
        )])

        for miss in 1...3 {
            let retiredPanelSnapshot = panelSnapshot.reconcile(
                scannedPorts: [panelKey: []],
                scannedKeys: [panelKey],
                trackedKeys: [panelKey],
                completeness: .complete
            )
            let retiredWorkspaceSnapshot = workspaceSnapshot.reconcile(
                scannedPorts: [workspaceID: []],
                scannedKeys: [workspaceID],
                trackedKeys: [workspaceID],
                completeness: .complete
            )
            let expectedPorts = miss < 3 ? [port] : []
            #expect(retiredPanelSnapshot[panelKey] ?? [] == expectedPorts)
            #expect(retiredWorkspaceSnapshot[workspaceID] ?? [] == expectedPorts)
            _ = buffer.enqueue(panelPublications: [PanelPortScanPublication(
                key: panelKey,
                ports: retiredPanelSnapshot[panelKey] ?? [],
                revision: 1
            )])
            _ = buffer.enqueue(agentPublications: [AgentPortScanPublication(
                workspaceId: workspaceID,
                ports: retiredWorkspaceSnapshot[workspaceID] ?? [],
                revision: 1,
                requestID: UInt64(miss + 1),
                removesLifecycle: false
            )])
        }

        let pendingBatch = buffer.takePendingBatch()
        let batch = try #require(pendingBatch)
        #expect(batch.panelPublicationsByKey[panelKey]?.ports.isEmpty == true)
        #expect(batch.agentPublicationsByWorkspace[workspaceID]?.ports.isEmpty == true)
    }
}
