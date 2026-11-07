import CmuxCloud
import CmuxCloudTui
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A user can keep Cloud terminals and browsers of several teams open at once.
/// Switching the selected team moves only discovery; a real loss of access
/// ends in a visible card, never a frozen frame.
@MainActor
@Suite("Cloud surfaces across teams")
struct CloudMultiTeamSurfaceTests {
    private let live = LiveWorkspaceFixture()

    @Test("A team switch keeps another team's open Cloud pane and its attachment alive")
    func teamSwitchKeepsOtherTeamSession() async throws {
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        var activeTeam = "team-a"
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: {
                VMListPage(vms: activeTeam == "team-a" ? [Self.machine("vm-a"), Self.machine("vm-a-idle")] : [Self.machine("vm-b")], limits: nil)
            },
            activeTeamID: { activeTeam },
            refreshProvider: { _, _ in true }
        )
        registry.start(catalog: catalog)
        #expect(await registry.refresh(force: true))
        let providerA = try #require(registry.provider(machineID: "vm-a"))
        #expect(providerA.ownerTeamID == "team-a")
        #expect(await registry.links.ownerTeam(for: "vm-a") == "team-a")

        // A team A terminal is open in a local workspace.
        let panelID = UUID()
        catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: .cloud("vm-a"), kind: .terminal, key: "term_a"),
            workspaceID: live.id(), panelID: panelID
        ))
        let session = CloudTuiManualMirrorSession(
            machineID: "vm-a", terminalID: "term_a", remoteSurfaceID: 1, onNeedsReconnect: {}
        )
        providerA.manualMirrorSessions[panelID] = session
        let generation = providerA.currentLifecycleGeneration

        activeTeam = "team-b"
        await registry.teamScopeDidChange()

        #expect(registry.provider(machineID: "vm-a") === providerA)
        #expect(providerA.isCurrentLifecycleGeneration(generation))
        #expect(providerA.isRegisteredInCatalog())
        #expect(providerA.manualMirrorSessions[panelID] === session)
        #expect(session.phase != .stopped)
        #expect(session.stopReason == nil)
        #expect(await registry.links.ownerTeam(for: "vm-a") == "team-a")
        // The selected team's fleet is discovered; the old team's unused
        // machine leaves, and the kept one is hidden from the new sidebar.
        #expect(registry.provider(machineID: "vm-b")?.ownerTeamID == "team-b")
        #expect(registry.provider(machineID: "vm-a-idle") == nil)
        #expect(registry.foreignTeamMachineIDs == ["vm-a"])

        // A later poll of team B's page still does not prune team A's pane.
        #expect(await registry.refresh(force: true))
        #expect(registry.provider(machineID: "vm-a") === providerA)
        #expect(session.phase != .stopped)

        // Sign-out ends every team and leaves the signed-out card.
        await registry.accessDidEnd()
        #expect(session.stopReason == .signedOut)
    }

    @Test("Another team's pane that lost access survives the selected team's poll and recovers on its own team's read")
    func foreignLostAccessRecoversOnOwnTeamRead() async throws {
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        var activeTeam = "team-a"
        var statusTeams: [String] = []
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: activeTeam == "team-a" ? [Self.machine("vm-a")] : [Self.machine("vm-b")], limits: nil) },
            activeTeamID: { activeTeam },
            loadMachineStatus: { machineID, teamID in
                statusTeams.append(teamID)
                return Self.machine(machineID)
            },
            refreshProvider: { _, _ in true }
        )
        registry.start(catalog: catalog)
        #expect(await registry.refresh(force: true))
        let providerA = try #require(registry.provider(machineID: "vm-a"))
        catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: .cloud("vm-a"), kind: .terminal, key: "term_a"),
            workspaceID: live.id(), panelID: UUID()
        ))
        providerA.noteAccessLost(.forbidden)

        activeTeam = "team-b"
        await registry.teamScopeDidChange()
        // Team B's page does not list vm-a; that says nothing about team A.
        #expect(registry.provider(machineID: "vm-a") === providerA)
        #expect(await registry.refresh(force: true))

        #expect(registry.provider(machineID: "vm-a") === providerA)
        #expect(statusTeams.contains("team-a"))
        #expect(!providerA.hasLostAccess)
        await registry.accessDidEnd()
    }

    @Test("A restored pane of a team that is not selected reconnects with its own team")
    func restoredForeignTeamPaneReconnectsWithOwnTeam() async throws {
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        var statusTeams: [String: String] = [:]
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: [Self.machine("vm-b")], limits: nil) },
            activeTeamID: { "team-b" },
            loadMachineStatus: { machineID, teamID in
                statusTeams[machineID] = teamID
                return Self.machine(machineID)
            },
            refreshProvider: { _, _ in true }
        )
        // After a restart, team A's pane restores while team B is selected.
        catalog.restore([SurfaceProjectionRecord(
            panelID: UUID(), resource: SurfaceResourceID(machine: .cloud("vm-a"), kind: .terminal, key: "term_a")
        )], workspaceID: live.id())
        #expect(catalog.pendingRestoredMachineIDs == ["vm-a"])
        registry.adoptOwnerTeam("team-a", forMachineID: "vm-a")
        registry.start(catalog: catalog)

        #expect(await registry.refresh(force: true))

        let provider = try #require(registry.provider(machineID: "vm-a"))
        #expect(provider.ownerTeamID == "team-a")
        #expect(statusTeams == ["vm-a": "team-a"])
        #expect(await registry.links.ownerTeam(for: "vm-a") == "team-a")
        #expect(registry.provider(machineID: "vm-b")?.ownerTeamID == "team-b")
        #expect(registry.foreignTeamMachineIDs == ["vm-a"])
        #expect(registry.ownerTeamID(forMachineID: "vm-a") == "team-a")
        await registry.accessDidEnd()
    }

    @Test("A restored pane leaves when the saved team's read answers 404 and the selected team's answers 403")
    func restoredPaneLeavesOnSelectedTeamForbidden() async throws {
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        var statusReads: [String] = []
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: [], limits: nil) },
            activeTeamID: { "team-b" },
            loadMachineStatus: { _, teamID in
                statusReads.append(teamID)
                if teamID == "team-a" {
                    throw VMClientError.httpStatus(404, #"{"error":"vm_not_found"}"#)
                }
                throw VMClientError.httpStatus(403, #"{"error":"forbidden"}"#)
            },
            refreshProvider: { _, _ in true }
        )
        catalog.restore([SurfaceProjectionRecord(
            panelID: UUID(), resource: SurfaceResourceID(machine: .cloud("vm-a"), kind: .terminal, key: "term_a")
        )], workspaceID: live.id())
        registry.adoptOwnerTeam("team-a", forMachineID: "vm-a")
        registry.start(catalog: catalog)

        #expect(await registry.refresh(force: true))
        #expect(statusReads == ["team-a", "team-b"])
        #expect(registry.provider(machineID: "vm-a") == nil)
        #expect(registry.ownerTeamID(forMachineID: "vm-a") == nil)
        #expect(catalog.pendingRestoredMachineIDs.isEmpty)
        #expect(await registry.refresh(force: true))
        #expect(statusReads == ["team-a", "team-b"])
        await registry.accessDidEnd()
    }

    @Test("A restored pane whose team access is gone does not keep reconnecting")
    func restoredForeignTeamPaneWithLostAccessLeaves() async throws {
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        var statusReads = 0
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: [], limits: nil) },
            activeTeamID: { "team-b" },
            loadMachineStatus: { _, _ in
                statusReads += 1
                throw VMClientError.httpStatus(403, #"{"error":"forbidden"}"#)
            },
            refreshProvider: { _, _ in true }
        )
        catalog.restore([SurfaceProjectionRecord(
            panelID: UUID(), resource: SurfaceResourceID(machine: .cloud("vm-a"), kind: .terminal, key: "term_a")
        )], workspaceID: live.id())
        registry.adoptOwnerTeam("team-a", forMachineID: "vm-a")
        registry.start(catalog: catalog)

        #expect(await registry.refresh(force: true))
        #expect(registry.provider(machineID: "vm-a") == nil)
        #expect(registry.ownerTeamID(forMachineID: "vm-a") == nil)
        #expect(await registry.refresh(force: true))
        #expect(statusReads == 1)
        await registry.accessDidEnd()
    }

    // https://github.com/manaflow-ai/cmux/issues/21820: a 404 from a status
    // read made with the wrong team unregistered the machine, which erased the
    // panes' saved links, and the next save restored them as local shells.
    @Test(
        "A restored pane whose status read answers 404 keeps its saved link and reconnects with the selected team",
        arguments: [nil, "team-a", "team-b"] as [String?]
    )
    func restoredPaneSurvivesAmbiguousNotFound(savedTeam: String?) async throws {
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        var ownerSelected = false
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: [], limits: nil) },
            activeTeamID: { ownerSelected ? "team-owner" : "team-b" },
            loadMachineStatus: { machineID, teamID in
                guard teamID == "team-owner" else {
                    throw VMClientError.httpStatus(404, #"{"error":"vm_not_found"}"#)
                }
                return Self.machine(machineID)
            },
            refreshProvider: { _, _ in true }
        )
        let resource = SurfaceResourceID(machine: .cloud("vm-a"), kind: .terminal, key: "term_a")
        let workspaceID = live.id()
        catalog.restore([SurfaceProjectionRecord(panelID: UUID(), resource: resource)], workspaceID: workspaceID)
        registry.adoptOwnerTeam(savedTeam, forMachineID: "vm-a")
        registry.start(catalog: catalog)

        #expect(await registry.refresh(force: true))
        #expect(registry.provider(machineID: "vm-a") == nil)
        #expect(catalog.pendingRestoredMachineIDs == ["vm-a"])
        #expect(catalog.projectionRecords(forWorkspace: workspaceID).map(\.resource) == [resource])

        ownerSelected = true
        await registry.teamScopeDidChange()
        #expect(await registry.refresh(force: true))
        let provider = try #require(registry.provider(machineID: "vm-a"))
        #expect(provider.ownerTeamID == "team-owner")
        #expect(registry.ownerTeamID(forMachineID: "vm-a") == "team-owner")
        await registry.accessDidEnd()
    }

    @Test("A permanent 404 shows the access-lost card and stops retrying")
    func permanentAccessLossStopsRetrying() async throws {
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        let links = AccessDeniedLinks()
        // The link path is shared by every remote machine; an SSH summary
        // reaches it without a signed-in control-plane client in the test host.
        let provider = CmuxTuiSurfaceProvider(
            summary: .ssh(Self.sshConnection()), ownerTeamID: "team-a", links: links, catalog: catalog
        )
        catalog.register(provider)
        let session = CloudTuiManualMirrorSession(
            machineID: provider.machineID, terminalID: "term_gone", remoteSurfaceID: 1, onNeedsReconnect: {}
        )
        provider.manualMirrorSessions[UUID()] = session

        #expect(await provider.refreshCurrentGraph(force: true) == false)

        #expect(provider.hasLostAccess)
        #expect(session.phase == .stopped)
        #expect(session.stopReason == .accessLost)
        #expect(provider.manualMirrorSessions.isEmpty)
        #expect(catalog.machines[provider.machine]?.linkState == .error)
        #expect(catalog.machines[provider.machine]?.linkError == "You no longer have access to this machine.")

        #expect(await provider.refreshCurrentGraph(force: true) == false)
        #expect(await links.connectCount == 1)
    }

    @Test("An authorized read clears a machine-scoped loss and dialing resumes")
    func authorizedReadClearsAccessLoss() async throws {
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        let links = AccessDeniedLinks(answer: .httpStatus(403, #"{"error":"forbidden"}"#))
        let provider = CmuxTuiSurfaceProvider(
            summary: .ssh(Self.sshConnection()), ownerTeamID: "team-a", links: links, catalog: catalog
        )
        catalog.register(provider)
        let panelID = UUID()
        provider.manualMirrorSessions[panelID] = CloudTuiManualMirrorSession(
            machineID: provider.machineID, terminalID: "term_a", remoteSurfaceID: 1, onNeedsReconnect: {}
        )
        provider.materializedPanels.insert(panelID)

        #expect(await provider.refreshCurrentGraph(force: true) == false)
        #expect(provider.accessLoss == .forbidden)
        #expect(await provider.refreshCurrentGraph(force: true) == false)
        #expect(await links.connectCount == 1)

        provider.noteAccessConfirmed()

        #expect(!provider.hasLostAccess)
        #expect(catalog.machines[provider.machine]?.linkError == nil)
        // The ended pane is rebuilt by the next refresh's reprojection.
        #expect(!provider.materializedPanels.contains(panelID))
        _ = await provider.refreshCurrentGraph(force: true)
        #expect(await links.connectCount == 2)
    }

    @Test("A revoked Mac sign-in shows the sign-in card and outlives an authorized read")
    func revokedSignInAsksForSignIn() async throws {
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        let links = AccessDeniedLinks(answer: .httpStatus(
            403, #"{"error":"vm_access_revoked","phase":"network"}"#
        ))
        let provider = CmuxTuiSurfaceProvider(
            summary: .ssh(Self.sshConnection()), ownerTeamID: "team-a", links: links, catalog: catalog
        )
        catalog.register(provider)
        let session = CloudTuiManualMirrorSession(
            machineID: provider.machineID, terminalID: "term_a", remoteSurfaceID: 1, onNeedsReconnect: {}
        )
        provider.manualMirrorSessions[UUID()] = session

        #expect(await provider.refreshCurrentGraph(force: true) == false)

        #expect(provider.accessLoss == .signInRevoked)
        #expect(session.stopReason == .signInRevoked)
        let detail = CloudTuiManualMirrorStopReason.signInRevoked.endedPresentation?.detail
        #expect(detail?.contains("sign in again") == true)
        #expect(catalog.machines[provider.machine]?.linkError == detail)
        // Listing machines does not use this Mac's network enrollment, so it
        // cannot prove the revoked sign-in works again.
        provider.noteAccessConfirmed()
        #expect(provider.accessLoss == .signInRevoked)
        #expect(await provider.refreshCurrentGraph(force: true) == false)
        #expect(await links.connectCount == 1)
    }

    @Test("A billing-team 403 keeps the machine and keeps retrying")
    func billingTeamForbiddenIsNotAccessLoss() async throws {
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        let links = AccessDeniedLinks(answer: .httpStatus(
            403, #"{"error":"vm_billing_team_not_found"}"#
        ))
        let provider = CmuxTuiSurfaceProvider(
            summary: .ssh(Self.sshConnection()), ownerTeamID: "team-a", links: links, catalog: catalog
        )
        catalog.register(provider)

        _ = await provider.refreshCurrentGraph(force: true)
        #expect(!provider.hasLostAccess)
        _ = await provider.refreshCurrentGraph(force: true)
        #expect(await links.connectCount == 2)
    }

    @Test("A stopped attachment leaves its card until a new attachment binds")
    func endedPresentationOutlivesSession() {
        let overlay = CloudTerminalOverlayCoordinator()
        let session = CloudTuiManualMirrorSession(
            machineID: "vm", terminalID: "term", remoteSurfaceID: 1, onNeedsReconnect: {}
        )
        overlay.session = session
        let card = CloudTuiManualMirrorStopReason.accessLost.endedPresentation
        #expect(card?.detail == "You no longer have access to this machine.")
        #expect(card?.showsReconnectButton == false)
        overlay.endSession(session, presentation: card)
        #expect(overlay.session == nil)
        #expect(overlay.endedPresentation == card)

        let replacement = CloudTuiManualMirrorSession(
            machineID: "vm", terminalID: "term", remoteSurfaceID: 2, onNeedsReconnect: {}
        )
        overlay.session = replacement
        #expect(overlay.endedPresentation == nil)
        #expect(CloudTuiManualMirrorStopReason.paneClosed.endedPresentation == nil)
    }

    @Test("Cloud workspace bindings persist their owning team and decode legacy snapshots")
    func bindingSnapshotRoundTrip() throws {
        let snapshot = SessionCloudVMBindingSnapshot(vmID: "vm-a", isBase: false, remoteWorkspaceID: "ws_1", teamID: "team-a")
        let decoded = try JSONDecoder().decode(SessionCloudVMBindingSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(Workspace.restoredCloudVMBinding(from: decoded)?.teamID == "team-a")

        let legacy = Data(#"{"vmID":"vm-a","isBase":true,"remoteWorkspaceID":"ws_1"}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(SessionCloudVMBindingSnapshot.self, from: legacy)
        #expect(legacyDecoded.teamID == nil)
        let restored = try #require(Workspace.restoredCloudVMBinding(from: legacyDecoded))
        #expect(restored.teamID == nil)
        #expect(restored.vmID == "vm-a")
        #expect(restored.isBase)
    }

    @Test("Cloud browser panes persist their owning team and decode legacy snapshots")
    func browserSnapshotRoundTrip() throws {
        let resource = SurfaceResourceID(machine: .cloud("vm-b"), kind: .display, key: "display")
        let snapshot = SessionBrowserPanelSnapshot(
            urlString: nil, profileID: nil, shouldRenderWebView: true, pageZoom: 1,
            developerToolsVisible: false, backHistoryURLStrings: nil, forwardHistoryURLStrings: nil,
            cloudResource: resource, cloudTeamID: "team-b"
        )
        let decoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.cloudResource == resource)
        #expect(decoded.cloudTeamID == "team-b")

        let legacy = Data(#"{"shouldRenderWebView":true,"pageZoom":1,"developerToolsVisible":false}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: legacy)
        #expect(legacyDecoded.cloudTeamID == nil)
        #expect(legacyDecoded.cloudResource == nil)
    }

    private static func sshConnection() -> SSHTuiConnection {
        SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            terminalProfile: .shell, destination: "alice@example.invalid", port: 2222, identityFile: nil,
            sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, configuredRemoteCommand: nil,
            preserveAfterTerminalExit: true
        ))
    }

    private static func machine(_ id: String) -> VMSummary {
        VMSummary(id: id, provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)
    }
}

/// A control plane that answers the first link attempt with `404 vm_not_found`.
private actor AccessDeniedLinks: RemoteTuiLinkManaging {
    nonisolated let operations: CloudOperationRecorder? = nil
    private(set) var connectCount = 0
    private let answer: VMClientError
    init(answer: VMClientError = .httpStatus(404, #"{"error":"vm_not_found"}"#)) {
        self.answer = answer
    }
    func connected(machineID: String) async throws -> CloudMachineLink.Connected {
        connectCount += 1
        throw answer
    }
    func link(machineID: String) async -> CloudMachineLink? { nil }
    func status(machineID: String) async -> CloudMachineLinkManager.LinkStatus? { nil }
    func privateAddresses(for machineID: String) async -> [String] { [] }
    func setPrivateAddresses(_ addresses: [String], for machineID: String) async {}
    func browserProxy(machineID: String, remoteNetwork: Bool) async throws -> CloudBrowserProxyEndpoint { throw URLError(.cannotConnectToHost) }
}
