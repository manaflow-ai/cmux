import AppKit
import CmuxTerminal
import CmuxTerminalBackend
import CmuxTerminalBackendService
import CmuxTerminalRenderCompositor
import CmuxTerminalRenderProtocol
import CmuxTerminalRenderTransport
import Foundation
import IOSurface
import QuartzCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal client composition", .serialized)
struct TerminalClientCompositionTests {
    @Test @MainActor
    func persistentCompositionCreatesAnExternalOnlyTerminalPanel() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        let composition = TerminalClientComposition.persistent(
            backendClient: client,
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
        )
        let workspaceID = UUID()
        let surfaceID = UUID()
        let authorizationGate = try #require(
            composition.terminalBackendTopologyAuthorizationGate
        )
        await authorizationGate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
        ])
        let panel = composition.terminalPanelFactory.makeTerminalPanel(
            TerminalPanelCreationRequest(
                origin: .workspaceInitial,
                id: surfaceID,
                workspaceId: workspaceID
            )
        )
        defer { panel.close() }

        #expect(composition.terminalBackendClient != nil)
        #expect(panel.surface.isExternallyManaged)
        #expect(panel.surface.surface == nil)
        #expect(!panel.surface.isRendererRealized)
        #expect(panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(!panel.surface.debugHasHeadlessStartupWindowForTesting())

        await client.waitForEnsureCount(1)
    }

    @Test @MainActor
    func tabManagerRoutesInitialAndNestedTerminalsThroughOneComposition() throws {
        let recorder = RecordingTerminalPanelFactory()
        let composition = TerminalClientComposition(terminalPanelFactory: recorder)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }

        let workspace = try #require(manager.tabs.first)
        #expect(manager.terminalClientComposition === composition)
        #expect(workspace.terminalClientComposition === composition)
        #expect(recorder.requests.map(\.origin) == [.workspaceInitial])
        #expect(recorder.requests.first?.workspaceId == workspace.id)

        recorder.removeAllRequests()
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))

        #expect(recorder.requests.map(\.origin) == [.workspaceTab])
        #expect(recorder.requests.first?.workspaceId == workspace.id)
    }

    @Test @MainActor
    func workspaceDockUsesTheSameCompositionAndDockPlacement() throws {
        let recorder = RecordingTerminalPanelFactory()
        let composition = TerminalClientComposition(terminalPanelFactory: recorder)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }

        let workspace = try #require(manager.tabs.first)
        let dock = workspace.dockSplit
        #expect(dock.terminalClientComposition === composition)

        recorder.removeAllRequests()
        let pane = try #require(dock.bonsplitController.allPaneIds.first)
        _ = try #require(dock.newSurface(kind: .terminal, inPane: pane, focus: false))

        let request = try #require(recorder.requests.last)
        #expect(request.origin == .dock)
        #expect(request.workspaceId == workspace.id)
        #expect(request.focusPlacement == .rightSidebarDock)
    }

    @Test @MainActor
    func remoteTmuxManualIOUsesTheInjectedFactory() throws {
        let recorder = RecordingTerminalPanelFactory()
        let composition = TerminalClientComposition(terminalPanelFactory: recorder)
        let workspace = Workspace(terminalClientComposition: composition)
        defer { workspace.teardownAllPanels() }

        recorder.removeAllRequests()
        let panel = try #require(workspace.makeRemoteTmuxPanePanel(onInput: { _ in }))
        defer { panel.close() }

        let request = try #require(recorder.requests.last)
        #expect(request.origin == .remoteTmuxMirror)
        #expect(request.manualIO)
        #expect(request.workspaceId == workspace.id)
    }

    @Test @MainActor
    func backendModeRequiresCanonicalRemoteTmuxProvenance() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        var failures: [String] = []
        let composition = TerminalClientComposition.persistent(
            backendClient: client,
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies,
            topologyFailureReporter: { failures.append($0) }
        )
        let workspace = Workspace(
            initialSurface: .cloudVMLoading,
            terminalClientComposition: composition
        )
        defer { workspace.teardownAllPanels() }

        #expect(workspace.makeRemoteTmuxPanePanel(onInput: { _ in }) == nil)
        #expect(workspace.addRemoteTmuxDisplayPane(
            remotePaneId: 7,
            onInput: { _ in }
        ) == nil)

        #expect(failures.isEmpty)
        #expect((await client.ensureRequests()).isEmpty)
    }

    @Test @MainActor
    func backendModeCloudReplacementFailsClosedBeforeCanonicalAdoption() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        var failures: [String] = []
        let composition = TerminalClientComposition.persistent(
            backendClient: client,
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies,
            topologyFailureReporter: { failures.append($0) }
        )
        let workspace = Workspace(
            initialSurface: .cloudVMLoading,
            terminalClientComposition: composition
        )
        defer { workspace.teardownAllPanels() }

        let loadingPanelID = try #require(workspace.focusedPanelId)
        let command = "cmux vm-pty-connect --config /tmp/cmux.json --id vm_external"
        #expect(workspace.replaceCloudVMLoadingSurfaceWithLocalTerminal(
            workspaceId: workspace.id,
            initialCommand: command,
            focus: false
        ) == nil)
        for _ in 0..<8 { await Task.yield() }

        #expect(workspace.panels[loadingPanelID] is CloudVMLoadingPanel)
        #expect((await client.ensureRequests()).isEmpty)
        #expect(failures.count == 1)
        #expect(failures[0].contains(TerminalBackendTopologyMutation.attachSurface.rawValue))
    }

    @Test @MainActor
    func backendModeRespawnFailsClosedWithoutReplacingOrClosingPanel() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        var failures: [String] = []
        let composition = TerminalClientComposition.persistent(
            backendClient: client,
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies,
            topologyFailureReporter: { failures.append($0) }
        )
        let workspaceID = UUID()
        let surfaceID = UUID()
        let authorizationGate = try #require(composition.terminalBackendTopologyAuthorizationGate)
        await authorizationGate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
        ])
        let workspace = Workspace(
            id: workspaceID,
            terminalClientComposition: composition,
            initialTerminalSurfaceID: surfaceID
        )
        defer { workspace.teardownAllPanels() }

        let original = try #require(workspace.focusedTerminalPanel)
        await client.waitForEnsureCount(1)
        #expect(workspace.respawnLocalTerminalSurface(
            panelId: original.id,
            command: "exec /bin/zsh -l",
            tmuxStartCommand: "exec /bin/zsh -l"
        ) == nil)

        #expect(workspace.terminalPanel(for: original.id) === original)
        #expect((await client.ensureRequests()).count == 1)
        #expect(!(await client.mutations()).contains { $0.mutation == .closeCanonicalTerminal })
        #expect(failures.count == 1)
        #expect(failures[0].contains(TerminalBackendTopologyMutation.attachSurface.rawValue))
    }

    @Test @MainActor
    func backendModeRemotePTYReattachFailsClosedAndPreservesExistingTerminal() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        var failures: [String] = []
        let composition = TerminalClientComposition.persistent(
            backendClient: client,
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies,
            topologyFailureReporter: { failures.append($0) }
        )
        let workspaceID = UUID()
        let surfaceID = UUID()
        let authorizationGate = try #require(composition.terminalBackendTopologyAuthorizationGate)
        await authorizationGate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
        ])
        let workspace = Workspace(
            id: workspaceID,
            terminalClientComposition: composition,
            initialTerminalSurfaceID: surfaceID
        )
        defer { workspace.teardownAllPanels() }

        let original = try #require(workspace.focusedTerminalPanel)
        await client.waitForEnsureCount(1)
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-backend-test",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-backend-lifecycle-test.sock",
                terminalStartupCommand: "ssh cmux-backend-test",
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "backend-lifecycle-test"
            ),
            autoConnect: false
        )
        workspace.markPersistentRemotePTYAttachFailed(surfaceId: surfaceID)

        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to backend lifecycle test",
            target: "cmux-backend-test"
        )

        #expect(workspace.terminalPanel(for: surfaceID) === original)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(surfaceID))
        #expect((await client.ensureRequests()).count == 1)
        #expect(!(await client.mutations()).contains { $0.mutation == .closeCanonicalTerminal })
        #expect(failures.count == 1)
    }

    @Test @MainActor
    func canonicalLastSurfaceRemovalDoesNotCreateSwiftReplacementOrEchoClose() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        let composition = TerminalClientComposition.persistent(
            backendClient: client,
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
        )
        let workspaceID = UUID()
        let surfaceID = UUID()
        let authorizationGate = try #require(composition.terminalBackendTopologyAuthorizationGate)
        await authorizationGate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
        ])
        let workspace = Workspace(
            id: workspaceID,
            terminalClientComposition: composition,
            initialTerminalSurfaceID: surfaceID,
            isCanonicalTopologyProjection: true
        )
        defer { workspace.teardownAllPanels() }

        let original = try #require(workspace.focusedTerminalPanel)
        await client.waitForEnsureCount(1)
        #expect(workspace.closePanel(original.id, force: true))
        for _ in 0..<8 { await Task.yield() }

        #expect(workspace.panels.isEmpty)
        #expect((await client.ensureRequests()).count == 1)
        #expect(!(await client.mutations()).contains { $0.mutation == .closeCanonicalTerminal })
    }

    @Test @MainActor
    func terminalViewFactorySeparatesEmbeddedAndExternalRendererLayers() throws {
        let factory = TerminalSurfaceViewFactory()
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        let embeddedViews = factory.makeSurfaceViews(
            initialFrame: frame,
            renderOwnership: .embeddedGhostty
        )
        let embeddedView = try #require(embeddedViews.surfaceView as? GhosttyNSView)
        #expect(!(embeddedView is ExternalTerminalHostNSView))
        #expect(embeddedView.renderOwnership == .embeddedGhostty)
        #expect(embeddedView.layer is GhosttyMetalLayer)

        let externalViews = factory.makeSurfaceViews(
            initialFrame: frame,
            renderOwnership: .externalCompositor
        )
        let externalView = try #require(externalViews.surfaceView as? ExternalTerminalHostNSView)
        let externalLayer = try #require(externalView.layer)
        #expect(externalView.renderOwnership == .externalCompositor)
        #expect(type(of: externalLayer) == CALayer.self)
        #expect(!(externalLayer is CAMetalLayer))
        #expect(!(externalLayer is GhosttyMetalLayer))
    }

    @Test @MainActor
    func persistentPanelHasNoEmbeddedSurfaceOrGhosttyMetalLayer() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        let registry = TerminalBackendPresentationRegistry()
        let topologyAuthorizationGate = TerminalBackendTopologyAuthorizationGate()
        let factory = PersistentTerminalPanelFactory(
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies,
            backendClient: client,
            launchResolver: makeLaunchResolver(),
            presentationRegistry: registry,
            renderConfigSource: TerminalBackendRenderConfigSource {
                Data("font-family = Menlo\n".utf8)
            },
            topologyAuthorizationGate: topologyAuthorizationGate
        )
        let workspaceID = UUID()
        let surfaceID = UUID()
        await topologyAuthorizationGate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
        ])
        let panel = factory.makeTerminalPanel(TerminalPanelCreationRequest(
            origin: .workspaceInitial,
            id: surfaceID,
            workspaceId: workspaceID
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            panel.surface.detachExternalPresentationPreservingCanonicalTerminal()
            panel.close()
            window.contentView = nil
            window.close()
        }

        let externalView = try #require(panel.hostedView.surfaceView as? ExternalTerminalHostNSView)
        #expect(panel.surface.compositorHostView === externalView)
        #expect(panel.surface.isExternallyManaged)
        #expect(panel.surface.surface == nil)
        #expect(!panel.surface.isRendererRealized)
        #expect(panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(!panel.surface.debugHasHeadlessStartupWindowForTesting())
        #expect(Self.ghosttyMetalLayerCount(in: panel.hostedView) == 0)
        #expect(registry.compositorView(surfaceID: surfaceID) == nil)

        panel.hostedView.frame = window.contentView?.bounds
            ?? NSRect(x: 0, y: 0, width: 640, height: 480)
        window.contentView = panel.hostedView
        panel.hostedView.layoutSubtreeIfNeeded()
        _ = externalView.debugUpdateSurfaceSizeForTesting(externalView.bounds.size)

        #expect(externalView.layer != nil)
        #expect(!(externalView.layer is CAMetalLayer))
        #expect(externalView.debugDeferredSurfaceSizeNonMetalRetryCountForTesting() == 0)
        #expect(!externalView.debugNeedsSurfaceSizeRetryAfterMetalLayerRealizesForTesting())
        #expect(!externalView.debugDeferredSurfaceSizeRetryQueuedForTesting())
        #expect(panel.surface.surface == nil)
        #expect(panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(Self.ghosttyMetalLayerCount(in: panel.hostedView) == 0)

        await client.waitForEnsureCount(1)
    }

    @Test @MainActor
    func oneHundredDormantPersistentTerminalsNeverRequestRendererPresentations() async {
        let client = RecordingPersistentTerminalBackendClient()
        let registry = TerminalBackendPresentationRegistry()
        let resolver = makeLaunchResolver()
        var runtimes: [PersistentTerminalExternalRuntime] = []
        var leases: [any TerminalExternalPresentationLease] = []
        var hosts: [NSView] = []

        for index in 0..<100 {
            let workspaceID = UUID()
            let surfaceID = UUID()
            let runtime = PersistentTerminalExternalRuntime(
                client: client,
                launchResolver: resolver,
                launchRequest: makeLaunchRequest(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    portOrdinal: index
                ),
                presentationRegistry: registry
            )
            runtimes.append(runtime)
            leases.append(runtime.attachPresentation(TerminalExternalPresentation(
                surfaceID: surfaceID,
                workspaceID: workspaceID
            )))
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            hosts.append(host)
            #expect(registry.mountCompositor(surfaceID: surfaceID, in: host))
        }
        defer { leases.forEach { $0.detach() } }

        await client.waitForEnsureCount(100)
        let requests = await client.ensureRequests()
        let mutations = await client.mutations()
        let detachCount = await client.detachedPresentationCount()
        #expect(requests.count == 100)
        #expect(runtimes.count == 100)
        #expect(hosts.count == 100)
        #expect(mutations.isEmpty)
        #expect(detachCount == 0)
    }

    @Test @MainActor
    func waitAfterCommandStaysOnPersistentBackendAndSurvivesReattach() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        let registry = TerminalBackendPresentationRegistry()
        let topologyAuthorizationGate = TerminalBackendTopologyAuthorizationGate()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let targetWorkspaceID = UUID()
        await topologyAuthorizationGate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
            TerminalBackendTopologyPlacement(
                workspaceID: targetWorkspaceID,
                surfaceID: surfaceID
            ),
        ])
        var template = CmuxSurfaceConfigTemplate()
        template.command = "printf complete"
        template.waitAfterCommand = true
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                configTemplate: template
            ),
            presentationRegistry: registry,
            topologyAuthorizationGate: topologyAuthorizationGate
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        ))
        defer { lease.detach() }

        await client.waitForEnsureCount(1)
        let initialRequests = await client.ensureRequests()
        let first = try #require(initialRequests.first)
        #expect(first.command == "printf complete")
        #expect(first.arguments == nil)
        #expect(first.waitAfterCommand)

        #expect(runtime.enqueue(.reparent(workspaceID: targetWorkspaceID)).accepted)
        #expect(runtime.enqueue(.focus(false)).accepted)
        await client.waitForMutationCount(2)
        await client.waitForRendererSubscriberCount(1)
        await client.publish(.connectionLost(first.authorityForTesting))
        await client.waitForEnsureCount(2)

        let requests = await client.ensureRequests()
        #expect(requests[1].appWorkspaceID == targetWorkspaceID)
        #expect(requests[1].appSurfaceID == surfaceID)
        #expect(requests[1].waitAfterCommand)
    }

    @Test @MainActor
    func daemonOriginMoveAdoptsPlacementWithoutEchoAndRebindsRendererRuntime() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let sourceWorkspaceID = UUID()
        let destinationWorkspaceID = UUID()
        let surfaceID = UUID()
        await gate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: sourceWorkspaceID,
                surfaceID: surfaceID
            ),
        ])
        let factory = PersistentTerminalPanelFactory(
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies,
            backendClient: client,
            launchResolver: makeLaunchResolver(),
            presentationRegistry: TerminalBackendPresentationRegistry(),
            renderConfigSource: TerminalBackendRenderConfigSource {
                Data("font-family = Menlo\n".utf8)
            },
            topologyAuthorizationGate: gate
        )
        let panel = factory.makeTerminalPanel(TerminalPanelCreationRequest(
            origin: .workspaceInitial,
            id: surfaceID,
            workspaceId: sourceWorkspaceID
        ))
        defer {
            panel.surface.detachExternalPresentationPreservingCanonicalTerminal()
            panel.close()
        }
        await client.waitForEnsureCount(1)
        await client.waitForUXReadCount(1)

        panel.installCanonicalWorkspaceId(destinationWorkspaceID)
        await gate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: destinationWorkspaceID,
                surfaceID: surfaceID
            ),
        ])
        await client.waitForEnsureCount(2)

        let requests = await client.ensureRequests()
        let mutations = await client.mutations()
        let detachCount = await client.detachedPresentationCount()
        #expect(requests.map(\.appWorkspaceID) == [
            sourceWorkspaceID,
            destinationWorkspaceID,
        ])
        #expect(mutations.allSatisfy { mutation in
            if case .reparent = mutation.mutation { return false }
            return true
        })
        #expect(detachCount == 1)
        #expect(panel.workspaceId == destinationWorkspaceID)
        #expect(panel.surface.tabId == destinationWorkspaceID)
    }

    @Test @MainActor
    func canonicalMoveDuringSuspendedLaunchResolutionNeverEnsuresOldPlacement() async {
        let client = RecordingPersistentTerminalBackendClient()
        let resolver = SuspendedTerminalLaunchResolver()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let sourceWorkspaceID = UUID()
        let destinationWorkspaceID = UUID()
        let surfaceID = UUID()
        await gate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: destinationWorkspaceID,
                surfaceID: surfaceID
            ),
        ])
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: sourceWorkspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: TerminalBackendPresentationRegistry(),
            topologyAuthorizationGate: gate,
            launchResolution: { request in
                await resolver.resolve(request)
            }
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: sourceWorkspaceID
        ))
        defer {
            lease.detach()
            Task { await resolver.resumeAll() }
        }

        await resolver.waitForRequestCount(1)
        runtime.adoptCanonicalPlacement(workspaceID: destinationWorkspaceID)
        #expect(runtime.enqueue(.focus(true)).accepted)
        await resolver.resume(at: 0)
        await resolver.waitForRequestCount(2)
        await resolver.resume(at: 1)
        await client.waitForEnsureCount(1)
        await client.waitForUXReadCount(1)
        await client.waitForMutationCount(1)

        let launchRequests = await resolver.requests()
        let ensuredRequests = await client.ensureRequests()
        let mutations = await client.mutations()
        let launchWorkspaces = launchRequests.map(\.workspaceID)
        let ensuredWorkspaces = ensuredRequests.map(\.appWorkspaceID)
        let uxWorkspaces = await client.uxReadWorkspaceIDs()
        #expect(launchWorkspaces == [sourceWorkspaceID, destinationWorkspaceID])
        #expect(ensuredWorkspaces == [destinationWorkspaceID])
        #expect(uxWorkspaces == [destinationWorkspaceID])
        #expect(mutations.map(\.bindingWorkspaceID) == [destinationWorkspaceID])
        #expect(runtime.snapshot.lifecycle == .live)
    }

    @Test @MainActor
    func canonicalMoveDuringSuspendedEnsureCannotInstallOrClearStaleBinding() async {
        let client = RecordingPersistentTerminalBackendClient(suspendEnsures: true)
        let gate = TerminalBackendTopologyAuthorizationGate()
        let sourceWorkspaceID = UUID()
        let destinationWorkspaceID = UUID()
        let surfaceID = UUID()
        await gate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: sourceWorkspaceID,
                surfaceID: surfaceID
            ),
            TerminalBackendTopologyPlacement(
                workspaceID: destinationWorkspaceID,
                surfaceID: surfaceID
            ),
        ])
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: sourceWorkspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: TerminalBackendPresentationRegistry(),
            topologyAuthorizationGate: gate
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: sourceWorkspaceID
        ))
        defer {
            lease.detach()
            Task { await client.resumeAllEnsures() }
        }

        await client.waitForEnsureCount(1)
        runtime.adoptCanonicalPlacement(workspaceID: destinationWorkspaceID)
        #expect(runtime.enqueue(.focus(true)).accepted)
        await client.resumeEnsure(at: 0)
        await client.waitForDetachCount(1)
        await client.waitForEnsureCount(2)
        await client.resumeEnsure(at: 1)
        await client.waitForUXReadCount(1)
        await client.waitForMutationCount(1)

        let requests = await client.ensureRequests()
        let detachedWorkspaces = await client.detachedBindingWorkspaceIDs()
        let uxWorkspaces = await client.uxReadWorkspaceIDs()
        let mutations = await client.mutations()
        #expect(requests.map(\.appWorkspaceID) == [
            sourceWorkspaceID,
            destinationWorkspaceID,
        ])
        #expect(detachedWorkspaces == [sourceWorkspaceID])
        #expect(uxWorkspaces == [destinationWorkspaceID])
        #expect(mutations.map(\.bindingWorkspaceID) == [destinationWorkspaceID])
        #expect(runtime.snapshot.lifecycle == .live)
    }

    @Test @MainActor
    func topologyEpochAdvanceDuringEnsureDiscardsBindingUntilReauthorized() async {
        let client = RecordingPersistentTerminalBackendClient(suspendEnsures: true)
        let gate = TerminalBackendTopologyAuthorizationGate()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let placement = TerminalBackendTopologyPlacement(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        await gate.authorize([placement])
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: TerminalBackendPresentationRegistry(),
            topologyAuthorizationGate: gate
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        ))
        defer {
            lease.detach()
            Task { await client.resumeAllEnsures() }
        }

        await client.waitForEnsureCount(1)
        gate.advanceAdmissionEpoch()
        await client.resumeEnsure(at: 0)
        await client.waitForDetachCount(1)

        #expect(runtime.snapshot.lifecycle == .unavailable)
        #expect(await client.uxReadWorkspaceIDs().isEmpty)
        #expect(await client.ensureRequests().count == 1)

        await gate.authorize([placement])
        await client.waitForEnsureCount(2)
        #expect(runtime.enqueue(.focus(true)).accepted)
        await client.resumeEnsure(at: 1)
        await client.waitForUXReadCount(1)
        await client.waitForMutationCount(1)

        #expect(await client.detachedBindingWorkspaceIDs() == [workspaceID])
        #expect(await client.uxReadWorkspaceIDs() == [workspaceID])
        #expect(runtime.snapshot.lifecycle == .live)
    }

    @Test @MainActor
    func topologyEpochAdvanceDuringUXReadDiscardsBindingUntilReauthorized() async {
        let client = RecordingPersistentTerminalBackendClient(suspendUXReads: true)
        let gate = TerminalBackendTopologyAuthorizationGate()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let placement = TerminalBackendTopologyPlacement(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        await gate.authorize([placement])
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: TerminalBackendPresentationRegistry(),
            topologyAuthorizationGate: gate
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        ))
        defer {
            lease.detach()
            Task { await client.resumeAllUXReads() }
        }

        await client.waitForUXReadCount(1)
        gate.advanceAdmissionEpoch()
        await client.resumeUXRead(at: 0)
        await client.waitForDetachCount(1)

        #expect(runtime.snapshot.lifecycle == .unavailable)
        #expect(await client.ensureRequests().count == 1)
        #expect((await client.mutations()).isEmpty)

        await gate.authorize([placement])
        await client.waitForEnsureCount(2)
        await client.waitForUXReadCount(2)
        #expect(runtime.enqueue(.focus(true)).accepted)
        await client.resumeUXRead(at: 1)
        await client.waitForMutationCount(1)

        #expect(await client.detachedBindingWorkspaceIDs() == [workspaceID])
        #expect(await client.uxReadWorkspaceIDs() == [workspaceID, workspaceID])
        #expect(runtime.snapshot.lifecycle == .live)
    }

    @Test @MainActor
    func rapidCanonicalMovesCoalesceToLatestPlacement() async {
        let client = RecordingPersistentTerminalBackendClient()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let workspaceA = UUID()
        let workspaceB = UUID()
        let workspaceC = UUID()
        let surfaceID = UUID()
        await gate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: workspaceA,
                surfaceID: surfaceID
            ),
            TerminalBackendTopologyPlacement(
                workspaceID: workspaceC,
                surfaceID: surfaceID
            ),
        ])
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: workspaceA,
                surfaceID: surfaceID
            ),
            presentationRegistry: TerminalBackendPresentationRegistry(),
            topologyAuthorizationGate: gate
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: workspaceA
        ))
        defer { lease.detach() }

        await client.waitForEnsureCount(1)
        await client.waitForUXReadCount(1)
        runtime.adoptCanonicalPlacement(workspaceID: workspaceB)
        runtime.adoptCanonicalPlacement(workspaceID: workspaceC)
        #expect(runtime.enqueue(.focus(true)).accepted)
        await client.waitForEnsureCount(2)
        await client.waitForUXReadCount(2)
        await client.waitForMutationCount(1)

        let requests = await client.ensureRequests()
        let detachedWorkspaces = await client.detachedBindingWorkspaceIDs()
        let uxWorkspaces = await client.uxReadWorkspaceIDs()
        let mutations = await client.mutations()
        #expect(requests.map(\.appWorkspaceID) == [workspaceA, workspaceC])
        #expect(detachedWorkspaces == [workspaceA])
        #expect(uxWorkspaces == [workspaceA, workspaceC])
        #expect(mutations.map(\.bindingWorkspaceID) == [workspaceC])
        #expect(runtime.snapshot.lifecycle == .live)
    }

    @Test @MainActor
    func canonicalMoveRejectsLateRendererAttachmentFromPriorPresentation() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        let registry = TerminalBackendPresentationRegistry()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let sourceWorkspaceID = UUID()
        let destinationWorkspaceID = UUID()
        let surfaceID = UUID()
        await gate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: sourceWorkspaceID,
                surfaceID: surfaceID
            ),
            TerminalBackendTopologyPlacement(
                workspaceID: destinationWorkspaceID,
                surfaceID: surfaceID
            ),
        ])
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: sourceWorkspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: registry,
            renderConfigSource: TerminalBackendRenderConfigSource {
                Data("font-family = Menlo\n".utf8)
            },
            topologyAuthorizationGate: gate
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: sourceWorkspaceID
        ))
        defer { lease.detach() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        #expect(registry.mountCompositor(surfaceID: surfaceID, in: host))
        let viewport = TerminalExternalViewport(
            widthPoints: 640,
            heightPoints: 480,
            widthPixels: 1_280,
            heightPixels: 960,
            xScale: 2,
            yScale: 2,
            proposedColumns: 160,
            proposedRows: 48
        )

        await client.waitForEnsureCount(1)
        await client.waitForUXReadCount(1)
        #expect(runtime.enqueue(.visibility(true)).accepted)
        #expect(runtime.enqueue(.resize(viewport)).accepted)
        await client.waitForMutationCount(1)
        let priorPresentationID = runtime.debugPresentationIDForTesting()
        #expect(registry.compositorView(surfaceID: surfaceID) != nil)

        runtime.adoptCanonicalPlacement(workspaceID: destinationWorkspaceID)
        #expect(registry.compositorView(surfaceID: surfaceID) == nil)
        await client.waitForEnsureCount(2)
        await client.waitForUXReadCount(2)
        await client.waitForMutationCount(2)
        let currentPresentationID = runtime.debugPresentationIDForTesting()
        #expect(currentPresentationID != priorPresentationID)
        #expect(runtime.snapshot.cellMetrics == nil)

        let staleMetrics = TerminalExternalCellMetrics(
            columns: 1,
            rows: 1,
            cellWidthPixels: 8,
            cellHeightPixels: 16,
            surfaceWidthPixels: 1_280,
            surfaceHeightPixels: 960,
            backingScale: 2
        )
        let currentMetrics = TerminalExternalCellMetrics(
            columns: 160,
            rows: 48,
            cellWidthPixels: 8,
            cellHeightPixels: 20,
            surfaceWidthPixels: 1_280,
            surfaceHeightPixels: 960,
            backingScale: 2
        )
        let worker = try TerminalRenderWorkerIdentity(
            processID: 42,
            effectiveUserID: 501
        )
        let staleAttachment = TerminalBackendRendererAttachment(
            fence: try TerminalRenderPresentationFence(
                daemonInstanceID: UUID(),
                rendererEpoch: 1,
                terminalID: surfaceID,
                terminalEpoch: 1,
                minimumTerminalSequence: 0,
                presentationID: priorPresentationID,
                presentationGeneration: 1,
                width: 1_280,
                height: 960,
                pixelFormat: .bgra8Unorm,
                colorSpace: .sRGB,
                completionRequirement: .producerCompleted
            ),
            worker: worker,
            cellMetrics: staleMetrics
        )
        await runtime.debugHandleRendererEventForTesting(.presentationReady(
            presentationID: priorPresentationID,
            attachment: staleAttachment
        ))
        #expect(runtime.snapshot.cellMetrics == nil)

        let currentAttachment = TerminalBackendRendererAttachment(
            fence: try TerminalRenderPresentationFence(
                daemonInstanceID: UUID(),
                rendererEpoch: 2,
                terminalID: surfaceID,
                terminalEpoch: 1,
                minimumTerminalSequence: 0,
                presentationID: currentPresentationID,
                presentationGeneration: 1,
                width: 1_280,
                height: 960,
                pixelFormat: .bgra8Unorm,
                colorSpace: .sRGB,
                completionRequirement: .producerCompleted
            ),
            worker: worker,
            cellMetrics: currentMetrics
        )
        await runtime.debugHandleRendererEventForTesting(.presentationReady(
            presentationID: currentPresentationID,
            attachment: currentAttachment
        ))
        #expect(runtime.snapshot.cellMetrics == currentMetrics)
    }

    @Test @MainActor
    func detachDuringSuspendedEnsureRejectsTheLateBinding() async {
        let client = RecordingPersistentTerminalBackendClient(suspendEnsures: true)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: TerminalBackendPresentationRegistry()
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        ))

        await client.waitForEnsureCount(1)
        lease.detach()
        await client.waitForDetachCount(1)
        await client.resumeEnsure(at: 0)
        await client.waitForDetachCount(2)

        let detachedWorkspaces = await client.detachedBindingWorkspaceIDs()
        let uxWorkspaces = await client.uxReadWorkspaceIDs()
        #expect(detachedWorkspaces == [nil, workspaceID])
        #expect(uxWorkspaces.isEmpty)
        #expect(!runtime.enqueue(.focus(true)).accepted)
    }

    @Test @MainActor
    func rendererPresentationRequiresVisibilityMountAndViewport() async throws {
        let client = RecordingPersistentTerminalBackendClient()
        let registry = TerminalBackendPresentationRegistry()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: registry,
            renderConfigSource: TerminalBackendRenderConfigSource {
                Data("font-family = Menlo\nbackground = #112233\n".utf8)
            }
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        ))
        defer { lease.detach() }
        await client.waitForEnsureCount(1)

        #expect(runtime.enqueue(.visibility(true)).accepted)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        #expect(registry.mountCompositor(surfaceID: surfaceID, in: host))
        let viewport = TerminalExternalViewport(
            widthPoints: 640,
            heightPoints: 480,
            widthPixels: 1280,
            heightPixels: 960,
            xScale: 2,
            yScale: 2,
            proposedColumns: nil,
            proposedRows: nil
        )
        #expect(runtime.enqueue(.resize(viewport)).accepted)
        await client.waitForMutationCount(1)

        let visibleMutations = await client.mutations()
        let visible = try #require(visibleMutations.last)
        #expect(visibleMutations.count == 1)
        #expect(visible.mutation == .resize(viewport))
        #expect(visible.presentation?.visible == true)
        #expect(visible.presentation?.viewport == viewport)

        #expect(runtime.enqueue(.visibility(false)).accepted)
        await client.waitForMutationCount(2)
        let hiddenMutations = await client.mutations()
        let hidden = try #require(hiddenMutations.last)
        #expect(hidden.mutation == .visibility(false))
        #expect(hidden.presentation?.visible == false)
    }

    @Test @MainActor
    func liveRenderConfigReloadReconfiguresOnlyTheVisiblePresentation() async throws {
        let notificationCenter = NotificationCenter()
        let notificationName = Notification.Name("test.persistent-terminal.config-reload")
        var serializedConfig = Data("""
            font-family = Fira Code
            background = #112233
            custom-shader = /tmp/old.glsl
            """.utf8)
        let source = TerminalBackendRenderConfigSource(
            serializer: { serializedConfig },
            notificationCenter: notificationCenter,
            notificationName: notificationName
        )
        let client = RecordingPersistentTerminalBackendClient()
        let registry = TerminalBackendPresentationRegistry()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: registry,
            renderConfigSource: source,
            presentationConfigOverrides: Data("font-size = 17\n".utf8)
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        ))
        defer { lease.detach() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        #expect(registry.mountCompositor(surfaceID: surfaceID, in: host))
        #expect(runtime.enqueue(.visibility(true)).accepted)
        let viewport = TerminalExternalViewport(
            widthPoints: 640,
            heightPoints: 480,
            widthPixels: 1280,
            heightPixels: 960,
            xScale: 2,
            yScale: 2,
            proposedColumns: nil,
            proposedRows: nil
        )
        #expect(runtime.enqueue(.resize(viewport)).accepted)
        await client.waitForMutationCount(1)

        let recordedInitial = await client.lastMutation()
        let initial = try #require(recordedInitial)
        let initialConfig = try #require(initial.presentation?.resolvedConfig)
        let initialString = try #require(String(data: initialConfig, encoding: .utf8))
        #expect(initialString.contains("font-family = Fira Code"))
        #expect(initialString.contains("custom-shader = /tmp/old.glsl"))
        #expect(initialString.hasSuffix("font-size = 17\n"))

        serializedConfig = Data("""
            font-family = Iosevka
            background = #445566
            custom-shader = /tmp/new.glsl
            """.utf8)
        notificationCenter.post(name: notificationName, object: nil)
        await client.waitForMutationCount(2)

        let updatedMutations = await client.mutations()
        let updated = try #require(updatedMutations.last)
        let updatedConfig = try #require(updated.presentation?.resolvedConfig)
        let updatedString = try #require(String(data: updatedConfig, encoding: .utf8))
        #expect(updated.mutation == .resize(viewport))
        #expect(updated.presentation?.resolvedConfigRevision != initial.presentation?.resolvedConfigRevision)
        #expect(updatedString.contains("font-family = Iosevka"))
        #expect(updatedString.contains("custom-shader = /tmp/new.glsl"))
        #expect(updatedString.hasSuffix("font-size = 17\n"))
        #expect(updatedMutations.allSatisfy { mutation in
            if case .resize = mutation.mutation { return true }
            return false
        })
    }

    @Test
    func persistentIngressQueueIsBoundedFIFO() {
        let first = TerminalBackendQueuedMutation(
            sequence: 7,
            requestID: UUID(),
            mutation: .focus(true)
        )
        let second = TerminalBackendQueuedMutation(
            sequence: 8,
            requestID: UUID(),
            mutation: .visibility(false)
        )
        var queue = TerminalBackendMutationQueue(capacity: 2)

        let acceptedFirst = queue.append(first)
        let acceptedSecond = queue.append(second)
        let acceptedOverflow = queue.append(TerminalBackendQueuedMutation(
            sequence: 9,
            requestID: UUID(),
            mutation: .closeCanonicalTerminal
        ))
        #expect(queue.first == first)
        let poppedFirst = queue.removeFirst()
        #expect(queue.first == second)
        let poppedSecond = queue.removeFirst()
        let poppedEmpty = queue.removeFirst()

        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(!acceptedOverflow)
        #expect(poppedFirst == first)
        #expect(poppedSecond == second)
        #expect(poppedEmpty == nil)
    }

    @Test @MainActor
    func ambiguousMutationRemainsQueuedWithOneRequestIDAcrossReconnect() async throws {
        let client = RecordingPersistentTerminalBackendClient(failFirstMutation: true)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: TerminalBackendPresentationRegistry()
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        ))
        defer { lease.detach() }

        await client.waitForEnsureCount(1)
        #expect(runtime.enqueue(.focus(true)).accepted)
        await client.waitForMutationCount(1)
        for _ in 0 ..< 100 where !runtime.debugIsUnavailableForTesting() {
            await Task.yield()
        }
        let queuedRequestID = try #require(
            runtime.debugFirstQueuedMutationRequestIDForTesting()
        )
        #expect(runtime.debugIsUnavailableForTesting())

        let request = try #require((await client.ensureRequests()).first)
        await runtime.debugHandleRendererEventForTesting(
            .connectionLost(request.authorityForTesting)
        )
        await client.waitForEnsureCount(2)
        await client.waitForMutationCount(2)

        let mutations = await client.mutations()
        #expect(mutations.map(\.mutation) == [.focus(true), .focus(true)])
        #expect(mutations.map(\.requestID) == [queuedRequestID, queuedRequestID])
        #expect(runtime.debugFirstQueuedMutationRequestIDForTesting() == nil)
    }

    @Test
    func invalidBackendBundleIdentityNeverFallsThroughToProductionNamespace() {
        let missing = cmuxApp.terminalBackendDescriptor(bundleIdentifier: nil)
        let malformed = cmuxApp.terminalBackendDescriptor(bundleIdentifier: "bad bundle/id")
        let production = cmuxApp.terminalBackendDescriptor(
            bundleIdentifier: BackendServiceDescriptor.productionBundleIdentifier
        )

        #expect(missing == cmuxApp.quarantinedTerminalBackendDescriptor)
        #expect(malformed == cmuxApp.quarantinedTerminalBackendDescriptor)
        #expect(missing != .production)
        #expect(malformed != .production)
        #expect(production == .production)
    }

    @Test @MainActor
    func appTerminationDetachesPersistentPresentationWhilePanelCloseTerminatesPTY() async {
        let client = RecordingPersistentTerminalBackendClient()
        let topologyAuthorizationGate = TerminalBackendTopologyAuthorizationGate()
        let factory = PersistentTerminalPanelFactory(
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies,
            backendClient: client,
            launchResolver: makeLaunchResolver(),
            presentationRegistry: TerminalBackendPresentationRegistry(),
            renderConfigSource: TerminalBackendRenderConfigSource {
                Data("font-family = Menlo\n".utf8)
            },
            topologyAuthorizationGate: topologyAuthorizationGate
        )

        let quitWorkspaceID = UUID()
        let quitSurfaceID = UUID()
        await topologyAuthorizationGate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: quitWorkspaceID,
                surfaceID: quitSurfaceID
            ),
        ])
        let quitPanel = factory.makeTerminalPanel(TerminalPanelCreationRequest(
            origin: .workspaceInitial,
            id: quitSurfaceID,
            workspaceId: quitWorkspaceID
        ))
        await client.waitForEnsureCount(1)
        #expect(AppDelegate.detachPersistentTerminalPresentationsForAppTermination([
            quitPanel.surface
        ]) == 1)
        quitPanel.close()
        await Task.yield()
        let mutationsAfterQuit = await client.mutations()
        #expect(!mutationsAfterQuit.contains { $0.mutation == .closeCanonicalTerminal })

        let closeWorkspaceID = UUID()
        let closeSurfaceID = UUID()
        await topologyAuthorizationGate.authorize([
            TerminalBackendTopologyPlacement(
                workspaceID: closeWorkspaceID,
                surfaceID: closeSurfaceID
            ),
        ])
        let explicitlyClosedPanel = factory.makeTerminalPanel(TerminalPanelCreationRequest(
            origin: .workspaceTab,
            id: closeSurfaceID,
            workspaceId: closeWorkspaceID
        ))
        await client.waitForEnsureCount(2)
        explicitlyClosedPanel.close()
        await client.waitForMutationCount(1)
        let mutationsAfterClose = await client.mutations()
        #expect(mutationsAfterClose.filter { $0.mutation == .closeCanonicalTerminal }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func backendObservationOverflowClosesOldSessionAndRecoversAfterRetryExhaustion() async throws {
        let firstAuthority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let secondAuthority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: firstAuthority.sessionID
        )
        let emptyTopology = try CanonicalTopology(workspaces: [])
        let firstSnapshot = TopologySnapshot(
            authority: firstAuthority,
            revision: 1,
            topology: emptyTopology
        )
        let latestSnapshot = TopologySnapshot(
            authority: secondAuthority,
            revision: 1_000,
            topology: emptyTopology
        )
        let rendererChange = try makeBackendWorkerChange()
        let targets = try TopologyTargets()
        var burst: [BackendCanonicalSessionEvent] = []
        burst.reserveCapacity(600)
        var topologyRevision: UInt64 = 1
        for index in 0..<600 {
            if index.isMultiple(of: 2) {
                topologyRevision += 1
                burst.append(.delta(TopologyDelta(
                    authority: firstAuthority,
                    baseRevision: topologyRevision - 1,
                    revision: topologyRevision,
                    operation: .layoutApplied,
                    targets: targets,
                    replacement: emptyTopology
                )))
            } else {
                burst.append(.rendererWorkerChanged(rendererChange))
            }
        }

        let lifecycle = BackendSessionLifecycleRecorder()
        let firstSession = OverflowingBackendSession(
            identifier: "first",
            snapshot: firstSnapshot,
            initialEvents: burst,
            lifecycle: lifecycle
        )
        let secondSession = OverflowingBackendSession(
            identifier: "second",
            snapshot: latestSnapshot,
            initialEvents: nil,
            lifecycle: lifecycle
        )
        let readiness = ScriptedBackendReadiness(results: [
            .ready(makeBackendReadiness(authority: firstAuthority, processID: 41, revision: 1)),
            .backendUnavailable,
            .backendUnavailable,
            .backendUnavailable,
            .ready(makeBackendReadiness(
                authority: secondAuthority,
                processID: 42,
                revision: latestSnapshot.revision
            )),
        ])
        let coordinator = TerminalBackendClientCoordinator(
            readinessProvider: { await readiness.next() },
            sessionFactory: { proof in
                proof.processID == 41 ? firstSession : secondSession
            },
            reconnectPolicy: TerminalBackendReconnectPolicy(
                delays: [.zero, .zero],
                recoveryCycleDelay: .zero
            )
        )

        let events = try await coordinator.canonicalTopologyEvents()
        let recoveredRevision = try await withReconnectTestTimeout(.seconds(5)) {
            for await event in events {
                let revision: UInt64?
                switch event {
                case .snapshot(let snapshot):
                    revision = snapshot.revision
                case .delta(let delta):
                    revision = delta.revision
                case .disconnected:
                    revision = nil
                }
                if let revision, revision >= latestSnapshot.revision {
                    return revision
                }
            }
            throw ReconnectSupervisorTestError.streamEnded
        }

        #expect(recoveredRevision == latestSnapshot.revision)
        #expect(await readiness.requestCount() >= 5)
        #expect(await firstSession.closeCount() == 1)
        #expect(await secondSession.connectCount() == 1)
        #expect(await lifecycle.activeIdentifiers() == ["second"])
        #expect(await lifecycle.maximumActiveCount() == 1)

        await coordinator.disconnectFrontend()
        #expect(await secondSession.closeCount() == 1)
        #expect(await lifecycle.activeIdentifiers().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func backendCompatibilityReportsEachConnectionAndClearsAcrossReconnectAndDisconnect() async throws {
        let firstAuthority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let secondAuthority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: firstAuthority.sessionID
        )
        let topology = try CanonicalTopology(workspaces: [])
        let readWrite: BackendCompatibilityResult = .readWrite(BackendReadWriteCompatibility(
            clientProtocolRange: 8 ... 9,
            serverProtocolRange: 8 ... 9,
            negotiatedProtocol: 9,
            requiredCapabilities: BackendHandshakePolicy.terminalAuthorityV1.requiredCapabilities
        ))
        let readOnly: BackendCompatibilityResult = .readOnly(BackendReadOnlyCompatibility(
            clientProtocolRange: 8 ... 9,
            serverProtocolRange: 8 ... 8,
            negotiatedProtocol: 8,
            minimumReadWriteProtocol: 9,
            requiredCapabilities: BackendHandshakePolicy.terminalAuthorityV1.requiredCapabilities,
            missingCapabilities: [],
            reasons: [.protocolTooOld]
        ))
        let lifecycle = BackendSessionLifecycleRecorder()
        let firstSession = OverflowingBackendSession(
            identifier: "read-write",
            snapshot: TopologySnapshot(
                authority: firstAuthority,
                revision: 1,
                topology: topology
            ),
            initialEvents: nil,
            compatibility: readWrite,
            lifecycle: lifecycle
        )
        let secondSession = OverflowingBackendSession(
            identifier: "read-only",
            snapshot: TopologySnapshot(
                authority: secondAuthority,
                revision: 2,
                topology: topology
            ),
            initialEvents: nil,
            compatibility: readOnly,
            lifecycle: lifecycle
        )
        let readiness = ScriptedBackendReadiness(results: [
            .ready(makeBackendReadiness(
                authority: firstAuthority,
                processID: 51,
                revision: 1,
                compatibility: readWrite
            )),
            .ready(makeBackendReadiness(
                authority: secondAuthority,
                processID: 52,
                revision: 2,
                compatibility: readOnly
            )),
        ])
        let reports = BackendCompatibilityReporterRecorder()
        let coordinator = TerminalBackendClientCoordinator(
            readinessProvider: { await readiness.next() },
            sessionFactory: { proof in
                proof.processID == 51 ? firstSession : secondSession
            },
            reconnectPolicy: .immediate,
            compatibilityReporter: { compatibility in
                await reports.record(compatibility)
            }
        )

        await coordinator.start()
        try await waitForCompatibilityReportCount(1, reports: reports)
        try await waitForEventSubscriptionCount(1, session: firstSession)
        #expect(await reports.recorded() == [readWrite])

        await firstSession.disconnectEventStream()
        try await waitForCompatibilityReportCount(3, reports: reports)
        try await waitForEventSubscriptionCount(1, session: secondSession)
        #expect(await reports.recorded() == [readWrite, nil, readOnly])

        await coordinator.disconnectFrontend()
        try await waitForCompatibilityReportCount(4, reports: reports)
        #expect(await reports.recorded() == [readWrite, nil, readOnly, nil])
        #expect(await firstSession.closeCount() == 1)
        #expect(await secondSession.closeCount() == 1)
        #expect(await lifecycle.activeIdentifiers().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func diagnosticOnlyBackendStaysConnectedWithoutInventingTopology() async throws {
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let readOnly: BackendCompatibilityResult = .readOnly(BackendReadOnlyCompatibility(
            clientProtocolRange: 8 ... 9,
            serverProtocolRange: 10 ... 11,
            negotiatedProtocol: nil,
            minimumReadWriteProtocol: 9,
            requiredCapabilities: BackendHandshakePolicy.terminalAuthorityV1.requiredCapabilities,
            missingCapabilities: BackendHandshakePolicy.terminalAuthorityV1.requiredCapabilities,
            reasons: [.incompatibleProtocol, .missingCapabilities]
        ))
        let lifecycle = BackendSessionLifecycleRecorder()
        let session = OverflowingBackendSession(
            identifier: "diagnostic-only",
            snapshot: nil,
            initialEvents: nil,
            compatibility: readOnly,
            lifecycle: lifecycle
        )
        let reports = BackendCompatibilityReporterRecorder()
        let readiness = makeBackendReadiness(
            authority: authority,
            processID: 53,
            revision: 7,
            compatibility: readOnly
        )
        let coordinator = TerminalBackendClientCoordinator(
            readinessProvider: { .ready(readiness) },
            sessionFactory: { _ in session },
            reconnectPolicy: .immediate,
            compatibilityReporter: { compatibility in
                await reports.record(compatibility)
            }
        )

        await coordinator.start()
        try await waitForCompatibilityReportCount(1, reports: reports)
        try await waitForEventSubscriptionCount(1, session: session)
        #expect(await reports.recorded() == [readOnly])
        #expect(await session.connectCount() == 1)
        #expect(await session.closeCount() == 0)
        #expect(await lifecycle.activeIdentifiers() == ["diagnostic-only"])

        await coordinator.disconnectFrontend()
        try await waitForCompatibilityReportCount(2, reports: reports)
        #expect(await reports.recorded() == [readOnly, nil])
        #expect(await session.closeCount() == 1)
        #expect(await lifecycle.activeIdentifiers().isEmpty)
    }

    private func waitForCompatibilityReportCount(
        _ count: Int,
        reports: BackendCompatibilityReporterRecorder
    ) async throws {
        try await withReconnectTestTimeout(.seconds(5)) {
            while await reports.count() < count {
                await Task.yield()
            }
        }
    }

    private func waitForEventSubscriptionCount(
        _ count: Int,
        session: OverflowingBackendSession
    ) async throws {
        try await withReconnectTestTimeout(.seconds(5)) {
            while await session.eventSubscriptionCount() < count {
                await Task.yield()
            }
        }
    }

    @MainActor
    private func makeLaunchResolver() -> TerminalSurfaceLaunchResolver {
        let dependencies = GhosttyApp.terminalSurfaceRuntimeDependencies
        return TerminalSurfaceLaunchResolver(
            engine: dependencies.engine,
            spawnPolicyProvider: dependencies.spawnPolicy,
            runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                claudeCommandShimTemporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                installClaudeCommandShim: { _, _, _ in nil },
                isExecutableFile: { _ in false }
            ),
            sessionPortBase: 40_000,
            sessionPortRangeSize: 100,
            resourceURL: nil,
            bundleIdentifier: "com.cmux.test.persistent-terminal",
            ambientEnvironment: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"],
            defaultShellArguments: { ["/bin/zsh", "-l"] }
        )
    }

    private func makeLaunchRequest(
        workspaceID: UUID,
        surfaceID: UUID,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        portOrdinal: Int = 0
    ) -> TerminalSurfaceLaunchRequest {
        TerminalSurfaceLaunchRequest(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            configTemplate: configTemplate,
            workingDirectory: nil,
            portOrdinal: portOrdinal,
            initialCommand: nil,
            initialInput: nil,
            initialEnvironmentOverrides: [:],
            additionalEnvironment: [:]
        )
    }

    private func makeBackendReadiness(
        authority: BackendAuthority,
        processID: UInt32,
        revision: UInt64,
        compatibility: BackendCompatibilityResult? = nil
    ) -> BackendServiceReadiness {
        BackendServiceReadiness(
            authority: authority,
            session: "cmux-test",
            processID: processID,
            userID: 501,
            peerIdentity: BackendPeerIdentity(
                processID: processID,
                userID: 501,
                auditToken: BackendAuditToken(
                    word0: processID,
                    word1: 2,
                    word2: 3,
                    word3: 4,
                    word4: 5,
                    word5: 6,
                    word6: 7,
                    word7: 8
                )
            ),
            peerTrust: BackendPeerTrustEvidence(
                signingIdentifier: "com.cmux.test.backend",
                teamIdentifier: nil,
                executableURL: URL(fileURLWithPath: "/tmp/cmux-test-backend"),
                processIDVersion: Int32(bitPattern: processID)
            ),
            topologyRevision: revision,
            compatibility: compatibility ?? .readWrite(BackendReadWriteCompatibility(
                clientProtocolRange: 8 ... 9,
                serverProtocolRange: 8 ... 9,
                negotiatedProtocol: 9,
                requiredCapabilities: BackendHandshakePolicy.terminalAuthorityV1.requiredCapabilities
            ))
        )
    }

    private func makeBackendWorkerChange() throws -> BackendRendererWorkerChanged {
        let workspaceID = WorkspaceID(rawValue: UUID())
        return try JSONDecoder().decode(
            BackendRendererWorkerChanged.self,
            from: Data("""
                {
                  "workspace_uuid": "\(workspaceID.description)",
                  "prior_renderer_epoch": 1,
                  "renderer_epoch": 2,
                  "pid": 88,
                  "effective_user_id": 501,
                  "scene_capabilities": 1,
                  "state": "ready",
                  "restart_count": 0
                }
                """.utf8)
        )
    }

    @Test
    func terminalAccessibilityConversionPreservesUTF16AndRejectsOutOfBoundsRanges() throws {
        let backendSurfaceID = UUID()
        let backendPresentationID = UUID()
        let appSurfaceID = UUID()
        let appPresentationID = UUID()
        let valid = try JSONDecoder().decode(
            BackendTerminalAccessibilitySnapshot.self,
            from: Data("""
                {
                  "schema_version": 1,
                  "surface_uuid": "\(backendSurfaceID.uuidString)",
                  "presentation_id": "\(backendPresentationID.uuidString)",
                  "presentation_generation": 7,
                  "content_sequence": 13,
                  "terminal_revision": 11,
                  "content_revision": 9,
                  "viewport_revision": 3,
                  "viewport_offset": 40,
                  "columns": 5,
                  "rows": 1,
                  "text": "🙂é界",
                  "lines": [{
                    "row": 40,
                    "utf16_range": {"location": 0, "length": 5},
                    "cells": [
                      {"column": 0, "column_span": 2, "utf16_range": {"location": 0, "length": 2}},
                      {"column": 2, "column_span": 1, "utf16_range": {"location": 2, "length": 2}},
                      {"column": 3, "column_span": 2, "utf16_range": {"location": 4, "length": 1}}
                    ]
                  }],
                  "cursor": {"column": 2, "row": 40, "insertion_range": {"location": 2, "length": 0}, "line": 0},
                  "selections": [],
                  "links": [],
                  "focused": true
                }
                """.utf8)
        )
        let snapshot = try valid.externalSnapshot(
            appSurfaceID: appSurfaceID,
            appPresentationID: appPresentationID
        )
        #expect(snapshot.surfaceID == appSurfaceID)
        #expect(snapshot.presentationID == appPresentationID)
        #expect(snapshot.contentSequence == 13)
        #expect(snapshot.lines[0].cells.map(\.utf16Range.length) == [2, 2, 1])
        #expect(snapshot.cursor?.insertionRange.location == 2)
        #expect(snapshot.focused)
        let textModel = TerminalAccessibilityTextModel(snapshot: snapshot)
        #expect(textModel.utf16Length == 5)
        #expect(textModel.string(for: NSRange(location: 0, length: 2)) == "🙂")
        #expect(textModel.composedRange(for: 0) == NSRange(location: 0, length: 2))
        #expect(textModel.line(for: 4) == 0)
        #expect(textModel.range(forLine: 0) == NSRange(location: 0, length: 5))
        #expect(textModel.range(viewportRow: 0, column: 1) == NSRange(location: 0, length: 2))
        #expect(textModel.cells(intersecting: NSRange(location: 2, length: 2)).map(\.column) == [2])
        #expect(textModel.selectedRange == NSRange(location: 2, length: 0))
        #expect(textModel.string(for: NSRange(location: 5, length: 1)) == nil)

        let malformed = try JSONDecoder().decode(
            BackendTerminalAccessibilitySnapshot.self,
            from: Data("""
                {
                  "schema_version": 1,
                  "surface_uuid": "\(backendSurfaceID.uuidString)",
                  "presentation_id": "\(backendPresentationID.uuidString)",
                  "presentation_generation": 7,
                  "content_sequence": 13,
                  "terminal_revision": 11,
                  "content_revision": 9,
                  "viewport_revision": 3,
                  "viewport_offset": 0,
                  "columns": 1,
                  "rows": 1,
                  "text": "x",
                  "lines": [{"row": 0, "utf16_range": {"location": 0, "length": 2}, "cells": []}],
                  "cursor": null,
                  "selections": [],
                  "links": [],
                  "focused": false
                }
                """.utf8)
        )
        #expect(throws: BackendProtocolError.self) {
            _ = try malformed.externalSnapshot(
                appSurfaceID: appSurfaceID,
                appPresentationID: appPresentationID
            )
        }
    }

    @Test
    func terminalAccessibilityGeometryUsesTopOriginRowsInsideUnflippedNSView() {
        let boundsHeight = 100.0
        let inset = 10.0
        let cellHeight = 20.0
        #expect(TerminalAccessibilityGeometry.unflippedCellY(
            boundsHeight: boundsHeight,
            yInset: inset,
            cellHeight: cellHeight,
            viewportRow: 0
        ) == 70)
        #expect(TerminalAccessibilityGeometry.unflippedCellY(
            boundsHeight: boundsHeight,
            yInset: inset,
            cellHeight: cellHeight,
            viewportRow: 3
        ) == 10)
        for row in 0 ..< 4 {
            let y = TerminalAccessibilityGeometry.unflippedCellY(
                boundsHeight: boundsHeight,
                yInset: inset,
                cellHeight: cellHeight,
                viewportRow: row
            ) + cellHeight / 2
            #expect(TerminalAccessibilityGeometry.unflippedViewportRow(
                localY: y,
                boundsHeight: boundsHeight,
                yInset: inset,
                cellHeight: cellHeight
            ) == row)
        }
    }

    @Test
    func presentedFrameStateKeepsNewestVisibleSequenceAndRejectsRetiredFence() throws {
        let state = TerminalBackendPresentedFrameState()
        let first = try Self.makeRenderDiagnosticsFrame(sequence: 1).metadata
        let second = try Self.makeRenderDiagnosticsFrame(sequence: 2).metadata

        let currentFence = try TerminalRenderPresentationFence(
            daemonInstanceID: second.daemonInstanceID,
            rendererEpoch: second.rendererEpoch,
            terminalID: second.terminalID,
            terminalEpoch: second.terminalEpoch,
            minimumTerminalSequence: 1,
            presentationID: second.presentationID,
            presentationGeneration: second.presentationGeneration,
            width: second.width,
            height: second.height,
            pixelFormat: second.pixelFormat,
            colorSpace: second.colorSpace,
            completionRequirement: .producerCompleted
        )
        state.install(currentFence)
        state.record(second)
        state.record(first)
        #expect(state.latest(matching: currentFence)?.terminalSequence == 2)

        let retiredFence = try TerminalRenderPresentationFence(
            daemonInstanceID: second.daemonInstanceID,
            rendererEpoch: second.rendererEpoch + 1,
            terminalID: second.terminalID,
            terminalEpoch: second.terminalEpoch,
            minimumTerminalSequence: 1,
            presentationID: second.presentationID,
            presentationGeneration: second.presentationGeneration + 1,
            width: second.width,
            height: second.height,
            pixelFormat: second.pixelFormat,
            colorSpace: second.colorSpace,
            completionRequirement: .producerCompleted
        )
        state.install(retiredFence)
        state.record(second)
        #expect(state.latest(matching: retiredFence) == nil)
    }

    @Test @MainActor
    func hyperlinkUsesIdlePresentedFrameWithoutAccessibilityDemand() async throws {
        let client = AccessibilityRuntimeBackendClient()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: TerminalBackendPresentationRegistry()
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        ))
        defer { lease.detach() }
        _ = await runtime.readScreenText(.visible)

        let metadata = try Self.makeRenderDiagnosticsFrame(sequence: 41).metadata
        runtime.debugInstallPresentedFrameForTesting(
            fence: try Self.makePresentedFrameFence(metadata),
            metadata: metadata
        )
        let hit = await runtime.activateHyperlink(at: TerminalExternalMouseEvent(
            action: .motion,
            button: nil,
            modifiers: .command,
            xPixels: 4,
            yPixels: 6,
            anyButtonPressed: false
        ))

        #expect(hit?.target == "https://example.com/")
        #expect(hit?.contentSequence == 41)
        #expect(await client.hyperlinkContentSequences() == [41])
    }

    @Test @MainActor
    func terminalAccessibilityCacheSuppressesDuplicateRevisionsAndRefreshesAfterReconnect() async throws {
        let client = AccessibilityRuntimeBackendClient()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let runtime = PersistentTerminalExternalRuntime(
            client: client,
            launchResolver: makeLaunchResolver(),
            launchRequest: makeLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
            presentationRegistry: TerminalBackendPresentationRegistry()
        )
        let lease = runtime.attachPresentation(TerminalExternalPresentation(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        ))
        defer { lease.detach() }

        let updates = runtime.accessibilitySnapshots()
        let collector = Task { @MainActor in
            var revisions: [UInt64] = []
            for await snapshot in updates {
                revisions.append(snapshot.contentRevision)
                if revisions.count == 3 { return revisions }
            }
            return revisions
        }

        _ = await runtime.readScreenText(.visible)
        let metadata = try Self.makeRenderDiagnosticsFrame(sequence: 42).metadata
        runtime.debugInstallPresentedFrameForTesting(
            fence: try Self.makePresentedFrameFence(metadata),
            metadata: metadata
        )
        runtime.enableAccessibility()
        try await waitForAccessibilityRevision(1, runtime: runtime)

        await client.setRevision(2)
        #expect(runtime.enqueue(.focus(true)).accepted)
        try await waitForAccessibilityRevision(2, runtime: runtime)

        await client.setRevision(3)
        await runtime.debugHandleRendererEventForTesting(
            .connectionLost(await client.authority())
        )
        try await waitForAccessibilityRevision(3, runtime: runtime)

        let collected = await collector.value
        #expect(collected == [1, 2, 3])
    }

    @Test
    func renderDiagnosticsRetainsOneReceiptAcrossDeferredSubmission() throws {
        let diagnostics = TerminalBackendRenderDiagnostics(capacity: 2)
        let workspaceID = UUID()
        let frame = try Self.makeRenderDiagnosticsFrame(sequence: 1)

        diagnostics.record(
            workspaceID: workspaceID,
            frame: frame,
            result: .drawableUnavailable
        )
        diagnostics.record(
            workspaceID: workspaceID,
            frame: frame,
            result: .submitted
        )

        let payload = diagnostics.payload(reset: false)
        let ghosttyCensus = try #require(payload["ghostty_process_census"] as? [String: Any])
        #expect(ghosttyCensus["schema_version"] as? UInt32 == 1)
        let metrics = try #require(payload["metrics"] as? [String: Any])
        #expect(metrics["received_frames"] as? UInt64 == 1)
        #expect(metrics["admitted_frames"] as? UInt64 == 1)
        #expect(metrics["submitted_blits"] as? UInt64 == 1)
        #expect(metrics["drawable_unavailable_events"] as? UInt64 == 1)
        #expect(metrics["provenance_records"] as? UInt64 == 1)
        #expect(metrics["missing_provenance_records"] as? UInt64 == 0)
        let provenance = try #require(payload["provenance"] as? [String: Any])
        let records = try #require(provenance["records"] as? [[String: Any]])
        #expect(records.count == 1)
        #expect(records[0]["disposition"] as? String == "submitted")
        #expect(records[0]["workspace_id"] as? String == workspaceID.uuidString)
    }

    @Test
    func renderDiagnosticsEvictionAndResetRemainCoherent() throws {
        let diagnostics = TerminalBackendRenderDiagnostics(capacity: 2)
        for sequence in 1 ... 3 {
            diagnostics.record(
                workspaceID: UUID(),
                frame: try Self.makeRenderDiagnosticsFrame(sequence: UInt64(sequence)),
                result: .coalesced
            )
        }

        let prior = diagnostics.payload(reset: true)
        let priorGhosttyCensus = try #require(
            prior["ghostty_process_census"] as? [String: Any]
        )
        let priorMetrics = try #require(prior["metrics"] as? [String: Any])
        #expect(priorMetrics["received_frames"] as? UInt64 == 3)
        #expect(priorMetrics["provenance_records"] as? UInt64 == 3)
        #expect(priorMetrics["provenance_dropped_records"] as? UInt64 == 1)
        let priorProvenance = try #require(prior["provenance"] as? [String: Any])
        let priorRecords = try #require(priorProvenance["records"] as? [[String: Any]])
        #expect(priorRecords.compactMap { $0["frame_sequence"] as? UInt64 } == [2, 3])

        let cleared = diagnostics.payload(reset: false)
        let clearedGhosttyCensus = try #require(
            cleared["ghostty_process_census"] as? [String: Any]
        )
        #expect(
            clearedGhosttyCensus["surface_constructor_attempts"] as? UInt64
                == priorGhosttyCensus["surface_constructor_attempts"] as? UInt64
        )
        #expect(
            clearedGhosttyCensus["pty_master_allocations"] as? UInt64
                == priorGhosttyCensus["pty_master_allocations"] as? UInt64
        )
        let clearedMetrics = try #require(cleared["metrics"] as? [String: Any])
        #expect(clearedMetrics["received_frames"] as? UInt64 == 0)
        #expect(clearedMetrics["provenance_records"] as? UInt64 == 0)
    }

    @Test @MainActor
    func remoteTmuxBridgePreservesEarlySeedThenLiveOutputAndPaneState() async throws {
        let service = RecordingExternalTerminalService(suspendResets: true)
        let requests = MainActorCounter()
        var forwardedEgress: [Data] = []
        let surfaceID = SurfaceID(rawValue: UUID())
        let bridge = TerminalBackendRemoteTmuxSurfaceBridge(
            surfaceID: surfaceID,
            service: service,
            sendKeys: {
                forwardedEgress.append($0)
                return true
            },
            requestSeed: { requests.increment() }
        )
        bridge.activate()
        await bridge.waitForIdleForTesting()
        #expect(requests.value == 1)

        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "seed-bridge.test"),
            sessionName: "work"
        )
        let paneID = 17
        let token = connection.addObserver(
            onPaneOutput: { observedPaneID, data in
                guard observedPaneID == paneID else { return }
                bridge.receiveOutput(data)
            },
            onPaneSeed: { observedPaneID, seed in
                guard observedPaneID == paneID else { return }
                bridge.receiveSeed(seed, columns: 160, rows: 48, noReflow: true)
            },
            onPaneSeedFailure: { observedPaneID in
                guard observedPaneID == paneID else { return }
                bridge.seedFailed()
            }
        )
        defer { connection.removeObserver(token) }

        let capture = Data(
            repeating: 0x61,
            count: RemoteTmuxControlConnection.maximumPendingPaneSeedByteCount + 1
        )
        let live = Data("live-after-early-seed".utf8)
        let state = Data("pane-state-after-live".utf8)
        connection.beginPaneSeed(paneId: paneID, clearScrollback: false)
        connection.installPaneSeedCapture(paneId: paneID, data: capture)
        await service.waitForResetCount(1)

        connection.handleMessageForTesting(.output(paneId: paneID, data: live))
        connection.finishPaneSeed(paneId: paneID, state: state)
        await service.releaseResets()
        await bridge.waitForIdleForTesting()

        let resetSeeds = await service.resetSeeds()
        let outputChunks = await service.outputChunks()
        #expect(resetSeeds.count == 1)
        #expect(resetSeeds[0].count == RemoteTmuxPaneSeed.maximumChunkByteCount)
        #expect(outputChunks.allSatisfy {
            !$0.isEmpty && $0.count <= RemoteTmuxPaneSeed.maximumChunkByteCount
        })
        var reconstructed = resetSeeds[0]
        for chunk in outputChunks { reconstructed.append(chunk) }
        #expect(reconstructed == capture + live + state)
        #expect(forwardedEgress.first == Data("reset-egress".utf8))
        #expect(forwardedEgress.count == outputChunks.count + 1)
    }

    @Test @MainActor
    func repeatedSeedFailureFailsWaiterThenRequestsOnceAfterRecovery() async throws {
        let service = RecordingExternalTerminalService()
        let requests = MainActorCounter()
        let recovery = AsyncTestGate()
        let bridge = TerminalBackendRemoteTmuxSurfaceBridge(
            surfaceID: SurfaceID(rawValue: UUID()),
            service: service,
            sendKeys: { _ in true },
            requestSeed: { requests.increment() },
            recoveryHandler: { await recovery.wait() }
        )
        bridge.activate()
        await requests.wait(for: 1)
        bridge.receiveSeed(
            RemoteTmuxPaneSeed(bytes: Data("initial".utf8)),
            columns: 80,
            rows: 24,
            noReflow: true
        )
        try await bridge.waitUntilReadyForTesting()

        bridge.seedFailed()
        await requests.wait(for: 2)
        let waiter = Task { @MainActor in
            do {
                try await bridge.waitUntilReadyForTesting()
                return false
            } catch TerminalBackendRemoteTmuxBridgeError.seedUnavailable {
                return true
            } catch {
                return false
            }
        }
        await Task.yield()
        #expect(bridge.readyWaiterCountForTesting == 1)
        bridge.seedFailed()
        #expect(await waiter.value)
        await recovery.waitUntilEntered()
        #expect(requests.value == 2)

        await recovery.open()
        await requests.wait(for: 3)
        #expect(requests.value == 3)
        bridge.receiveSeed(
            RemoteTmuxPaneSeed(bytes: Data("recovered".utf8)),
            columns: 80,
            rows: 24,
            noReflow: true
        )
        try await bridge.waitUntilReadyForTesting()
    }

    @Test @MainActor
    func remoteDisconnectEndpointRebindRequestsFreshSeedAndReturnsReady() async throws {
        let service = RecordingExternalTerminalService()
        let requests = MainActorCounter()
        let bridge = TerminalBackendRemoteTmuxSurfaceBridge(
            surfaceID: SurfaceID(rawValue: UUID()),
            service: service,
            sendKeys: { _ in true },
            requestSeed: { requests.increment() }
        )
        bridge.activate()
        await requests.wait(for: 1)
        bridge.receiveSeed(
            RemoteTmuxPaneSeed(bytes: Data("before-disconnect".utf8)),
            columns: 80,
            rows: 24,
            noReflow: true
        )
        try await bridge.waitUntilReadyForTesting()

        bridge.remoteConnectionDidDisconnect()
        let waiter = Task { @MainActor in
            try await bridge.waitUntilReadyForTesting()
        }
        await Task.yield()
        #expect(bridge.readyWaiterCountForTesting == 1)
        bridge.updateEndpoints(
            sendKeys: { _ in true },
            requestSeed: { requests.increment() },
            requestSeedIfNeeded: true
        )
        await requests.wait(for: 2)
        #expect(requests.value == 2)
        bridge.receiveSeed(
            RemoteTmuxPaneSeed(bytes: Data("after-reconnect".utf8)),
            columns: 80,
            rows: 24,
            noReflow: false
        )
        try await waiter.value
    }

    @Test @MainActor
    func noReflowChangeDropsInFlightOutputEgressBeforeReplacementSeed() async throws {
        let service = RecordingExternalTerminalService()
        let requests = MainActorCounter()
        var forwardedEgress: [Data] = []
        let bridge = TerminalBackendRemoteTmuxSurfaceBridge(
            surfaceID: SurfaceID(rawValue: UUID()),
            service: service,
            sendKeys: {
                forwardedEgress.append($0)
                return true
            },
            requestSeed: { requests.increment() }
        )
        bridge.activate()
        await requests.wait(for: 1)
        bridge.receiveSeed(
            RemoteTmuxPaneSeed(bytes: Data("original".utf8)),
            columns: 80,
            rows: 24,
            noReflow: true
        )
        try await bridge.waitUntilReadyForTesting()
        let forwardedBeforePolicyChange = forwardedEgress

        await service.setSuspendOutputs(true)
        bridge.receiveOutput(Data("old-cycle-output".utf8))
        await service.waitForOutputCount(1)
        bridge.updateNoReflow(false)
        await requests.wait(for: 2)
        await service.releaseOutputs()
        await bridge.waitForIdleForTesting()
        #expect(forwardedEgress == forwardedBeforePolicyChange)

        bridge.receiveSeed(
            RemoteTmuxPaneSeed(bytes: Data("replacement".utf8)),
            columns: 80,
            rows: 24,
            noReflow: false
        )
        try await bridge.waitUntilReadyForTesting()
    }

    @Test @MainActor
    func retiringBlockedOutputCancelsQueuedMutationAndDropsLateEgress() async throws {
        let service = RecordingExternalTerminalService()
        var forwardedEgress: [Data] = []
        let surfaceID = SurfaceID(rawValue: UUID())
        let bridge = TerminalBackendRemoteTmuxSurfaceBridge(
            surfaceID: surfaceID,
            service: service,
            sendKeys: {
                forwardedEgress.append($0)
                return true
            },
            requestSeed: {}
        )
        bridge.activate()
        await bridge.waitForIdleForTesting()
        bridge.receiveSeed(
            RemoteTmuxPaneSeed(bytes: Data("seed".utf8)),
            columns: 80,
            rows: 24,
            noReflow: true
        )
        try await bridge.waitUntilReadyForTesting()
        let forwardedBeforeBlockedOutput = forwardedEgress

        await service.setSuspendOutputs(true)
        bridge.receiveOutput(Data("blocked".utf8))
        await service.waitForOutputCount(1)
        let client = RecordingPersistentTerminalBackendClient()
        let workspaceID = UUID()
        let binding = TerminalBackendTerminalBinding(
            authority: BackendAuthority(
                daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
                sessionID: SessionID(rawValue: UUID())
            ),
            appWorkspaceID: workspaceID,
            appSurfaceID: surfaceID.rawValue,
            workspaceHandle: 1,
            workspaceID: WorkspaceID(rawValue: workspaceID),
            surfaceHandle: 2,
            surfaceID: surfaceID,
            columns: 80,
            rows: 24,
            created: false
        )
        let viewport = TerminalExternalViewport(
            widthPoints: 640,
            heightPoints: 480,
            widthPixels: 1_280,
            heightPixels: 960,
            xScale: 2,
            yScale: 2,
            proposedColumns: 100,
            proposedRows: 30
        )
        let mutation = Task { @MainActor in
            do {
                _ = try await bridge.apply(
                    .resize(viewport),
                    requestID: UUID(),
                    client: client,
                    binding: binding,
                    presentation: nil
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await Task.yield()
        bridge.retire()
        await service.releaseOutputs()

        #expect(await mutation.value)
        #expect((await client.mutations()).isEmpty)
        #expect(forwardedEgress == forwardedBeforeBlockedOutput)
    }

    private static func makeRenderDiagnosticsFrame(
        sequence: UInt64
    ) throws -> TerminalRenderFrame {
        let daemonID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let terminalID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let presentationID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let metadata = try TerminalRenderFrameMetadata(
            daemonInstanceID: daemonID,
            rendererEpoch: 3,
            terminalID: terminalID,
            terminalEpoch: 5,
            terminalSequence: sequence,
            presentationID: presentationID,
            presentationGeneration: 7,
            frameSequence: sequence,
            width: 2,
            height: 2,
            pixelFormat: .bgra8Unorm,
            colorSpace: .sRGB,
            completionFence: .producerCompleted,
            damageBounds: nil
        )
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: 2,
            kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 8,
            kIOSurfaceAllocSize: 16,
            kIOSurfacePixelFormat: TerminalRenderPixelFormat.bgra8Unorm.rawValue,
        ]
        let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
        return TerminalRenderFrame(
            metadata: metadata,
            surface: TerminalRenderSurfaceHandle(surface: surface),
            workerIdentity: try TerminalRenderWorkerIdentity(
                processID: 42,
                effectiveUserID: 501
            )
        )
    }

    private static func makePresentedFrameFence(
        _ metadata: TerminalRenderFrameMetadata
    ) throws -> TerminalRenderPresentationFence {
        try TerminalRenderPresentationFence(
            daemonInstanceID: metadata.daemonInstanceID,
            rendererEpoch: metadata.rendererEpoch,
            terminalID: metadata.terminalID,
            terminalEpoch: metadata.terminalEpoch,
            minimumTerminalSequence: metadata.terminalSequence,
            presentationID: metadata.presentationID,
            presentationGeneration: metadata.presentationGeneration,
            width: metadata.width,
            height: metadata.height,
            pixelFormat: metadata.pixelFormat,
            colorSpace: metadata.colorSpace,
            completionRequirement: .producerCompleted
        )
    }

    @MainActor
    private func waitForAccessibilityRevision(
        _ revision: UInt64,
        runtime: PersistentTerminalExternalRuntime
    ) async throws {
        for _ in 0 ..< 10_000 {
            if runtime.snapshot.accessibility?.contentRevision == revision { return }
            await Task.yield()
        }
        throw ReconnectSupervisorTestError.timedOut
    }

    @MainActor
    private static func ghosttyMetalLayerCount(in view: NSView) -> Int {
        let ownLayerCount = view.layer is GhosttyMetalLayer ? 1 : 0
        return ownLayerCount + view.subviews.reduce(into: 0) { count, subview in
            count += ghosttyMetalLayerCount(in: subview)
        }
    }
}

@MainActor
private final class MainActorCounter {
    private(set) var value = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func increment() {
        value += 1
        let ready = waiters.filter { $0.target <= value }
        waiters.removeAll { $0.target <= value }
        for waiter in ready { waiter.continuation.resume() }
    }

    func wait(for target: Int) async {
        guard value < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var isEntered = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isEntered = true
        let entered = entryWaiters
        entryWaiters.removeAll(keepingCapacity: false)
        for waiter in entered { waiter.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = gateWaiters
        gateWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

actor RecordingExternalTerminalService: TerminalBackendExternalTerminalServing,
    TerminalBackendRemoteTmuxProducerSourceServing
{
    private let authority: BackendAuthority
    private var suspendResets: Bool
    private var suspendOutputs = false
    private var resetContinuations: [CheckedContinuation<Void, Never>] = []
    private var outputContinuations: [CheckedContinuation<Void, Never>] = []
    private var resetWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var outputWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var claims = 0
    private var recordedResetSeeds: [Data] = []
    private var recordedOutputChunks: [Data] = []
    private var currentOutputGeneration: UInt64 = 0
    private var currentNoReflow = true
    private var producerSources: [UUID: BackendRemoteTmuxProducerSource] = [:]

    init(
        suspendResets: Bool = false,
        authority: BackendAuthority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        ),
        producerSources: [UUID: BackendRemoteTmuxProducerSource] = [:]
    ) {
        self.suspendResets = suspendResets
        self.authority = authority
        self.producerSources = producerSources
    }

    func claimExternalTerminal(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> BackendExternalTerminalClaimReceipt {
        _ = surfaceID
        claims += 1
        return BackendExternalTerminalClaimReceipt(
            requestID: requestID,
            ownerGeneration: 1,
            requiredOutputGeneration: max(currentOutputGeneration + 1, 1),
            replayed: false
        )
    }

    func resetExternalTerminal(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        outputGeneration: UInt64,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool,
        seed: Data
    ) async throws -> BackendExternalTerminalOutputReceipt {
        _ = surfaceID
        _ = columns
        _ = rows
        recordedResetSeeds.append(seed)
        resumeSatisfied(&resetWaiters, count: recordedResetSeeds.count)
        if suspendResets {
            await withCheckedContinuation { resetContinuations.append($0) }
        }
        currentOutputGeneration = outputGeneration
        currentNoReflow = noReflow
        return BackendExternalTerminalOutputReceipt(
            requestID: requestID,
            ownerGeneration: ownerGeneration,
            outputGeneration: outputGeneration,
            acceptedSequence: 0,
            nextSequence: 1,
            noReflow: noReflow,
            egress: Data("reset-egress".utf8),
            replayed: false
        )
    }

    func sendExternalTerminalOutput(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        outputGeneration: UInt64,
        sequence: UInt64,
        data: Data
    ) async throws -> BackendExternalTerminalOutputReceipt {
        _ = surfaceID
        recordedOutputChunks.append(data)
        resumeSatisfied(&outputWaiters, count: recordedOutputChunks.count)
        if suspendOutputs {
            await withCheckedContinuation { outputContinuations.append($0) }
        }
        return BackendExternalTerminalOutputReceipt(
            requestID: requestID,
            ownerGeneration: ownerGeneration,
            outputGeneration: outputGeneration,
            acceptedSequence: sequence,
            nextSequence: sequence + 1,
            noReflow: currentNoReflow,
            egress: Data("output-egress-\(sequence)".utf8),
            replayed: false
        )
    }

    func drainExternalTerminalEgress(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64
    ) async throws -> Data {
        _ = surfaceID
        _ = ownerGeneration
        return Data("drain-egress".utf8)
    }

    func claimRemoteTmuxProducerSource(
        producerID: UUID,
        requestID: UUID,
        source: BackendRemoteTmuxProducerSource?
    ) async throws -> BackendRemoteTmuxProducerSourceClaimReceipt {
        if let source { producerSources[producerID] = source }
        return BackendRemoteTmuxProducerSourceClaimReceipt(
            requestID: requestID,
            daemonInstanceID: authority.daemonInstanceID,
            sessionID: authority.sessionID,
            producerID: producerID,
            ownerGeneration: 1,
            source: producerSources[producerID],
            replayed: false
        )
    }

    func updateRemoteTmuxProducerSource(
        producerID: UUID,
        ownerGeneration: UInt64,
        requestID: UUID,
        source: BackendRemoteTmuxProducerSource
    ) async throws -> BackendRemoteTmuxProducerSourceUpdateReceipt {
        producerSources[producerID] = source
        return BackendRemoteTmuxProducerSourceUpdateReceipt(
            requestID: requestID,
            daemonInstanceID: authority.daemonInstanceID,
            sessionID: authority.sessionID,
            producerID: producerID,
            ownerGeneration: ownerGeneration,
            replayed: false
        )
    }

    func setSuspendOutputs(_ value: Bool) {
        suspendOutputs = value
    }

    func releaseResets() {
        suspendResets = false
        let continuations = resetContinuations
        resetContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume() }
    }

    func releaseOutputs() {
        suspendOutputs = false
        let continuations = outputContinuations
        outputContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume() }
    }

    func waitForResetCount(_ count: Int) async {
        guard recordedResetSeeds.count < count else { return }
        await withCheckedContinuation { resetWaiters.append((count, $0)) }
    }

    func waitForOutputCount(_ count: Int) async {
        guard recordedOutputChunks.count < count else { return }
        await withCheckedContinuation { outputWaiters.append((count, $0)) }
    }

    func resetSeeds() -> [Data] { recordedResetSeeds }
    func outputChunks() -> [Data] { recordedOutputChunks }

    private func resumeSatisfied(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        let satisfied = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        for waiter in satisfied { waiter.1.resume() }
    }
}

private enum ReconnectSupervisorTestError: Error {
    case timedOut
    case streamEnded
}

private func withReconnectTestTimeout<Value: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await ContinuousClock().sleep(for: duration)
            throw ReconnectSupervisorTestError.timedOut
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw ReconnectSupervisorTestError.streamEnded
        }
        return value
    }
}

