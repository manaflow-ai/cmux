import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure read-model regressions: no app launch, filesystem, process scan, or Cloud requests.
@Suite
struct CurrentWorkReducerTests {
    @Test("Stable projection identity does not rename local or Cloud resources")
    func identityScopesAndJSON() throws {
        var input = fixture()
        let projection = try #require(input.export.catalog.projections.first)
        let stableSurfaceID = UUID(), stableWorkspaceID = UUID()
        input.export.projectionIdentities[projection] = .init(stableSurfaceID: stableSurfaceID, stableWorkspaceID: stableWorkspaceID)
        let snapshot = CurrentWorkReducer().reduce(input)
        let item = try #require(snapshot.items.first)
        #expect(item.resourceRef == projection.resource.rawValue)
        #expect(item.durableSurfaceID == stableSurfaceID)
        #expect(item.projections.first?.stableWorkspaceID == stableWorkspaceID)
        let json = try snapshot.jsonObject()
        let row = try #require((json["items"] as? [[String: Any]])?.first)
        #expect(row["resource_ref"] as? String == projection.resource.rawValue)
        #expect(row["durable_surface_id"] as? String == stableSurfaceID.uuidString)
        let projected = try #require((row["projections"] as? [[String: Any]])?.first)
        #expect(projected["stable_workspace_id"] as? String == stableWorkspaceID.uuidString)

        let remote = SurfaceResourceID(machine: .cloud("test-machine"), kind: .terminal, key: "term-1")
        input.export.catalog.resources[0].id = remote
        var mirror = projection
        mirror.resource = remote
        mirror.remoteWorkspaceID = "remote-workspace"
        input.export.catalog.projections = [mirror]
        input.export.projectionIdentities = [mirror: .init(stableSurfaceID: stableSurfaceID, stableWorkspaceID: stableWorkspaceID)]
        let cloudItem = try #require(CurrentWorkReducer().reduce(input).items.first)
        #expect(cloudItem.durableSurfaceID == nil)
        #expect(cloudItem.resourceRef == remote.rawValue)
        #expect(cloudItem.projections.first?.stableSurfaceID == stableSurfaceID)
        #expect(cloudItem.freshness.state == "unknown")
    }

    @Test("Unread and process presence do not invent human obligations")
    func attentionRequiresHookProvenance() throws {
        var input = fixture()
        let projection = try #require(input.export.catalog.projections.first)
        input.unreadPanelIDs = [projection.panelID]
        input.agentsByPanelID[projection.panelID] = [agent(hook: false)]
        var item = try #require(CurrentWorkReducer().reduce(input).items.first)
        #expect(item.attention.contains { $0.kind == "unread" })
        #expect(item.possibleHumanObligations.isEmpty)
        input.agentsByPanelID[projection.panelID] = [agent(hook: true)]
        item = try #require(CurrentWorkReducer().reduce(input).items.first)
        #expect(item.possibleHumanObligations.count == 1)
        #expect(item.possibleHumanObligations.first?.freshness.state == "unknown")
        #expect(item.possibleHumanObligations.first?.evidence.reference == "codex/session-1@7")
        #expect(item.agents.first?.version == 7)
        // An unbound session is not assigned by a matching workspace label/cwd.
        input.agentsByPanelID = [UUID(): [agent(hook: true)]]
        #expect(CurrentWorkReducer().reduce(input).items.first?.agents.isEmpty == true)
    }

    @Test("A freshly captured stale Cloud observation never becomes current")
    func staleCloudRemainsStale() throws {
        var input = fixture(machine: .cloud("test-machine"))
        let projection = try #require(input.export.catalog.projections.first)
        input.agentsByPanelID[projection.panelID] = [agent(hook: true)]
        input.export.cloudStateObservations[projection.resource.machine] = .stale(reason: "disconnected")
        let item = try #require(CurrentWorkReducer().reduce(input).items.first)
        #expect(item.freshness.state == "stale")
        #expect(item.freshness.reason == "disconnected")
        #expect(item.possibleHumanObligations.isEmpty)
        #expect(item.agents.first?.lastActivityAt == "2026-09-20T00:00:00Z")
    }

