import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxAuthRuntime
import CmuxCloudTui
import CmuxPanes
import CmuxSurfaceCatalogModel
import Testing
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cmd+T / Cmd+D in a pane that projects a cloud terminal create the machine's new
/// terminal through ``SurfacePaneFactory`` (`Workspace+CloudPaneRouting`). The factory
/// drives the socket `surface.create` / `surface.split` handlers, which honor a focus
/// request only inside a focus-allowed socket command. An in-app gesture runs with no
/// socket command active, so without the factory setting that policy itself the new tab
/// appears behind the current one and Cmd+T looks like it did nothing.
@MainActor
@Suite(.serialized) struct SurfacePaneFactoryFocusTests {
    @Test(arguments: ["right", "down"])
    func routedCloudSplitIsAcceptedBeforeItsPanelExists(directionName: String) async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let panelID = try #require(workspace.focusedPanelId)
        let manager = try #require(harness.appDelegate.tabManagerFor(windowId: harness.windowId))
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == "cmux.main.\(harness.windowId.uuidString)" })
        let machine = SurfaceMachineID.cloud("split-action-\(UUID().uuidString)")
        let provider = CloudCreationProvider(machine: machine, workingDirectory: nil, creationError: CloudDiagnosticFailure.network)
        let catalog = SurfaceCatalog.shared
        catalog.register(provider)
        defer { catalog.unregister(machine: machine) }
        let remote = SurfaceRemoteWorkspace(id: "ws-source", name: "source", index: 0, focused: true)
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term-source"),
            title: "shell", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: remote, remoteViews: [SurfaceRemoteView(tabID: "tab-source", workspace: remote)],
            port: nil, url: nil
        )
        catalog.upsert(resource, from: provider)
        catalog.record(SurfaceProjection(
            resource: resource.id, workspaceID: workspace.id, panelID: panelID,
            remoteWorkspaceID: remote.id, remoteTabID: "tab-source"
        ))
        let direction: SplitDirection = directionName == "right" ? .right : .down

        let accepted = harness.appDelegate.performSplitShortcut(direction: direction, preferredWindow: window)
        // Menu and palette callers use this fallback when the shared action says it failed.
        if !accepted { _ = manager.createSplit(direction: direction) }
        await provider.creationAttemptSignal.wait()
        let pendingPanelID = try #require(workspace.cloudPendingCreations.keys.first)
        _ = try await waitForPaneFailure(workspace, panelID: pendingPanelID)

        #expect(accepted)
        #expect(provider.creationRequestCount == 1)
    }

    @Test func focusedTabIsSelectedOutsideASocketCommand() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)
        #expect(TerminalController.currentSocketCommandFocusAllowanceStack().isEmpty)

        let created = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: nil,
            workingDirectory: nil,
            at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
            focus: true
        )

        #expect(created.workspaceID == workspace.id)
        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == created.panelID)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == created.panelID)
    }

    @Test("Cloud shortcut inheritance uses the live remote foreground cwd")
    func cloudShortcutInheritanceUsesLiveRemoteForegroundCwd() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let machine = SurfaceMachineID.cloud("cwd-\(UUID().uuidString)")
        let provider = CloudCreationProvider(machine: machine, workingDirectory: "/remote/project-a")
        let catalog = SurfaceCatalog.shared
        catalog.register(provider)
        defer { catalog.unregister(machine: machine) }

        let remoteWorkspace = SurfaceRemoteWorkspace(id: "ws-project", name: "project", index: 0, focused: true)
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term-source"),
            title: "shell",
            // The public snapshot cwd is the spawn directory. The provider's live
            // process query below is deliberately different.
            detail: "/remote/home",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: remoteWorkspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab-source", workspace: remoteWorkspace)],
            port: nil,
            url: nil
        )
        catalog.upsert(resource, from: provider)
        catalog.record(SurfaceProjection(
            resource: resource.id,
            workspaceID: workspace.id,
            panelID: sourcePanelID,
            remoteWorkspaceID: remoteWorkspace.id,
            remoteTabID: "tab-source"
        ))

        #expect(workspace.routeCloudPaneTerminalTab(inPane: paneID, focus: false))
        for _ in 0..<20 where provider.createdWorkingDirectory == nil {
            await Task.yield()
        }
        #expect(provider.createdWorkingDirectory == "/remote/project-a")
        #expect(provider.createdRemoteWorkspaceID == remoteWorkspace.id)
    }

    /// Exercises the cloud shortcut failure route and verifies it stays non-modal.
    @Test("Cloud shortcut failures show their cause and export a matching diagnostic", arguments: [false, true])
    func failedCloudPaneCreationStaysInWorkspaceState(split: Bool) async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let diagnostics = CloudPaneCapturedDiagnostics()
        let identity = AuthenticatedSessionIdentity(generation: 1, accountID: "test-account")
        let recorder = CloudOperationRecorder(uploader: diagnostics, identity: { identity })
        let previousRecorder = harness.appDelegate.cloudOperations
        harness.appDelegate.cloudOperations = recorder
        defer { harness.appDelegate.cloudOperations = previousRecorder }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let machine = SurfaceMachineID.cloud("failed-pane-\(UUID().uuidString)")
        let error = CmuxTuiSurfaceProvider.ProviderError.remoteTabNotFound("tab-failure")
        let provider = CloudCreationProvider(machine: machine, workingDirectory: nil, creationError: error)
        let catalog = SurfaceCatalog.shared
        catalog.register(provider)
        defer { catalog.unregister(machine: machine) }
        let remoteWorkspace = SurfaceRemoteWorkspace(id: "ws-failure", name: "failure", index: 0, focused: true)

        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term-source"),
            title: "shell",
            detail: "/remote/home",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: remoteWorkspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab-failure", workspace: remoteWorkspace)],
            port: nil,
            url: nil
        )
        catalog.upsert(resource, from: provider)
        catalog.record(SurfaceProjection(
            resource: resource.id,
            workspaceID: workspace.id,
            panelID: sourcePanelID,
            remoteWorkspaceID: remoteWorkspace.id,
            remoteTabID: "tab-failure"
        ))

        if split {
            #expect(workspace.routeCloudPaneTerminalSplit(from: sourcePanelID, orientation: .horizontal, insertFirst: false, focus: false))
        } else {
            #expect(workspace.routeCloudPaneTerminalTab(inPane: paneID, focus: false))
        }
        let pendingPanelID = try #require(workspace.cloudPendingCreations.keys.first)
        await provider.creationAttemptSignal.wait()
        let presentation = try await waitForPaneFailure(workspace, panelID: pendingPanelID)
        let deadline = ContinuousClock.now + .seconds(2)
        while recorder.operations.first?.outcome == nil, ContinuousClock.now < deadline {
            await Task.yield()
        }

        #expect(NSApp.modalWindow == nil)
        #expect(workspace.cloudPaneCreationFailureStore.failure == nil, "A reserved terminal owns its error; no duplicate source-pane card")
        let panelID = try #require(workspace.cloudMaterializationFailures.keys.first)
        #expect(panelID != sourcePanelID)
        #expect(workspace.cloudMaterializationFailures.count == 1)
        let failure = try #require(workspace.cloudMaterializationFailures[panelID])
        #expect(panelID == pendingPanelID)
        #expect(workspace.cloudPendingCreations[panelID]?.machine == machine)
        #expect(failure.detail == CloudDiagnosticFailure.classify(error).label)
        #expect(presentation.showsReconnectButton)
        let operation = try #require(recorder.operations.first)
        #expect(operation.operation == .terminal)
        #expect(operation.failure == .notFound)
        #expect(failure.reference?.contains(operation.traceID) == true)
        let spans = await diagnostics.spans
        #expect(spans.contains { $0.parentSpanId == nil && $0.failure == .notFound && $0.traceId == operation.traceID })
        var requestIterator = provider.creationRequests.stream.makeAsyncIterator()
        let firstRequest = await requestIterator.next()
        #expect(workspace.retryReservedCloudTerminalPane(surfaceId: panelID))
        let retryRequest = await requestIterator.next()
        #expect(firstRequest != nil)
        #expect(retryRequest == firstRequest)
        _ = try await waitForPaneFailure(workspace, panelID: panelID)
        #expect(workspace.cloudPendingCreations.count == 1)
        #expect(workspace.closePanel(panelID, force: true))
        #expect(workspace.cloudPendingCreations[panelID] == nil)
        #expect(workspace.panels[panelID] == nil)
        workspace.cloudPaneCreationFailureStore.cancelAll()
    }

    @Test("Provider and placement failures retain safe error categories")
    func knownCloudTerminalFailuresAreNotUnknown() {
        let errors: [(Error, CloudDiagnosticFailure)] = [
            (CmuxTuiSurfaceProvider.ProviderError.remoteTabNotFound("tab"), .notFound),
            (CmuxTuiSurfaceProvider.ProviderError.noWorkspaceOnMachine("machine"), .placement),
            (CmuxTuiSurfaceProvider.ProviderError.stateUnavailable("machine"), .response),
            (CmuxTuiSurfaceProvider.ProviderError.terminalExited("term"), .process),
            (CmuxTuiSurfaceProvider.ProviderError.terminalNotCreated("private response"), .process),
            (SurfaceCatalogError.ambiguousRemotePlacement(.init(machine: .cloud("machine"), kind: .terminal, key: "term"), workspaceID: "private-workspace"), .conflict)
        ]
        for (error, expected) in errors {
            #expect(CloudDiagnosticFailure.classify(error) == expected)
            let failure = CloudPaneCreationFailure(machine: .cloud("machine"), error: error)
            #expect(!failure.errorText.contains("unknown error"))
            #expect(!failure.copyableText.contains("private response"))
            #expect(!failure.copyableText.contains("private-workspace"))
        }
    }

    @Test("Cloud failure controls stay above native surfaces and stop intercepting input after dismissal")
    func cloudFailureOwnsItsRenderedHitRegion() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let window = try #require(NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.main.\(harness.windowId.uuidString)"
        })
        let target = try #require(AppWindowChromeComposition().contentOverlayTargetResolver.installationTarget(for: window))
        let store = harness.workspace.cloudPaneCreationFailureStore
        let sourcePanelID = try #require(harness.workspace.focusedPanelId)
        let source = try #require(harness.workspace.terminalPanel(for: sourcePanelID))
        // A new window inherits persisted geometry and chrome from earlier
        // tests in the same app host, which can leave the terminal narrower
        // than the card's 100pt floor (seen at 124pt in a 640pt window). The
        // card is sized to `pane width - 24`, so give the pane room first.
        // Restore before tearDown closes the window so any persisted geometry
        // later tests inherit stays what it was.
        let originalFrame = window.frame
        defer { window.setFrame(originalFrame, display: false) }
        window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: true)
        let resizeDeadline = ContinuousClock.now + .seconds(3)
        while source.hostedView.bounds.width < 300, ContinuousClock.now < resizeDeadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = store.beginRequest()
        harness.workspace.presentCloudPaneCreationFailure(
            machine: .cloud("overlay-test"),
            error: CmuxTuiSurfaceProvider.ProviderError.stateUnavailable("overlay-test"),
            requestID: request
        )

        func card() -> NSView? {
            target.container.subviews.first { $0.identifier?.rawValue == "cmux.cloudPaneCreationFailure.card" }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while card() == nil, ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let overlay = try #require(card())
        let layoutDeadline = ContinuousClock.now + .seconds(3)
        while (overlay.frame.width <= 100 || overlay.frame.height <= 50), ContinuousClock.now < layoutDeadline {
            window.displayIfNeeded()
            target.container.layoutSubtreeIfNeeded()
            overlay.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        #expect(
            overlay.frame.width > 100 && overlay.frame.height > 50,
            """
            card=\(overlay.frame) inContainer=\(overlay.superview === target.container) \
            source=\(target.container.convert(source.hostedView.bounds, from: source.hostedView)) \
            sourceVisible=\(source.hostedView.visibleRect) sourceHidden=\(source.hostedView.isHiddenOrHasHiddenAncestor) \
            sourceWindowMatches=\(source.hostedView.window === window) \
            reference=\(target.container.convert(target.reference.bounds, from: target.reference)) \
            window=\(window.frame) visible=\(window.isVisible) key=\(window.isKeyWindow) \
            mainWindows=\(NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("cmux.main.") == true }.map { "\($0.frame)" })
            """
        )
        let terminalFrame = target.container.convert(source.hostedView.bounds, from: source.hostedView)
        #expect(abs(overlay.frame.midX - terminalFrame.midX) < 2)
        #expect(abs(overlay.frame.midY - terminalFrame.midY) < 2)
        #expect(terminalFrame.contains(overlay.frame), "The card must not cover Bonsplit tabs or adjacent panes")

        // A browser portal installed after the card must remain underneath it.
        let browserPortal = WindowBrowserPortal(window: window)
        _ = browserPortal.webViewAtWindowPoint(.zero)
        let nativeHosts = target.container.subviews.filter {
            $0 is WindowTerminalHostView || $0 is WindowBrowserHostView
        }
        #expect(!nativeHosts.isEmpty)
        let overlayIndex = try #require(target.container.subviews.firstIndex(of: overlay))
        for host in nativeHosts {
            #expect(try #require(target.container.subviews.firstIndex(of: host)) < overlayIndex)
        }
        let point = overlay.convert(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY), to: target.container.superview)
        let hit = try #require(target.container.hitTest(point))
        #expect(hit === overlay || hit.isDescendant(of: overlay))

        let outside = overlay.convert(NSPoint(x: -20, y: overlay.bounds.midY), to: target.container.superview)
        if let outsideHit = target.container.hitTest(outside) {
            #expect(outsideHit !== overlay && !outsideHit.isDescendant(of: overlay))
        }

        store.dismiss(id: try #require(store.failure?.id))
        let dismissDeadline = ContinuousClock.now + .seconds(3)
        while card() != nil, ContinuousClock.now < dismissDeadline {
            await Task.yield()
        }
        #expect(card() == nil)
    }

    @Test("Failure text uses the full width in narrow terminals", arguments: [CGFloat(166), 260, 360])
    func narrowFailureCardRemainsReadable(width: CGFloat) {
        let failure = CloudPaneCreationFailure(machine: .cloud("narrow-pane"), error: CmuxTuiSurfaceProvider.ProviderError.stateUnavailable("narrow-pane"))
        let host = NSHostingView(rootView: CloudPaneCreationFailureView(failure: failure, onRetry: {}, onDismiss: {})
            .frame(width: width).fixedSize(horizontal: false, vertical: true))
        let size = host.fittingSize
        #expect(abs(size.width - width) < 1)
        #expect(size.height < 210, "The detail must not be squeezed into a side column")
    }

    @Test("A retained Cloud projection never falls back to a local terminal", arguments: ["split", "tab", "splitButton"])
    func failedCloudRouteDoesNotCreateLocalPanel(action: String) throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let machine = SurfaceMachineID.cloud("missing-provider-\(UUID().uuidString)")
        let remoteWorkspace = SurfaceRemoteWorkspace(id: "ws-missing-provider", name: "missing", index: 0, focused: true)
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term-missing-provider"),
            title: "shell", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: remoteWorkspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab-missing-provider", workspace: remoteWorkspace)],
            port: nil, url: nil
        )
        let catalog = SurfaceCatalog.shared
        // A restored projection keeps its Cloud identity before the provider
        // reconnects and publishes its resource graph.
        catalog.record(SurfaceProjection(
            resource: resource.id,
            workspaceID: workspace.id,
            panelID: sourcePanelID,
            remoteWorkspaceID: remoteWorkspace.id,
            remoteTabID: "tab-missing-provider"
        ))
        defer {
            catalog.endProjections(panelID: sourcePanelID, reason: .replaced)
        }
        #expect(catalog.hasCloudProjection(panelID: sourcePanelID, workspaceID: workspace.id))
        #expect(workspace.cloudProjectedResource(forPanel: sourcePanelID) == nil)

        let panelCount = workspace.panels.count
        switch action {
        case "tab":
            #expect(!workspace.newTerminalSurfaceOutcome(inPane: paneID, focus: false).isAccepted)
        case "splitButton":
            workspace.bonsplitController.splitPane(paneID, orientation: .horizontal)
        default:
            #expect(!workspace.newTerminalSplitOutcome(
                from: sourcePanelID, orientation: .horizontal, focus: false
            ).isAccepted)
        }
        #expect(workspace.panels.count == panelCount)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        #expect(workspace.bonsplitController.tabs(inPane: paneID).count == 1)
    }

    @Test("Cloud placement errors have a specific diagnostic")
    func cloudPlacementErrorHasSpecificDiagnostic() {
        let error = CmuxTuiSurfaceProvider.ProviderError.noWorkspaceOnMachine("vm-placement")
        #expect(CloudDiagnosticFailure.classify(error) == .placement)
        #expect(CloudDiagnosticFailure.classify(error).label.contains("placement"))
    }

    @Test("Creation failure belongs to its visible workspace and detaches with its anchor")
    func failureCardTracksWorkspaceVisibilityAndWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 720, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let target = try #require(AppWindowChromeComposition().contentOverlayTargetResolver.installationTarget(for: window))
        let root = target.container
        let source = NSView(frame: content.bounds)
        content.addSubview(source)
        let host = CloudPaneCreationFailurePresentation.NativeOverlay.AnchorView(frame: content.bounds)
        let coordinator = CloudPaneCreationFailurePresentation.NativeOverlay.Coordinator()
        coordinator.anchor = host
        host.coordinator = coordinator
        content.addSubview(host)
        defer { coordinator.removeCard() }
        let failure = CloudPaneCreationFailure(machine: .cloud("fixture"), error: URLError(.timedOut))
        coordinator.update(failure: failure, layoutDirection: .leftToRight, colorScheme: .light,
                           sourceView: source, style: .compact, onRetry: nil, onDismiss: { _ in })
        func card() -> NSView? {
            root.subviews.first { $0.identifier?.rawValue == "cmux.cloudPaneCreationFailure.card" }
        }
        let visibleCard = try #require(card())
        #expect(!visibleCard.isDescendant(of: content))
        #expect(visibleCard.frame.width > 0 && visibleCard.frame.height > 0)
        #expect(content.convert(visibleCard.bounds, from: visibleCard).minX >= 0)
        #expect(content.convert(visibleCard.bounds, from: visibleCard).maxX <= content.bounds.maxX)
        #expect(host.hitTest(NSPoint(x: 5, y: 5)) == nil)
        host.isHidden = true
        #expect(card() == nil, "Switching workspaces must remove its window-level error")
        host.isHidden = false
        #expect(card() != nil)
        host.removeFromSuperview()
        #expect(card() == nil, "An unmounted workspace must not leave an orphan card")
    }

    /// Ensures a suspended older request cannot replace a newer request's failure.
    @Test("Superseded cloud pane failures are ignored")
    func supersededCloudPaneFailureDoesNotReplaceCurrentRequest() throws {
        let store = CloudPaneCreationFailureStore()
        let first = store.beginRequest()
        let second = store.beginRequest()
        let error = NSError(domain: "CloudPaneCreationFailureTests", code: 1)

        store.present(machine: .cloud("old"), error: error, requestID: first)
        #expect(store.failure == nil)
        store.present(machine: .cloud("new"), error: error, requestID: second)
        #expect(store.failure?.machine == .cloud("new"))
    }

    @Test("Cloud placement failures remain inline and dismissible")
    func cloudPlacementFailureDoesNotOpenAModal() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let machine = SurfaceMachineID.cloud("placement-fixture")

        workspace.presentCloudPlacementFailure(CloudDiagnosticFailure.network, machine: machine)

        #expect(NSApp.modalWindow == nil)
        let failure = try #require(workspace.cloudPaneCreationFailureStore.failure)
        #expect(failure.machine == machine)
        #expect(failure.title == String(localized: "cloudPane.layoutSyncFailed.title", defaultValue: "Couldn’t update the machine workspace"))
        workspace.cloudPaneCreationFailureStore.dismiss(id: failure.id)
        #expect(workspace.cloudPaneCreationFailureStore.failure == nil)
    }

    @Test("Cloud process cwd parsing ignores the recorded spawn directory")
    func cloudProcessCwdParsingIgnoresSpawnDirectory() {
        #expect(CloudTuiCommandLine.processInfoArguments(socketPath: "/tmp/cloud.sock", terminalID: "term-source") == [
            "--socket", "/tmp/cloud.sock", "--json", "terminal", "term-source", "process", "show"
        ])
        #expect(CloudTuiCommandLine.foregroundWorkingDirectory(fromProcessInfo: [
            "cwd": "/remote/home",
            "foreground_cwd": "/remote/project-a"
        ]) == "/remote/project-a")
        #expect(CloudTuiCommandLine.foregroundWorkingDirectory(fromProcessInfo: [
            "cwd": "/remote/home",
            "foreground_cwd": ""
        ]) == nil)
    }

    @MainActor
    private final class CloudCreationProvider: SurfaceProvider {
        let machine: SurfaceMachineID
        let info: SurfaceMachineInfo
        let workingDirectory: String?
        private(set) var createdWorkingDirectory: String?
        private(set) var createdRemoteWorkspaceID: String?

        var materializePane: ((SurfaceResource, SurfaceDestination, Bool) throws -> SurfaceProjection)?
        let creationError: Error?
        let creationAttemptSignal = CreationAttemptSignal()
        let creationRequests = AsyncStream<UUID>.makeStream()
        private(set) var creationRequestCount = 0

        /// Creates a provider fixture with optional deterministic creation failure.
        init(machine: SurfaceMachineID, workingDirectory: String?, creationError: Error? = nil) {
            self.machine = machine
            self.workingDirectory = workingDirectory
            self.creationError = creationError
            info = SurfaceMachineInfo(
                id: machine, name: machine.rawValue, status: "running", image: nil,
                hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
                linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
            )
        }

        /// Satisfies the provider refresh contract without touching the network.
        func refresh() async {}

        /// Returns the fixture's configured foreground directory.
        func currentWorkingDirectory(of _: SurfaceResource) async -> String? {
            workingDirectory
        }

        /// Signals and throws the configured failure, or returns a fixture resource.
        func createTerminal(command _: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
            if let creationError {
                creationAttemptSignal.signal()
                throw creationError
            }
            createdWorkingDirectory = cwd
            createdRemoteWorkspaceID = remoteWorkspaceID
            return SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term-created"),
                title: name ?? "shell",
                detail: cwd,
                lifecycle: .launching,
                agent: nil,
                remoteWorkspace: nil,
                port: nil,
                url: nil
            )
        }

        func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?, request: CloudTerminalCreationRequest) async throws -> SurfaceResource {
            creationRequestCount += 1
            creationRequests.continuation.yield(request.id)
            return try await createTerminal(command: command, cwd: cwd, name: name, remoteWorkspaceID: remoteWorkspaceID)
        }

        @MainActor
        final class CreationAttemptSignal {
            private var didSignal = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            /// Waits for the provider to enter its throwing create path.
            func wait() async {
                if didSignal { return }
                await withCheckedContinuation { continuation in
                    if didSignal {
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                    }
                }
            }

            /// Completes all waiters exactly once when creation starts.
            func signal() {
                didSignal = true
                let pending = waiters
                waiters.removeAll()
                for waiter in pending {
                    waiter.resume()
                }
            }
        }

        /// Returns a projection fixture for unrelated provider protocol calls.
        func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
            if let materializePane { return try materializePane(resource, destination, focus) }
            return SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
        }

        /// Records no state when the test projection ends.
        func projectionDidEnd(_: SurfaceProjection) {}
    }

    @Test func unfocusedTabStaysBehindTheCurrentOne() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: nil,
            workingDirectory: nil,
            at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
            focus: false
        )

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == before)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == before)
    }

    /// Cmd+D from a cloud pane (`routeCloudPaneTerminalSplit`) lands in the split
    /// handler with the same gate; the new pane must take focus when asked.
    @Test func focusedSplitFocusesTheNewPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: nil,
            workingDirectory: nil,
            at: .split(workspaceID: workspace.id, paneID: paneID.id.uuidString, direction: .right),
            focus: true
        )

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == created.panelID)
        #expect(workspace.paneId(forPanelId: created.panelID) != paneID)
    }

    /// A projected browser (VM desktop or port preview) goes through the same create
    /// handler as a terminal; `focus: true` must select it too.
    @Test func focusedBrowserTabIsSelected() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try SurfacePaneFactory.makeBrowserPane(
            url: SurfacePaneFactory.blankURL,
            at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
            focus: true
        )

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == created.panelID)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == created.panelID)
    }

    @Test("Cloud resource drop hands keyboard ownership to its first pane")
    func cloudPaneFocusTransfersKeyboardOwnershipFromSidebar() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let window = try #require(harness.appDelegate.mainWindow(for: harness.windowId))
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let catalog = SurfaceCatalog()
        let provider = CloudCreationProvider(machine: .cloud("drop-fixture"), workingDirectory: nil)
        catalog.register(provider)
        var created: [UUID] = []
        provider.materializePane = { resource, destination, focus in
            let panel = try SurfacePaneFactory.makeTerminalPane(
                initialCommand: nil, workingDirectory: nil, at: destination, focus: focus
            )
            created.append(panel.panelID)
            return SurfaceProjection(resource: resource.id, workspaceID: panel.workspaceID, panelID: panel.panelID)
        }
        let resources = ["first", "second"].map { name in
            SurfaceResource(id: SurfaceResourceID(machine: provider.machine, kind: .terminal, key: name),
                            title: name, detail: nil, lifecycle: .running, agent: nil,
                            remoteWorkspace: nil, port: nil, url: nil)
        }
        catalog.replaceResources(resources, on: provider.machine)
        harness.appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .machines, in: window)
        #expect(harness.appDelegate.rightSidebarOwnsInputFocus(for: workspace))
        #expect(workspace.handleSurfaceResourceDrop(
            group: SurfaceResourceGroup(title: "drop", resources: resources.map(\.id)),
            destination: .split(targetPane: paneID, orientation: .horizontal, insertFirst: false),
            catalog: catalog
        ))
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline,
              created.count < 2 || harness.appDelegate.rightSidebarOwnsInputFocus(for: workspace) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(created.count == 2)
        let first = try #require(created.first)
        #expect(workspace.focusedPanelId == first)
        #expect(workspace.paneId(forPanelId: first) != paneID)
        #expect(!harness.appDelegate.rightSidebarOwnsInputFocus(for: workspace))
        #expect(harness.appDelegate.allowsTerminalKeyboardFocus(workspaceId: workspace.id, panelId: first, in: window))
    }

    /// Inside a socket command whose policy forbids focus mutations, the factory must
    /// not re-enable them: the outer policy wins over the caller's `focus: true`.
    @Test func focusRequestCannotEscapeAFocusForbiddingSocketPolicy() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try TerminalController.withSocketCommandPolicyStack([false]) {
            try SurfacePaneFactory.makeTerminalPane(
                initialCommand: nil,
                workingDirectory: nil,
                at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
                focus: true
            )
        }

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == before)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == before)
    }

    private func waitForPaneFailure(_ workspace: Workspace, panelID: UUID) async throws -> CloudTerminalReconnectOverlayPolicy.Presentation {
        let deadline = ContinuousClock.now + .seconds(5)
        while workspace.cloudMaterializationFailures[panelID] == nil, ContinuousClock.now < deadline { await Task.yield() }
        return try #require(workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: panelID))
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let workspace: Workspace

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
        }

        func tearDown() {
            let identifier = "cmux.main.\(windowId.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}

private actor CloudPaneCapturedDiagnostics: CloudTelemetrySending {
    private(set) var spans: [CloudTelemetrySpan] = []
    func enqueue(_ span: CloudTelemetrySpan, identity: AuthenticatedSessionIdentity) { spans.append(span) }
    func clearForSignOut() { spans.removeAll() }
}