private actor ScriptedBackendReadiness {
    private let results: [BackendServiceBootstrapResult]
    private var nextIndex = 0

    init(results: [BackendServiceBootstrapResult]) {
        self.results = results
    }

    func next() -> BackendServiceBootstrapResult {
        let result = nextIndex < results.count ? results[nextIndex] : .backendUnavailable
        nextIndex += 1
        return result
    }

    func requestCount() -> Int { nextIndex }
}

private actor BackendSessionLifecycleRecorder {
    private var active: Set<String> = []
    private var recordedMaximumActiveCount = 0

    func opened(_ identifier: String) {
        active.insert(identifier)
        recordedMaximumActiveCount = max(recordedMaximumActiveCount, active.count)
    }

    func closed(_ identifier: String) {
        active.remove(identifier)
    }

    func activeIdentifiers() -> [String] {
        active.sorted()
    }

    func maximumActiveCount() -> Int {
        recordedMaximumActiveCount
    }
}

private actor BackendCompatibilityReporterRecorder {
    private var reports: [BackendCompatibilityResult?] = []

    func record(_ compatibility: BackendCompatibilityResult?) {
        reports.append(compatibility)
    }

    func count() -> Int { reports.count }

    func recorded() -> [BackendCompatibilityResult?] { reports }
}