    @Test("PR summaries retain workspace association and unknown owner freshness")
    func knownWorkspaceFactsOnly() throws {
        var input = fixture()
        let projection = try #require(input.export.catalog.projections.first)
        let observed = input.observedAt.ISO8601Format()
        input.workspaces[projection.workspaceID] = .init(projectRoot: "/work/repo", unreadCount: 1, notificationID: UUID(), pullRequests: [
            .init(number: 12, url: "https://example.test/pull/12", label: "owner/repo", status: "open", workspaceID: projection.workspaceID,
                  freshness: .init(state: "unknown", reason: "owner_has_no_update_timestamp", observedAt: observed),
                  evidence: .init(owner: "Workspace.sidebarPullRequests", reference: "https://example.test/pull/12", observedAt: observed))
        ])
        let item = try #require(CurrentWorkReducer().reduce(input).items.first)
        #expect(item.projectHints == ["/work/repo"])
        #expect(item.repositoryHints == ["owner/repo"])
        #expect(item.pullRequests.first?.associationScope == "workspace")
        #expect(item.pullRequests.first?.freshness.state == "unknown")
        #expect(item.possibleHumanObligations.isEmpty)
        input.export.catalog.resources[0].id.kind = .browser
        input.export.catalog.resources[0].detail = "https://example.test/path"
        #expect(CurrentWorkReducer().reduce(input).items.first?.cwd == nil)
    }

    @Test("Ordering and omissions are bounded and stable")
    func limitsAndOmissions() throws {
        var input = fixture()
        let original = input.export.catalog.resources[0]
        input.export.catalog.resources = (0..<205).reversed().map { index in
            var resource = original
            resource.id.key = String(format: "%03d", index)
            return resource
        }
        let limited = CurrentWorkReducer().reduce(input, limit: 200)
        #expect(limited.items.count == 200)
        #expect(limited.totalObserved == 205)
        #expect(limited.truncated)
        #expect(limited.items.first?.resourceRef.hasSuffix("/000") == true)
        input.export.catalog.resources = [original]
        input.export.catalog.projections = (0..<19).map { _ in .init(resource: original.id, workspaceID: UUID(), panelID: UUID()) }
        let item = try #require(CurrentWorkReducer().reduce(input).items.first)
        #expect(item.projections.count == 16)
        #expect(item.omitted["projections"] == 3)
    }

    @Test("Oversized identifiers fail encoding rather than being silently changed")
    func encodedByteLimit() throws {
        var input = fixture()
        input.export.catalog.resources[0].id.key = String(repeating: "x", count: 2_000_001)
        #expect(throws: (any Error).self) { try CurrentWorkReducer().reduce(input).jsonObject() }
    }

    private func fixture(machine: SurfaceMachineID = .local) -> CurrentWorkInput {
        let resource = SurfaceResource(id: .init(machine: machine, kind: .terminal, key: "panel-1"), title: "Current work", detail: "/work/repo",
                                       lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
        let projection = SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID())
        return .init(export: .init(catalog: .init(machines: [], resources: [resource], projections: [projection]), cloudStates: []),
                     observedAt: Date(timeIntervalSince1970: 1_789_862_400), workspaces: [:], agentsByPanelID: [:], unreadPanelIDs: [], agentOwnerAvailable: true)
    }

    private func agent(hook: Bool) -> CurrentWorkSnapshot.Agent {
        .init(sessionID: "session-1", kind: "codex", state: "needs_input", hasHookLifecycleState: hook, version: 7,
              lastActivityAt: "2026-09-20T00:00:00Z", evidence: .init(owner: "AgentChatSessionRegistry", reference: "codex/session-1@7", observedAt: "2026-09-20T01:00:00Z"))
    }
}
