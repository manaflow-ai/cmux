import CmuxCore
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceHostLabelWindowTitleTests {
    @Test("SSH workspaces show their host after the title and refresh title chrome when it changes")
    func sshWorkspaceWindowTitleCarriesHost() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "build"))
        #expect(workspace.hostLabel == .local)
        #expect(manager.resolvedWorkspaceWindowTitle(for: workspace) == "build")

        var notifiedWorkspaceIds: [UUID] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .workspaceTitleDidChange,
            object: manager,
            queue: nil
        ) { notification in
            if let workspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID {
                notifiedWorkspaceIds.append(workspaceId)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        workspace.remoteConfiguration = Self.configuration(destination: "leo@big-red", relayPort: nil)
        #expect(workspace.hostLabel.kind == .ssh)
        #expect(workspace.hostLabel.label == "big-red")
        #expect(manager.resolvedWorkspaceWindowTitle(for: workspace) == "build · big-red")
        #expect(manager.resolvedWorkspaceDisplayTitle(for: workspace) == "build")
        #expect(notifiedWorkspaceIds == [workspace.id])

        // A relay or lease change keeps the host, so title chrome is left alone.
        workspace.remoteConfiguration = Self.configuration(destination: "leo@big-red", relayPort: 64_010)
        #expect(notifiedWorkspaceIds == [workspace.id])

        workspace.remoteConfiguration = nil
        #expect(manager.resolvedWorkspaceWindowTitle(for: workspace) == "build")
        #expect(notifiedWorkspaceIds == [workspace.id, workspace.id])
    }

    @Test("a title that already names the host is not repeated")
    func titleNamingHostIsNotRepeated() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "agents @big-red"))
        workspace.remoteConfiguration = Self.configuration(destination: "big-red", relayPort: nil)
        #expect(manager.resolvedWorkspaceWindowTitle(for: workspace) == "agents @big-red")
    }

    private static func configuration(destination: String, relayPort: Int?) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: destination,
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
    }
}