private actor OverflowingBackendSession: TerminalBackendSessionServing {
    private let identifier: String
    private let snapshot: TopologySnapshot?
    private let initialEvents: [BackendCanonicalSessionEvent]?
    private let compatibility: BackendCompatibilityResult
    private let lifecycle: BackendSessionLifecycleRecorder
    private var stableContinuation: AsyncStream<BackendCanonicalSessionEvent>.Continuation?
    private var recordedEventSubscriptionCount = 0
    private var recordedConnectCount = 0
    private var recordedCloseCount = 0
    private var isOpen = false

    init(
        identifier: String,
        snapshot: TopologySnapshot?,
        initialEvents: [BackendCanonicalSessionEvent]?,
        compatibility: BackendCompatibilityResult = .readWrite(BackendReadWriteCompatibility(
            clientProtocolRange: 9 ... 9,
            serverProtocolRange: 9 ... 9,
            negotiatedProtocol: 9,
            requiredCapabilities: []
        )),
        lifecycle: BackendSessionLifecycleRecorder
    ) {
        self.identifier = identifier
        self.snapshot = snapshot
        self.initialEvents = initialEvents
        self.compatibility = compatibility
        self.lifecycle = lifecycle
    }

    func events() -> AsyncStream<BackendCanonicalSessionEvent> {
        recordedEventSubscriptionCount += 1
        let pair = AsyncStream<BackendCanonicalSessionEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(256)
        )
        if let initialEvents {
            eventLoop: for event in initialEvents {
                switch pair.continuation.yield(event) {
                case .enqueued:
                    continue
                case .dropped, .terminated:
                    pair.continuation.finish()
                    break eventLoop
                @unknown default:
                    pair.continuation.finish()
                    break eventLoop
                }
            }
        } else {
            stableContinuation = pair.continuation
        }
        return pair.stream
    }

    func backendCompatibility() async throws -> BackendCompatibilityResult {
        compatibility
    }

    func disconnectEventStream() {
        stableContinuation?.yield(.disconnected(.topologyStreamFailed("test disconnect")))
        stableContinuation?.finish()
        stableContinuation = nil
    }

    func eventSubscriptionCount() -> Int { recordedEventSubscriptionCount }

    func connect() async throws -> TopologySnapshot? {
        recordedConnectCount += 1
        isOpen = true
        await lifecycle.opened(identifier)
        return snapshot
    }

    func close() async {
        recordedCloseCount += 1
        stableContinuation?.finish()
        stableContinuation = nil
        guard isOpen else { return }
        isOpen = false
        await lifecycle.closed(identifier)
    }

    func connectCount() -> Int { recordedConnectCount }

    func closeCount() -> Int { recordedCloseCount }

    func ensureTerminal(
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        workingDirectory: String?,
        command: String?,
        arguments: [String]?,
        environment: [String: String],
        initialInput: String?,
        waitAfterCommand: Bool,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendEnsuredTerminalPlacement {
        throw BackendProtocolError.notConnected
    }

    func reparentTerminal(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID
    ) async throws -> BackendReparentedTerminalPlacement {
        throw BackendProtocolError.notConnected
    }

    func openPresentation(
        view: BackendPresentationView,
        zoom: BackendPresentationZoom,
        scroll: BackendPresentationScroll
    ) async throws -> BackendPresentation {
        throw BackendProtocolError.notConnected
    }

    func closePresentation(id: PresentationID) async throws {
        throw BackendProtocolError.notConnected
    }

    func configureRendererPresentation(
        id: PresentationID,
        expectedGeneration: UInt64,
        configuration: BackendRendererPresentationConfiguration
    ) async throws -> BackendRendererPresentationReceipt {
        throw BackendProtocolError.notConnected
    }

    func detachRendererPresentation(
        id: PresentationID,
        expectedGeneration: UInt64
    ) async throws {
        throw BackendProtocolError.notConnected
    }

    func setTerminalPreedit(
        presentationID: PresentationID,
        rendererGeneration: UInt64,
        text: String?
    ) async throws {
        throw BackendProtocolError.notConnected
    }

    func releaseRendererFrame(
        _ release: BackendRendererFrameRelease
    ) async throws -> BackendRendererFrameReleaseResponse {
        throw BackendProtocolError.notConnected
    }

    func rendererWorkers() async throws -> BackendRendererWorkersResponse {
        throw BackendProtocolError.notConnected
    }

    func claimProjectionState(
        logicalPresentationID: UUID
    ) async throws -> BackendProjectionState {
        throw BackendProtocolError.notConnected
    }

    func updateProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64,
        workspaces: [BackendProjectionWorkspaceState]
    ) async throws -> BackendProjectionState {
        throw BackendProtocolError.notConnected
    }

    func updateProjectionStates(
        _ projections: [BackendProjectionStateUpdate]
    ) async throws -> [BackendProjectionState] {
        throw BackendProtocolError.notConnected
    }

    func releaseProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64
    ) async throws {
        throw BackendProtocolError.notConnected
    }

    func listProjectionStates() async throws -> [BackendProjectionState] {
        throw BackendProtocolError.notConnected
    }

    func terminalControlProtocol() async throws -> BackendTerminalControlProtocol {
        .leasedV9
    }

    func acquireTerminalControl(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        ttlMilliseconds: UInt64
    ) async throws -> BackendTerminalControlLease {
        throw BackendProtocolError.notConnected
    }

    func releaseTerminalControl(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64
    ) async throws {
        throw BackendProtocolError.notConnected
    }

    func sendTerminalInput(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        requestID: UUID,
        input: BackendTerminalControlInput
    ) async throws -> BackendTerminalOperationReceipt {
        throw BackendProtocolError.notConnected
    }

    func sendTerminalGeometry(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        requestID: UUID,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendTerminalOperationReceipt {
        throw BackendProtocolError.notConnected
    }

    func sendTerminalKey(
        surface: UInt64,
        event: BackendTerminalKeyEvent
    ) async throws -> BackendTerminalKeyResponse {
        throw BackendProtocolError.notConnected
    }

    func sendTerminalNamedKey(surface: UInt64, key: String) async throws {
        throw BackendProtocolError.notConnected
    }

    func sendTerminalMouse(
        surface: UInt64,
        event: BackendTerminalMouseEvent
    ) async throws -> BackendTerminalMouseResponse {
        throw BackendProtocolError.notConnected
    }

    func sendTerminalText(surface: UInt64, text: String, paste: Bool) async throws {
        throw BackendProtocolError.notConnected
    }

    func terminalState(
        surfaceID: SurfaceID
    ) async throws -> BackendTerminalStateResponse {
        throw BackendProtocolError.notConnected
    }

    func performTerminalBindingAction(
        surfaceID: SurfaceID,
        action: String,
        repeatCount: UInt32?
    ) async throws -> BackendTerminalActionResponse {
        throw BackendProtocolError.notConnected
    }

    func terminalSelection(
        surfaceID: SurfaceID,
        operation: BackendTerminalSelectionOperation
    ) async throws -> BackendTerminalSelectionResponse {
        throw BackendProtocolError.notConnected
    }

    func terminalCopyMode(
        surfaceID: SurfaceID,
        operation: BackendTerminalCopyModeOperation,
        adjustment: BackendTerminalCopyModeAdjustment?,
        count: UInt32?
    ) async throws -> BackendTerminalActionResponse {
        throw BackendProtocolError.notConnected
    }

    func terminalSearch(
        surfaceID: SurfaceID,
        operation: BackendTerminalSearchOperation,
        query: String?
    ) async throws -> BackendTerminalActionResponse {
        throw BackendProtocolError.notConnected
    }

    func terminalScroll(
        surfaceID: SurfaceID,
        operation: BackendTerminalScrollOperation,
        amount: Int64?
    ) async throws -> BackendTerminalActionResponse {
        throw BackendProtocolError.notConnected
    }

    func resizeTerminal(
        surface: UInt64,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendSurfaceResizeResponse {
        throw BackendProtocolError.notConnected
    }

    func readTerminalScreen(surface: UInt64) async throws -> BackendScreenText {
        throw BackendProtocolError.notConnected
    }

    func terminalProcessInfo(surface: UInt64) async throws -> BackendProcessInfo {
        throw BackendProtocolError.notConnected
    }

    func closeTerminal(surface: UInt64) async throws {
        throw BackendProtocolError.notConnected
    }
}

private extension TerminalBackendTerminalRequest {
    var authorityForTesting: BackendAuthority {
        BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID(uuid: (
                0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x4A, 0xAA,
                0x8A, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA
            ))),
            sessionID: SessionID(rawValue: UUID(uuid: (
                0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x4B, 0xBB,
                0x8B, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB
            )))
        )
    }
}

