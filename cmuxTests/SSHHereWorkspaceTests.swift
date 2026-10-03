import Bonsplit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The real socket handler, coordinator, SSH link, provider, reservation and
/// native pane factory run here. Only the remote daemon is a local protocol
/// peer. No assertion relies on a newly introduced --here implementation API,
/// so this suite also compiles against the pre-fix native SSH owner.
@MainActor
@Suite("SSH here workspace lifecycle", .serialized)
struct SSHHereWorkspaceTests {
    @Test("SSH here applies focus while remote creation is still pending", .timeLimit(.minutes(1)), arguments: [true, false])
    func pendingHereVisitHonorsFocus(focus: Bool) async throws {
        try await SSHHereDaemonFixture.withFixture(mode: .holdCreate) { fixture in
            let other = fixture.manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
            let before = try OriginalPane(fixture: fixture)
            #expect(fixture.manager.selectedTabId == other.id)
            let opening = Task { _ = try await fixture.open(extra: ["focus": focus]) }
            defer { opening.cancel(); try? fixture.releaseCreate() }
            try await fixture.waitForCreate()
            // Waiting for the daemon must already show the connecting pane
            // for an interactive open. --no-focus keeps the user's selection.
            let expectedSelection = focus ? fixture.workspace.id : other.id
            #expect(fixture.manager.selectedTabId == expectedSelection)
            #expect(fixture.manager.tabs.map(\.id) == before.workspaceIDs)
            #expect(fixture.workspace.groupId == before.groupID)
            #expect(fixture.workspace.bonsplitController.allPaneIds == before.paneIDs)
            let remote = try #require(fixture.workspace.panels.values.compactMap { $0 as? TerminalPanel }.first)
            #expect(remote.id != before.panel.id)
            #expect(remote.surface.ioMode == .manualMirror)
            #expect(fixture.workspace.paneId(forPanelId: remote.id) == before.paneID)
            try fixture.releaseCreate()
            try await opening.value
            #expect(fixture.manager.selectedTabId == expectedSelection)
            #expect(fixture.workspace.terminalPanel(for: remote.id) === remote,
                    "Completing the attach must use the pane shown during connection")
            fixture.workspace.disconnectRemoteConnection(clearConfiguration: true)
            try before.expectRestored(fixture: fixture)
            #expect(fixture.manager.selectedTabId == expectedSelection)
        }
    }

    @Test("SSH here and disconnect preserve the workspace, pane, group and original terminal", .timeLimit(.minutes(1)))
    func disconnectReturnsToOriginalTerminal() async throws {
        try await SSHHereDaemonFixture.withFixture { fixture in
            let before = try OriginalPane(fixture: fixture)
            let result = try await fixture.open()
            let remote = try before.expectRemote(result: result, fixture: fixture)
            #expect(fixture.provider.manualMirrorSessions[remote] != nil,
                    "The concrete provider must adopt the native reserved pane")
            fixture.workspace.disconnectRemoteConnection(clearConfiguration: true)
            try before.expectRestored(fixture: fixture)
            #expect(fixture.provider.manualMirrorSessions[remote] == nil)
            #expect(fixture.caller.isRunning, "Disconnect must not terminate the CLI caller")
        }
    }

    @Test("SSH here rejects missing or stale caller identity before mutating the workspace",
          .timeLimit(.minutes(1)), arguments: ["missing", "malformed", "dead", "wrong-generation"])
    func invalidCallerFailsWithoutMutation(kind: String) async throws {
        try await SSHHereDaemonFixture.withFixture { fixture in
            let before = try OriginalPane(fixture: fixture)
            var caller = try fixture.callerProcessPayload()
            switch kind {
            case "malformed": caller["pid"] = true
            case "dead": try await fixture.stopCaller()
            case "wrong-generation":
                let identity = try #require(fixture.callerIdentity)
                caller["start_seconds"] = identity.startSeconds + 1
            default: break
            }
            let extra: [String: Any] = kind == "missing" ? [:] : ["caller_process": caller]
            await #expect(throws: (any Error).self) {
                _ = try await fixture.open(extra: extra, includeCaller: kind != "missing")
            }
            try before.expectRestored(fixture: fixture)
            #expect(try !fixture.operations().contains("workspace.create"))
            #expect(try !fixture.operations().contains("workspace.run"))
        }
    }

    @Test("Caller exit during remote creation restores the shell before the daemon answers", .timeLimit(.minutes(1)))
    func callerExitDuringCreateRestoresWithoutLateHandoff() async throws {
        try await SSHHereDaemonFixture.withFixture(mode: .holdCreate) { fixture in
            let before = try OriginalPane(fixture: fixture)
            let opening = Task { _ = try await fixture.open() }
            defer { opening.cancel(); try? fixture.releaseCreate() }
            try await fixture.waitForCreate()
            #expect(fixture.workspace.panels[before.panel.id] == nil)
            try await fixture.stopCaller()
            try await before.waitForRestoration(fixture: fixture)
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("release-create").path),
                    "Caller death must restore the shell without waiting for the blocked daemon")
            try fixture.releaseCreate()
            await #expect(throws: (any Error).self) { _ = try await opening.value }
            try before.expectRestored(fixture: fixture)
        }
    }

    @Test("Caller exit after attachment returns to the original terminal", .timeLimit(.minutes(1)))
    func callerExitAfterAttachRestoresOriginalTerminal() async throws {
        try await SSHHereDaemonFixture.withFixture { fixture in
            let before = try OriginalPane(fixture: fixture)
            let result = try await fixture.open()
            let remote = try before.expectRemote(result: result, fixture: fixture)
            try await fixture.stopCaller()
            try await before.waitForRestoration(fixture: fixture)
            #expect(fixture.provider.manualMirrorSessions[remote] == nil)
        }
    }

    @Test("A caller that exits during authentication cannot hand off when the carrier later connects", .timeLimit(.minutes(1)))
    func callerExitDuringPreflightCannotParkLocalShell() async throws {
        try await SSHHereDaemonFixture.withFixture(mode: .holdPreflight) { fixture in
            let before = try OriginalPane(fixture: fixture)
            let opening = Task { _ = try await fixture.open() }
            defer { opening.cancel(); try? fixture.releasePreflight() }
            try await fixture.waitForPreflight()
            try before.expectRestored(fixture: fixture)
            try await fixture.stopCaller()
            // The real link manager accepts a carrier that connected during
            // its preflight, even if that preflight later refuses login. This
            // forces the open handler to revalidate the caller after its await.
            try await fixture.startCarrier()
            try fixture.releasePreflight()
            await #expect(throws: (any Error).self) { _ = try await opening.value }
            try before.expectRestored(fixture: fixture)
            #expect(try !fixture.operations().contains("workspace.create"))
            #expect(try !fixture.operations().contains("workspace.run"))
        }
    }

    @Test("Interrupting the real CLI during authentication cannot cause a delayed pane handoff", .timeLimit(.minutes(1)))
    func realCLIInterruptAndSocketEOFCannotHandOffLater() async throws {
        try await SSHHereDaemonFixture.withFixture(mode: .holdPreflight) { fixture in
            let before = try OriginalPane(fixture: fixture)
            try await fixture.interruptCLIWhilePreflightIsHeld()
            try before.expectRestored(fixture: fixture)
            #expect(try !fixture.operations().contains("workspace.create"))
            #expect(try !fixture.operations().contains("workspace.run"))
        }
    }

    @Test("An SSH here process exit returns to the same local shell instead of closing its workspace", .timeLimit(.minutes(1)))
    func processExitReturnsToOriginalTerminal() async throws {
        try await SSHHereDaemonFixture.withFixture { fixture in
            let before = try OriginalPane(fixture: fixture)
            let result = try await fixture.open()
            let remote = try before.expectRemote(result: result, fixture: fixture)
            // This is the production provider's process-ended callback, not an
            // ordinary user close (which cannot close a workspace's last pane).
            SurfacePaneFactory.closeExited(panelID: remote, in: fixture.workspace.id)
            try before.expectRestored(fixture: fixture)
        }
    }

    @Test("Moving an SSH here anchor cannot orphan the parked local shell", .timeLimit(.minutes(1)))
    func remoteAnchorCannotDetachDuringVisit() async throws {
        try await SSHHereDaemonFixture.withFixture { fixture in
            let before = try OriginalPane(fixture: fixture)
            let result = try await fixture.open()
            let remote = try before.expectRemote(result: result, fixture: fixture)
            let panel = try #require(fixture.workspace.terminalPanel(for: remote))
            let detached = fixture.workspace.detachSurface(panelId: remote)
            #expect(detached == nil, "An in-place visit must keep the anchor that owns its return shell")
            #expect(fixture.workspace.terminalPanel(for: remote) === panel)
            #expect(fixture.provider.manualMirrorSessions[remote] != nil)
            #expect(fixture.workspace.paneId(forPanelId: remote) == before.paneID)
            // If this assertion fails on the old implementation, its transfer
            // still owns the remote panel. Do not leak that failed-test panel.
            defer { detached?.panel.close() }
            fixture.workspace.disconnectRemoteConnection(clearConfiguration: true)
            try before.expectRestored(fixture: fixture)
        }
    }

    @Test("A refused remote create rolls SSH here back without replacing its terminal", .timeLimit(.minutes(1)))
    func creationFailureRestoresOriginalTerminal() async throws {
        try await SSHHereDaemonFixture.withFixture(mode: .failCreate) { fixture in
            let before = try OriginalPane(fixture: fixture)
            await #expect(throws: (any Error).self) {
                _ = try await fixture.open(extra: ["title": "Must roll back"])
            }
            try before.expectRestored(fixture: fixture)
            #expect(fixture.workspace.customTitle == before.title)
            #expect(try fixture.operations().contains("workspace.run"))
        }
    }

    @Test("Disconnect during SSH here creation fences a late daemon reply", .timeLimit(.minutes(1)))
    func disconnectDuringCreateCannotReplaceRestoredShell() async throws {
        try await SSHHereDaemonFixture.withFixture(mode: .holdCreate) { fixture in
            let before = try OriginalPane(fixture: fixture)
            let opening = Task { _ = try await fixture.open() }
            defer { opening.cancel(); try? fixture.releaseCreate() }
            try await fixture.waitForCreate()
            #expect(fixture.manager.tabs.map(\.id) == before.workspaceIDs,
                    "--here must not create another local workspace while the daemon is busy")
            #expect(fixture.workspace.panels[before.panel.id] == nil,
                    "The local shell should be parked while the native remote pane is connecting")
            fixture.workspace.disconnectRemoteConnection(clearConfiguration: true)
            try before.expectRestored(fixture: fixture)
            try fixture.releaseCreate()
            await #expect(throws: (any Error).self) { _ = try await opening.value }
            try before.expectRestored(fixture: fixture)
            #expect(!SurfaceCatalog.shared.projections.contains {
                $0.workspaceID == fixture.workspace.id && $0.resource.machine == fixture.provider.machine
            })
        }
    }

    @Test("Canceling an SSH here request during creation restores its original pane", .timeLimit(.minutes(1)))
    func cancellationDuringCreateRestoresOriginalTerminal() async throws {
        try await SSHHereDaemonFixture.withFixture(mode: .holdCreate) { fixture in
            let before = try OriginalPane(fixture: fixture)
            let opening = Task { _ = try await fixture.open() }
            defer { opening.cancel(); try? fixture.releaseCreate() }
            try await fixture.waitForCreate()
            opening.cancel()
            try fixture.releaseCreate()
            await #expect(throws: (any Error).self) { _ = try await opening.value }
            try before.expectRestored(fixture: fixture)
        }
    }

    @Test("A stale SSH here caller cannot replace the focused terminal", .timeLimit(.minutes(1)))
    func staleCallerSurfaceFailsWithoutMutation() async throws {
        try await SSHHereDaemonFixture.withFixture { fixture in
            let before = try OriginalPane(fixture: fixture)
            await #expect(throws: (any Error).self) {
                _ = try await fixture.open(extra: ["surface_id": UUID().uuidString])
            }
            try before.expectRestored(fixture: fixture)
            #expect(try !fixture.operations().contains("workspace.create"))
            #expect(try !fixture.operations().contains("workspace.run"))
        }
    }

    @MainActor
    private struct OriginalPane {
        let workspaceIDs: [UUID]
        let paneIDs: [PaneID]
        let paneID: PaneID
        let panel: TerminalPanel
        let groupID: UUID?
        let title: String?

        init(fixture: SSHHereDaemonFixture) throws {
            let panelID = try #require(fixture.workspace.focusedPanelId)
            panel = try #require(fixture.workspace.terminalPanel(for: panelID))
            paneID = try #require(fixture.workspace.paneId(forPanelId: panelID))
            paneIDs = fixture.workspace.bonsplitController.allPaneIds
            workspaceIDs = fixture.manager.tabs.map(\.id)
            groupID = fixture.workspace.groupId
            title = fixture.workspace.customTitle
            #expect(panel.surface.ioMode == .exec)
        }

        func expectRemote(result: [String: Any], fixture: SSHHereDaemonFixture) throws -> UUID {
            #expect(result["workspace_id"] as? String == fixture.workspace.id.uuidString)
            #expect(fixture.manager.tabs.map(\.id) == workspaceIDs)
            #expect(fixture.workspace.groupId == groupID)
            #expect(fixture.workspace.bonsplitController.allPaneIds == paneIDs)
            let remoteID = try #require((result["surface_id"] as? String).flatMap(UUID.init(uuidString:)))
            let remote = try #require(fixture.workspace.terminalPanel(for: remoteID))
            #expect(remoteID != panel.id)
            #expect(remote.surface.ioMode == .manualMirror)
            #expect(fixture.workspace.panels[panel.id] == nil)
            #expect(fixture.workspace.paneId(forPanelId: remoteID) == paneID)
            #expect(Set(fixture.workspace.panels.keys) == [remoteID])
            let operationID = try #require(result["here_operation_id"] as? String)
            #expect(UUID(uuidString: operationID) != nil)
            #expect(fixture.workspace.remoteStatusPayload()["here_operation_id"] as? String == operationID,
                    "The caller waits on exactly this visit, not any later SSH connection")
            return remoteID
        }

        func expectRestored(fixture: SSHHereDaemonFixture) throws {
            #expect(fixture.manager.tabs.map(\.id) == workspaceIDs)
            #expect(fixture.workspace.groupId == groupID)
            #expect(fixture.workspace.bonsplitController.allPaneIds == paneIDs)
            #expect(fixture.workspace.paneId(forPanelId: panel.id) == paneID)
            #expect(Set(fixture.workspace.panels.keys) == [panel.id])
            let restored = try #require(fixture.workspace.terminalPanel(for: panel.id))
            #expect(restored === panel, "Returning must reuse the live TerminalPanel, not respawn its shell")
            #expect(restored.surface === panel.surface)
            #expect(restored.surface.ioMode == .exec)
            #expect(fixture.workspace.remoteConfiguration == nil)
            #expect(fixture.workspace.cloudVMBinding == nil)
            #expect(fixture.workspace.cloudPendingCreations.isEmpty)
            #expect(fixture.workspace.remoteStatusPayload()["here_operation_id"] == nil)
        }

        func waitForRestoration(fixture: SSHHereDaemonFixture) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while fixture.workspace.terminalPanel(for: panel.id) !== panel,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try expectRestored(fixture: fixture)
        }
    }
}
