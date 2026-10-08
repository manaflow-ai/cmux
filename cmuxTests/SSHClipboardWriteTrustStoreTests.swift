import CmuxCloud
import CmuxSurfaceCatalogModel
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHClipboardWriteTrustStoreTests {
    // Regression context from #18324 (@simjak): cmux 0.65.0's cmux-tui SSH
    // mirrors received OSC 52 from a remote TUI/tmux selection, but the
    // manual-I/O callback policy kept that remote-origin write off the Mac
    // clipboard until the user explicitly trusted the SSH machine.
    @Test("trust is opt-in, endpoint-scoped, revocable, and write-only")
    @MainActor
    func trustPolicy() throws {
        let suiteName = "cmux.ssh-clipboard-trust-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHClipboardWriteTrustStore(defaults: defaults)
        let trusted = SurfaceMachineID.ssh("endpoint-a")
        let differentEndpoint = SurfaceMachineID.ssh("endpoint-b")

        #expect(!store.isTrusted(trusted))
        #expect(!store.allowsRemoteClipboardWrites(for: trusted))
        #expect(!store.allowsRemoteClipboardReads(for: trusted))
        #expect(store.allowsRemoteClipboardWrites(for: .cloud("cloud-machine")))
        #expect(!store.allowsRemoteClipboardWrites(for: .local))

        store.setTrusted(true, for: trusted)
        #expect(store.isTrusted(trusted))
        #expect(store.allowsRemoteClipboardWrites(for: trusted))
        #expect(!store.allowsRemoteClipboardWrites(for: differentEndpoint))
        #expect(!store.allowsRemoteClipboardReads(for: trusted))

        let reloaded = SSHClipboardWriteTrustStore(defaults: defaults)
        #expect(reloaded.isTrusted(trusted))
        reloaded.setTrusted(false, for: trusted)
        #expect(!reloaded.isTrusted(trusted))
        #expect(!reloaded.allowsRemoteClipboardWrites(for: trusted))
    }

    @Test("ownership index keeps pending mirror wrappers addressable")
    @MainActor
    func ownershipIndexIncludesPendingRestoreIdentity() {
        let wrapperPanelID = UUID()
        let machine = SurfaceMachineID.ssh("nested-endpoint")
        let pending = SurfaceProjection(
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_nested"),
            workspaceID: UUID(),
            panelID: wrapperPanelID
        )

        let index = SSHClipboardWriteSurfaceOwnershipIndex(
            projections: [],
            pendingRestores: [pending]
        )

        #expect(index.machine(for: wrapperPanelID) == machine)
        #expect(index.machine(for: UUID()) == nil)
    }

    @Test("generic manual mirrors do not inherit workspace SSH trust")
    @MainActor
    func genericManualMirrorRemainsDenied() throws {
        let suiteName = "cmux.ssh-clipboard-generic-mirror-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHClipboardWriteTrustStore(defaults: defaults)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: 2222,
            identityFile: "/tmp/id_test",
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        let machine = SurfaceMachineID.ssh(SSHTuiConnection(configuration: configuration).identityDigest)
        store.setTrusted(true, for: machine)

        let workspace = Workspace(sshClipboardWriteTrustStore: store)
        workspace.remoteConfiguration = configuration
        let panel = try #require(workspace.makeRemoteTmuxPanePanel(onInput: { _ in }))
        _ = try workspace.insertCloudManualMirrorPanel(
            panel, at: .workspace(id: workspace.id, placement: .tab),
            focus: false, isLoading: false
        )
        let ownership = SSHClipboardWriteSurfaceOwnershipIndex(projections: [], pendingRestores: [])
        workspace.applySSHClipboardWritePermission(for: machine, ownership: ownership)

        #expect(!panel.surface.allowsRemoteClipboardWrites)
        #expect(workspace.sshClipboardMachine(for: panel.id, ownership: ownership) == nil)
    }

    @Test("pending SSH cmux-tui reservations keep their machine identity")
    @MainActor
    func pendingSSHTuiReservationRemainsOwned() throws {
        let suiteName = "cmux.ssh-clipboard-pending-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHClipboardWriteTrustStore(defaults: defaults)
        let workspace = Workspace(sshClipboardWriteTrustStore: store)
        let machine = SurfaceMachineID.ssh("pending-ssh-machine")
        store.setTrusted(true, for: machine)
        let reservation = try #require(workspace.reserveCloudTerminalPane(
            machine: machine,
            at: .workspace(id: workspace.id, placement: .tab),
            focus: false
        ))
        let panel = try #require(workspace.terminalPanel(for: reservation.panelID))
        let ownership = SSHClipboardWriteSurfaceOwnershipIndex(projections: [], pendingRestores: [])
        #expect(panel.surface.allowsRemoteClipboardWrites)
        #expect(workspace.sshClipboardMachine(for: panel.id, ownership: ownership) == machine)
        store.setTrusted(false, for: machine)
        workspace.applySSHClipboardWritePermission(for: machine, ownership: ownership)
        #expect(!panel.surface.allowsRemoteClipboardWrites)
    }

    @Test("live cmux-tui projections own their trust independently of workspace configuration")
    @MainActor
    func liveSSHTuiMirrorUsesProjectionIdentity() throws {
        let suiteName = "cmux.ssh-clipboard-tui-mirror-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHClipboardWriteTrustStore(defaults: defaults)
        let machine = SurfaceMachineID.ssh("projected-ssh-machine")
        let workspace = Workspace(sshClipboardWriteTrustStore: store)
        let panel = try #require(workspace.makeRemoteTmuxPanePanel(onInput: { _ in }))
        let panelID = try workspace.insertCloudManualMirrorPanel(
            panel, at: .workspace(id: workspace.id, placement: .tab),
            focus: false, isLoading: false
        )
        let projection = SurfaceProjection(
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "tui-term"),
            workspaceID: workspace.id, panelID: panelID
        )
        let ownership = SSHClipboardWriteSurfaceOwnershipIndex(projections: [projection], pendingRestores: [])
        #expect(workspace.sshClipboardMachine(for: panelID, ownership: ownership) == machine)
        store.setTrusted(true, for: machine)
        workspace.applySSHClipboardWritePermission(for: machine, ownership: ownership)
        #expect(panel.surface.allowsRemoteClipboardWrites)
        store.setTrusted(false, for: machine)
        workspace.applySSHClipboardWritePermission(for: machine, ownership: ownership)
        #expect(!panel.surface.allowsRemoteClipboardWrites)
    }

    @Test("plain SSH tmux mirrors keep the grant for future nested panes")
    @MainActor
    func plainSSHMirrorUsesHostIdentityForNewPanes() throws {
        let suiteName = "cmux.ssh-clipboard-remote-tmux-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHClipboardWriteTrustStore(defaults: defaults)
        let host = RemoteTmuxHost(
            destination: "user@example.test",
            port: 2222,
            identityFile: "/tmp/id_test"
        )
        let configuration = WorkspaceRemoteConfiguration(
            destination: host.destination,
            port: host.port,
            identityFile: host.identityFile,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        let machine = SurfaceMachineID.ssh(SSHTuiConnection(configuration: configuration).identityDigest)
        store.setTrusted(true, for: machine)

        let manager = TabManager(sshClipboardWriteTrustStore: store)
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        let firstLayout = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0, content: .pane(4)
        )
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1, name: "main", width: 80, height: 24, layout: firstLayout
        )
        connection.windowOrder = [1]
        connection.activePaneByWindow[1] = 4
        let sessionMirror = RemoteTmuxSessionMirror(
            host: host,
            sessionName: "work",
            connection: connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }

        let windowMirror = try #require(sessionMirror.windowMirrorByWindowId[1])
        let firstPanel = try #require(windowMirror.panel(forPane: 4))
        #expect(firstPanel.surface.allowsRemoteClipboardWrites)
        #expect(workspace.sshClipboardMachine(
            for: firstPanel.id,
            ownership: SSHClipboardWriteSurfaceOwnershipIndex(projections: [], pendingRestores: [])
        ) == machine)
        #expect(workspace.sshClipboardMachine(
            for: windowMirror.panelId,
            ownership: SSHClipboardWriteSurfaceOwnershipIndex(projections: [], pendingRestores: [])
        ) == machine)

        let splitLayout = RemoteTmuxLayoutNode(
            width: 80,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 0, y: 0, content: .pane(4)),
                RemoteTmuxLayoutNode(width: 40, height: 24, x: 40, y: 0, content: .pane(5)),
            ])
        )
        windowMirror.apply(window: RemoteTmuxWindow(
            id: 1, name: "main", width: 80, height: 24, layout: splitLayout
        ))

        let newPanel = try #require(windowMirror.panel(forPane: 5))
        #expect(newPanel.surface.allowsRemoteClipboardWrites)

        // Keep only the mirror ownership: wrapper removal must not strand the
        // original or later split pane's grant.
        workspace.panels.removeValue(forKey: windowMirror.panelId)
        store.setTrusted(false, for: machine)
        let ownership = SSHClipboardWriteSurfaceOwnershipIndex(projections: [], pendingRestores: [])
        #expect(workspace.sshClipboardMachine(for: windowMirror.panelId, ownership: ownership) == machine)
        workspace.applySSHClipboardWritePermission(for: machine, ownership: ownership)
        #expect(!firstPanel.surface.allowsRemoteClipboardWrites)
        #expect(!newPanel.surface.allowsRemoteClipboardWrites)
    }
}