private struct RecordedPersistentTerminalMutation: Equatable, Sendable {
    let mutation: TerminalExternalRuntimeMutation
    let requestID: UUID
    let bindingWorkspaceID: UUID
    let presentation: TerminalBackendPresentationDescriptor?
}

private actor SuspendedTerminalLaunchResolver {
    private var recordedRequests: [TerminalSurfaceLaunchRequest] = []
    private var continuations: [
        Int: CheckedContinuation<TerminalSurfaceResolvedLaunch, Never>
    ] = [:]
    private var requestWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func resolve(
        _ request: TerminalSurfaceLaunchRequest
    ) async -> TerminalSurfaceResolvedLaunch {
        let index = recordedRequests.count
        recordedRequests.append(request)
        resumeSatisfiedWaiters(&requestWaiters, count: recordedRequests.count)
        return await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard recordedRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters[count, default: []].append(continuation)
        }
    }

    func resume(at index: Int) {
        guard recordedRequests.indices.contains(index),
              let continuation = continuations.removeValue(forKey: index) else { return }
        continuation.resume(returning: Self.resolvedLaunch(for: recordedRequests[index]))
    }

    func resumeAll() {
        for index in continuations.keys.sorted() {
            resume(at: index)
        }
    }

    func requests() -> [TerminalSurfaceLaunchRequest] { recordedRequests }

    private static func resolvedLaunch(
        for request: TerminalSurfaceLaunchRequest
    ) -> TerminalSurfaceResolvedLaunch {
        TerminalSurfaceResolvedLaunch(
            workingDirectory: request.workingDirectory,
            command: request.initialCommand,
            arguments: request.initialCommand == nil ? ["/bin/zsh", "-l"] : nil,
            environment: ["CMUX_WORKSPACE_ID": request.workspaceID.uuidString],
            initialInput: request.initialInput,
            waitAfterCommand: request.configTemplate?.waitAfterCommand ?? false
        )
    }

    private func resumeSatisfiedWaiters(
        _ waiters: inout [Int: [CheckedContinuation<Void, Never>]],
        count: Int
    ) {
        let satisfied = waiters.keys.filter { $0 <= count }
        for key in satisfied {
            waiters.removeValue(forKey: key)?.forEach { $0.resume() }
        }
    }
}

