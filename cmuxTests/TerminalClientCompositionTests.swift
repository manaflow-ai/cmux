import AppKit
import CmuxTerminal
import CmuxTerminalBackend
import CmuxTerminalBackendService
import CmuxTerminalRenderProtocol
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal client composition", .serialized)
struct TerminalClientCompositionTests {
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
        let panel = workspace.makeRemoteTmuxPanePanel(onInput: { _ in })
        defer { panel.close() }

        let request = try #require(recorder.requests.last)
        #expect(request.origin == .remoteTmuxMirror)
        #expect(request.manualIO)
        #expect(request.workspaceId == workspace.id)
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
        let workspaceID = UUID()
        let surfaceID = UUID()
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
            presentationRegistry: registry
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

        let targetWorkspaceID = UUID()
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
            mutation: .focus(true)
        )
        let second = TerminalBackendQueuedMutation(
            sequence: 8,
            mutation: .visibility(false)
        )
        var queue = TerminalBackendMutationQueue(capacity: 2)

        #expect(queue.append(first))
        #expect(queue.append(second))
        #expect(!queue.append(TerminalBackendQueuedMutation(
            sequence: 9,
            mutation: .closeCanonicalTerminal
        )))
        #expect(queue.popFirst() == first)
        #expect(queue.popFirst() == second)
        #expect(queue.popFirst() == nil)
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
        let factory = PersistentTerminalPanelFactory(
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies,
            backendClient: client,
            launchResolver: makeLaunchResolver(),
            presentationRegistry: TerminalBackendPresentationRegistry(),
            renderConfigSource: TerminalBackendRenderConfigSource {
                Data("font-family = Menlo\n".utf8)
            }
        )

        let quitPanel = factory.makeTerminalPanel(TerminalPanelCreationRequest(
            origin: .workspaceInitial,
            workspaceId: UUID()
        ))
        await client.waitForEnsureCount(1)
        #expect(AppDelegate.detachPersistentTerminalPresentationsForAppTermination([
            quitPanel.surface
        ]) == 1)
        quitPanel.close()
        await Task.yield()
        let mutationsAfterQuit = await client.mutations()
        #expect(!mutationsAfterQuit.contains { $0.mutation == .closeCanonicalTerminal })

        let explicitlyClosedPanel = factory.makeTerminalPanel(TerminalPanelCreationRequest(
            origin: .workspaceTab,
            workspaceId: UUID()
        ))
        await client.waitForEnsureCount(2)
        explicitlyClosedPanel.close()
        await client.waitForMutationCount(1)
        let mutationsAfterClose = await client.mutations()
        #expect(mutationsAfterClose.filter { $0.mutation == .closeCanonicalTerminal }.count == 1)
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
    let presentation: TerminalBackendPresentationDescriptor?
}

private actor RecordingPersistentTerminalBackendClient: TerminalBackendClient {
    private var requests: [TerminalBackendTerminalRequest] = []
    private var recordedMutations: [RecordedPersistentTerminalMutation] = []
    private var rendererContinuations: [
        UUID: AsyncStream<TerminalBackendRendererEvent>.Continuation
    ] = [:]
    private var ensureWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var mutationWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var rendererSubscriberWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var detachCount = 0

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

    func canonicalSnapshots() async -> AsyncStream<TopologySnapshot> {
        AsyncStream { _ in }
    }

    func ensureTerminal(
        _ request: TerminalBackendTerminalRequest
    ) async throws -> TerminalBackendTerminalBinding {
        requests.append(request)
        resumeSatisfiedWaiters(&ensureWaiters, count: requests.count)
        return binding(for: request)
    }

    func apply(
        _ mutation: TerminalExternalRuntimeMutation,
        to binding: TerminalBackendTerminalBinding,
        presentation: TerminalBackendPresentationDescriptor?
    ) async throws -> TerminalBackendMutationOutcome {
        recordedMutations.append(RecordedPersistentTerminalMutation(
            mutation: mutation,
            presentation: presentation
        ))
        resumeSatisfiedWaiters(&mutationWaiters, count: recordedMutations.count)
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
        TerminalBackendMutationOutcome()
    }

    func detachPresentation(
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding?
    ) async {
        detachCount += 1
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

    func ensureRequests() -> [TerminalBackendTerminalRequest] { requests }

    func mutations() -> [RecordedPersistentTerminalMutation] { recordedMutations }

    func lastMutation() -> RecordedPersistentTerminalMutation? { recordedMutations.last }

    func detachedPresentationCount() -> Int { detachCount }

    func publish(_ event: TerminalBackendRendererEvent) {
        for continuation in rendererContinuations.values {
            continuation.yield(event)
        }
    }

    private func binding(
        for request: TerminalBackendTerminalRequest
    ) -> TerminalBackendTerminalBinding {
        TerminalBackendTerminalBinding(
            authority: request.authorityForTesting,
            appWorkspaceID: request.appWorkspaceID,
            appSurfaceID: request.appSurfaceID,
            workspaceHandle: UInt64(requests.count),
            workspaceID: WorkspaceID(rawValue: request.appWorkspaceID),
            surfaceHandle: UInt64(requests.count + 1_000),
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
