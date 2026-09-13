import AppKit
import Bonsplit
import Testing

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
    @Test("Failed cloud pane creation does not enter a process-modal run loop")
    func failedCloudPaneCreationStaysInWorkspaceState() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let machine = SurfaceMachineID.cloud("failed-pane-\(UUID().uuidString)")
        let error = NSError(
            domain: "CloudPaneCreationFailureTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "connection refused"]
        )
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

        #expect(workspace.routeCloudPaneTerminalTab(inPane: paneID, focus: false))
        await provider.creationAttemptSignal.wait()

        #expect(NSApp.modalWindow == nil)
        let failure = try #require(workspace.cloudPaneCreationFailureStore.failure)
        #expect(failure.machine == machine)
        #expect(!failure.errorText.isEmpty)
        #expect(!failure.errorText.contains("connection refused"))

        workspace.dismissCloudPaneCreationFailure(id: failure.id)
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

        let creationError: Error?
        let creationAttemptSignal = CreationAttemptSignal()

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

        func refresh() async {}

        func currentWorkingDirectory(of _: SurfaceResource) async -> String? {
            workingDirectory
        }

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

        func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus _: Bool) async throws -> SurfaceProjection {
            SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
        }

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