private actor AccessibilityRuntimeBackendClient: TerminalBackendClient {
    private let stableAuthority = BackendAuthority(
        daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
        sessionID: SessionID(rawValue: UUID())
    )
    private var revision: UInt64 = 1
    private var recordedHyperlinkContentSequences: [UInt64] = []

    func authority() -> BackendAuthority { stableAuthority }

    func setRevision(_ revision: UInt64) {
        self.revision = revision
    }

    func hyperlinkContentSequences() -> [UInt64] {
        recordedHyperlinkContentSequences
    }

    func rendererEvents() async -> AsyncStream<TerminalBackendRendererEvent> {
        AsyncStream { _ in }
    }

    func canonicalSnapshots() async throws -> AsyncStream<TopologySnapshot> {
        AsyncStream { $0.finish() }
    }

    func ensureTerminal(
        _ request: TerminalBackendTerminalRequest
    ) async throws -> TerminalBackendTerminalBinding {
        TerminalBackendTerminalBinding(
            authority: stableAuthority,
            appWorkspaceID: request.appWorkspaceID,
            appSurfaceID: request.appSurfaceID,
            workspaceHandle: 1,
            workspaceID: WorkspaceID(rawValue: request.appWorkspaceID),
            surfaceHandle: 2,
            surfaceID: SurfaceID(rawValue: request.appSurfaceID),
            columns: request.columns,
            rows: request.rows,
            created: revision == 1
        )
    }

    func apply(
        _ mutation: TerminalExternalRuntimeMutation,
        requestID: UUID,
        to binding: TerminalBackendTerminalBinding,
        presentation: TerminalBackendPresentationDescriptor?
    ) async throws -> TerminalBackendMutationOutcome {
        _ = mutation
        _ = requestID
        _ = binding
        _ = presentation
        return TerminalBackendMutationOutcome()
    }

    func readScreenText(
        _ request: TerminalExternalScreenTextRequest,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> String? {
        _ = request
        _ = binding
        return nil
    }

    func readSelection(
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalExternalSelection? {
        _ = binding
        return nil
    }

    func readTerminalUXState(
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalBackendMutationOutcome {
        _ = binding
        return TerminalBackendMutationOutcome()
    }

    func readAccessibilitySnapshot(
        presentationID: UUID,
        expectedContentSequence: UInt64,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalAccessibilitySnapshot {
        let value = "r\(revision)"
        return TerminalAccessibilitySnapshot(
            schemaVersion: 1,
            surfaceID: binding.appSurfaceID,
            presentationID: presentationID,
            presentationGeneration: 1,
            contentSequence: expectedContentSequence,
            terminalRevision: revision,
            contentRevision: revision,
            viewportRevision: 1,
            viewportOffset: 0,
            columns: 2,
            rows: 1,
            text: value,
            lines: [TerminalAccessibilityLine(
                row: 0,
                utf16Range: TerminalAccessibilityRange(location: 0, length: 2),
                cells: [
                    TerminalAccessibilityCell(
                        column: 0,
                        columnSpan: 1,
                        utf16Range: TerminalAccessibilityRange(location: 0, length: 1)
                    ),
                    TerminalAccessibilityCell(
                        column: 1,
                        columnSpan: 1,
                        utf16Range: TerminalAccessibilityRange(location: 1, length: 1)
                    ),
                ]
            )],
            cursor: TerminalAccessibilityCursor(
                column: 1,
                row: 0,
                insertionRange: TerminalAccessibilityRange(location: 1, length: 0),
                line: 0
            ),
            selections: [],
            links: [],
            focused: revision >= 2
        )
    }

    func activateHyperlink(
        at event: TerminalExternalMouseEvent,
        contentSequence: UInt64,
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalExternalHyperlinkHit {
        _ = event
        _ = presentationID
        _ = binding
        recordedHyperlinkContentSequences.append(contentSequence)
        return TerminalExternalHyperlinkHit(
            target: "https://example.com/",
            contentSequence: contentSequence,
            presentationGeneration: 7,
            column: 1,
            row: 0
        )
    }

    func detachPresentation(
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding?
    ) async {
        _ = presentationID
        _ = binding
    }

    func releaseFrame(_ release: TerminalRenderFrameRelease) async {
        _ = release
    }
}

private actor RecordingPersistentTerminalBackendClient: TerminalBackendClient {
    private let suspendEnsures: Bool
    private let suspendUXReads: Bool
    private let failFirstMutation: Bool
    private var didFailMutation = false
    private var requests: [TerminalBackendTerminalRequest] = []
    private var recordedMutations: [RecordedPersistentTerminalMutation] = []
    private var rendererContinuations: [
        UUID: AsyncStream<TerminalBackendRendererEvent>.Continuation
    ] = [:]
    private var ensureWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var mutationWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var rendererSubscriberWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var uxReadWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var detachWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var ensureContinuations: [
        Int: CheckedContinuation<TerminalBackendTerminalBinding, Never>
    ] = [:]
    private var uxReadContinuations: [
        Int: CheckedContinuation<TerminalBackendMutationOutcome, Never>
    ] = [:]
    private var uxReadWorkspaces: [UUID] = []
    private var detachedBindingWorkspaces: [UUID?] = []

    init(
        suspendEnsures: Bool = false,
        suspendUXReads: Bool = false,
        failFirstMutation: Bool = false
    ) {
        self.suspendEnsures = suspendEnsures
        self.suspendUXReads = suspendUXReads
        self.failFirstMutation = failFirstMutation
    }

    func rendererEvents() async -> AsyncStream<TerminalBackendRendererEvent> {
        let identifier = UUID()
        let pair = AsyncStream<TerminalBackendRendererEvent>.makeStream()
        rendererContinuations[identifier] = pair.continuation
        resumeSatisfiedWaiters(
            &rendererSubscriberWaiters,
            count: rendererContinuations.count
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRendererContinuation(identifier) }
        }
        return pair.stream
    }

    func canonicalSnapshots() async throws -> AsyncStream<TopologySnapshot> {
        AsyncStream { _ in }
    }

    func ensureTerminal(
        _ request: TerminalBackendTerminalRequest
    ) async throws -> TerminalBackendTerminalBinding {
        let index = requests.count
        requests.append(request)
        resumeSatisfiedWaiters(&ensureWaiters, count: requests.count)
        guard suspendEnsures else {
            return binding(for: request, ordinal: index + 1)
        }
        return await withCheckedContinuation { continuation in
            ensureContinuations[index] = continuation
        }
    }

    func apply(
        _ mutation: TerminalExternalRuntimeMutation,
        requestID: UUID,
        to binding: TerminalBackendTerminalBinding,
        presentation: TerminalBackendPresentationDescriptor?
    ) async throws -> TerminalBackendMutationOutcome {
        recordedMutations.append(RecordedPersistentTerminalMutation(
            mutation: mutation,
            requestID: requestID,
            bindingWorkspaceID: binding.appWorkspaceID,
            presentation: presentation
        ))
        resumeSatisfiedWaiters(&mutationWaiters, count: recordedMutations.count)
        if failFirstMutation, !didFailMutation {
            didFailMutation = true
            throw BackendProtocolError.connectionClosed
        }
        var outcome = TerminalBackendMutationOutcome()
        if case .reparent(let workspaceID) = mutation {
            outcome.binding = TerminalBackendTerminalBinding(
                authority: binding.authority,
                appWorkspaceID: workspaceID,
                appSurfaceID: binding.appSurfaceID,
                workspaceHandle: binding.workspaceHandle + 1,
                workspaceID: WorkspaceID(rawValue: workspaceID),
                surfaceHandle: binding.surfaceHandle,
                surfaceID: binding.surfaceID,
                columns: binding.columns,
                rows: binding.rows,
                created: false
            )
        }
        return outcome
    }

    func readScreenText(
        _ request: TerminalExternalScreenTextRequest,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> String? {
        nil
    }

    func readSelection(
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalExternalSelection? {
        nil
    }

    func readTerminalUXState(
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalBackendMutationOutcome {
        let index = uxReadWorkspaces.count
        uxReadWorkspaces.append(binding.appWorkspaceID)
        resumeSatisfiedWaiters(&uxReadWaiters, count: uxReadWorkspaces.count)
        guard suspendUXReads else { return TerminalBackendMutationOutcome() }
        return await withCheckedContinuation { continuation in
            uxReadContinuations[index] = continuation
        }
    }

    func detachPresentation(
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding?
    ) async {
        detachedBindingWorkspaces.append(binding?.appWorkspaceID)
        resumeSatisfiedWaiters(
            &detachWaiters,
            count: detachedBindingWorkspaces.count
        )
    }

    func releaseFrame(_ release: TerminalRenderFrameRelease) async {}

    func waitForEnsureCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            ensureWaiters[count, default: []].append(continuation)
        }
    }

    func waitForMutationCount(_ count: Int) async {
        guard recordedMutations.count < count else { return }
        await withCheckedContinuation { continuation in
            mutationWaiters[count, default: []].append(continuation)
        }
    }

    func waitForRendererSubscriberCount(_ count: Int) async {
        guard rendererContinuations.count < count else { return }
        await withCheckedContinuation { continuation in
            rendererSubscriberWaiters[count, default: []].append(continuation)
        }
    }

    func waitForUXReadCount(_ count: Int) async {
        guard uxReadWorkspaces.count < count else { return }
        await withCheckedContinuation { continuation in
            uxReadWaiters[count, default: []].append(continuation)
        }
    }

    func waitForDetachCount(_ count: Int) async {
        guard detachedBindingWorkspaces.count < count else { return }
        await withCheckedContinuation { continuation in
            detachWaiters[count, default: []].append(continuation)
        }
    }

    func resumeEnsure(at index: Int) {
        guard requests.indices.contains(index),
              let continuation = ensureContinuations.removeValue(forKey: index) else { return }
        continuation.resume(returning: binding(for: requests[index], ordinal: index + 1))
    }

    func resumeAllEnsures() {
        for index in ensureContinuations.keys.sorted() {
            resumeEnsure(at: index)
        }
    }

    func resumeUXRead(at index: Int) {
        uxReadContinuations.removeValue(forKey: index)?.resume(
            returning: TerminalBackendMutationOutcome()
        )
    }

    func resumeAllUXReads() {
        for index in uxReadContinuations.keys.sorted() {
            resumeUXRead(at: index)
        }
    }

    func ensureRequests() -> [TerminalBackendTerminalRequest] { requests }

    func mutations() -> [RecordedPersistentTerminalMutation] { recordedMutations }

    func lastMutation() -> RecordedPersistentTerminalMutation? { recordedMutations.last }

    func detachedPresentationCount() -> Int { detachedBindingWorkspaces.count }

    func detachedBindingWorkspaceIDs() -> [UUID?] { detachedBindingWorkspaces }

    func uxReadWorkspaceIDs() -> [UUID] { uxReadWorkspaces }

    func publish(_ event: TerminalBackendRendererEvent) {
        for continuation in rendererContinuations.values {
            continuation.yield(event)
        }
    }

    private func binding(
        for request: TerminalBackendTerminalRequest,
        ordinal: Int
    ) -> TerminalBackendTerminalBinding {
        TerminalBackendTerminalBinding(
            authority: request.authorityForTesting,
            appWorkspaceID: request.appWorkspaceID,
            appSurfaceID: request.appSurfaceID,
            workspaceHandle: UInt64(ordinal),
            workspaceID: WorkspaceID(rawValue: request.appWorkspaceID),
            surfaceHandle: UInt64(ordinal + 1_000),
            surfaceID: SurfaceID(rawValue: request.appSurfaceID),
            columns: request.columns,
            rows: request.rows,
            created: true
        )
    }

    private func removeRendererContinuation(_ identifier: UUID) {
        rendererContinuations.removeValue(forKey: identifier)
    }

    private func resumeSatisfiedWaiters(
        _ waiters: inout [Int: [CheckedContinuation<Void, Never>]],
        count: Int
    ) {
        let satisfied = waiters.keys.filter { $0 <= count }
        for key in satisfied {
            waiters.removeValue(forKey: key)?.forEach { $0.resume() }
        }
    }
}

@MainActor
private final class RecordingTerminalPanelFactory: TerminalPanelCreating {
    private let base = EmbeddedTerminalPanelFactory(
        dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
    )

    private(set) var requests: [TerminalPanelCreationRequest] = []

    func makeTerminalPanel(_ request: TerminalPanelCreationRequest) -> TerminalPanel {
        requests.append(request)
        return base.makeTerminalPanel(request)
    }

    func removeAllRequests() {
        requests.removeAll()
    }
}
