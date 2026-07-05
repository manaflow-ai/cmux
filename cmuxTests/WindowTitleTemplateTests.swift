import Foundation
import AppKit
import CmuxCore
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct WindowTitleTemplateTests {
    private let backupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test func resolvesWindowPlaceholdersAndPreservesUnknownPlaceholders() throws {
        let windowId = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let template = WindowTitleTemplate(
            rawValue: "[cmux:{windowToken}] {activeWorkspace} {activeDirectory} {windowId} {defaultTitle} {appName} {unknown}"
        )

        let resolved = template.resolved(context: WindowTitleTemplateContext(
            defaultTitle: "Fallback",
            activeWorkspace: "Build",
            activeDirectory: "/tmp/project",
            windowId: windowId,
            appName: "cmux"
        ))

        #expect(resolved == "[cmux:01234567] Build /tmp/project 01234567-89ab-cdef-0123-456789abcdef Fallback cmux {unknown}")
    }

    @Test func configuredTemplateTreatsBlankDefaultsValueAsDisabled() throws {
        let defaults = try isolatedDefaults()
        defaults.set("   \n", forKey: WindowTitleTemplate.userDefaultsKey)

        #expect(WindowTitleTemplate.configured(defaults: defaults) == nil)
    }

    @Test func resolverDoesNotExpandPlaceholdersInsideReplacementValues() throws {
        let windowId = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let template = WindowTitleTemplate(rawValue: "{activeWorkspace} {appName}")

        let resolved = template.resolved(context: WindowTitleTemplateContext(
            defaultTitle: "Fallback",
            activeWorkspace: "{windowId}",
            activeDirectory: "{windowToken}",
            windowId: windowId,
            appName: "cmux"
        ))

        #expect(resolved == "{windowId} cmux")
    }

    @Test func settingsFileStoreAppliesAppWindowTitleTemplate() throws {
        let defaults = UserDefaults.standard
        let keys = [
            WindowTitleTemplate.userDefaultsKey,
            backupsDefaultsKey,
            importedManagedDefaultsKey,
        ]
        let previousValues: [String: Any?] = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) }
        )
        defer {
            restore(previousValues, defaults: defaults)
        }
        keys.forEach { defaults.removeObject(forKey: $0) }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-window-title-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "app": {
            "windowTitleTemplate": "[cmux:{windowToken}] {activeWorkspace}"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        #expect(defaults.string(forKey: WindowTitleTemplate.userDefaultsKey) == "[cmux:{windowToken}] {activeWorkspace}")
    }

    @Test func settingsFileStoreAppliesWorkspaceAutoNamingAutomationSetting() throws {
        let defaults = UserDefaults.standard
        let workspaceAutoNamingKey = AutomationCatalogSection().workspaceAutoNaming.userDefaultsKey
        let keys = [
            workspaceAutoNamingKey,
            backupsDefaultsKey,
            importedManagedDefaultsKey,
        ]
        let previousValues: [String: Any?] = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) }
        )
        defer {
            restore(previousValues, defaults: defaults)
        }
        keys.forEach { defaults.removeObject(forKey: $0) }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-auto-naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "automation": {
            "workspaceAutoNaming": true
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        #expect(defaults.bool(forKey: workspaceAutoNamingKey))
    }

    @Test func settingsFileStoreAppliesAutoNamingAgentAutomationSetting() throws {
        let defaults = UserDefaults.standard
        let autoNamingAgentKey = AutomationCatalogSection().autoNamingAgent.userDefaultsKey
        let keys = [
            autoNamingAgentKey,
            backupsDefaultsKey,
            importedManagedDefaultsKey,
        ]
        let previousValues: [String: Any?] = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) }
        )
        defer {
            restore(previousValues, defaults: defaults)
        }
        keys.forEach { defaults.removeObject(forKey: $0) }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-auto-naming-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "automation": {
            "autoNamingAgent": "codex"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        #expect(defaults.string(forKey: autoNamingAgentKey) == "codex")
    }

    @MainActor
    @Test func selectedWorkspaceDirectoryChangeRefreshesActiveDirectoryTitle() throws {
        let defaults = UserDefaults.standard
        let previousValues: [String: Any?] = [
            WindowTitleTemplate.userDefaultsKey: defaults.object(forKey: WindowTitleTemplate.userDefaultsKey),
        ]
        defer {
            restore(previousValues, defaults: defaults)
        }
        defaults.set("[cmux:{windowToken}] {activeDirectory}", forKey: WindowTitleTemplate.userDefaultsKey)

        let windowId = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let manager = TabManager(
            initialWorkspaceTitle: "Build",
            initialWorkingDirectory: "/tmp/old",
            autoWelcomeIfNeeded: false
        )
        manager.windowId = windowId

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        manager.window = window
        defer {
            manager.window = nil
            window.close()
        }

        manager.refreshWindowTitle()
        #expect(window.title == "[cmux:01234567] /tmp/old")

        let workspace = try #require(manager.tabs.first)
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.updatePanelDirectory(panelId: panelId, directory: "/tmp/new"))
        manager.workspaceCurrentDirectoryDidChange(workspaceId: workspace.id)
        #expect(window.title == "[cmux:01234567] /tmp/new")
    }

    @MainActor
    @Test func remoteWorkspaceTitleUsesReportedDirectoryForActiveDirectoryTemplate() throws {
        let defaults = UserDefaults.standard
        let previousValues: [String: Any?] = [
            WindowTitleTemplate.userDefaultsKey: defaults.object(forKey: WindowTitleTemplate.userDefaultsKey),
        ]
        defer {
            restore(previousValues, defaults: defaults)
        }
        defaults.set("[cmux:{windowToken}] {activeDirectory}", forKey: WindowTitleTemplate.userDefaultsKey)

        let windowId = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let manager = TabManager(
            initialWorkspaceTitle: "Remote",
            initialWorkingDirectory: localDirectory,
            autoWelcomeIfNeeded: false
        )
        manager.windowId = windowId
        let workspace = try #require(manager.selectedWorkspace)
        let remotePanelId = try #require(workspace.focusedPanelId)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        manager.window = window
        defer {
            manager.window = nil
            window.close()
        }

        #expect(workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory))
        manager.refreshWindowTitle()
        #expect(window.title == "[cmux:01234567] \(localDirectory)")

        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "seepine@192.168.5.20",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: "relay-\(UUID().uuidString)",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-issue-7268-window-title.sock",
                terminalStartupCommand: sshCommand
            ),
            autoConnect: false
        )
        #expect(window.title == "[cmux:01234567]")

        workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory)
        #expect(window.title == "[cmux:01234567]")

        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        #expect(window.title == "[cmux:01234567] \(remoteDirectory)")

        workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory)
        #expect(window.title == "[cmux:01234567] \(remoteDirectory)")

        workspace.disconnectRemoteConnection()
        manager.refreshWindowTitle()
        #expect(window.title == "[cmux:01234567]")
    }

    @MainActor
    @Test func remoteWorkspaceTitleUsesFocusedLocalTerminalDirectoryForActiveDirectoryTemplate() throws {
        let defaults = UserDefaults.standard
        let previousValues: [String: Any?] = [
            WindowTitleTemplate.userDefaultsKey: defaults.object(forKey: WindowTitleTemplate.userDefaultsKey),
        ]
        defer {
            restore(previousValues, defaults: defaults)
        }
        defaults.set("[cmux:{windowToken}] {activeDirectory}", forKey: WindowTitleTemplate.userDefaultsKey)

        let windowId = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let initialDirectory = "/Users/alice/development"
        let localTerminalDirectory = "/Users/alice/local-tools"
        let remoteDirectory = "/home/seepine/workspace"
        let manager = TabManager(
            initialWorkspaceTitle: "Remote",
            initialWorkingDirectory: initialDirectory,
            autoWelcomeIfNeeded: false
        )
        manager.windowId = windowId
        let workspace = try #require(manager.selectedWorkspace)
        let remotePanelId = try #require(workspace.focusedPanelId)
        let localPanel = try #require(workspace.newTerminalSplit(
            from: remotePanelId,
            orientation: .horizontal,
            focus: false
        ))
        #expect(workspace.updatePanelDirectory(panelId: localPanel.id, directory: localTerminalDirectory))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        manager.window = window
        defer {
            manager.window = nil
            window.close()
        }

        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "seepine@192.168.5.20",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: "relay-\(UUID().uuidString)",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-issue-7268-local-window-title.sock",
                terminalStartupCommand: "ssh seepine@192.168.5.20"
            ),
            autoConnect: false
        )
        #expect(workspace.isRemoteTerminalSurface(remotePanelId))
        #expect(!workspace.isRemoteTerminalSurface(localPanel.id))

        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        workspace.focusPanel(localPanel.id)
        #expect(workspace.presentedCurrentDirectory == localTerminalDirectory)
        manager.refreshWindowTitle()
        #expect(window.title == "[cmux:01234567] \(localTerminalDirectory)")

        workspace.focusPanel(remotePanelId)
        manager.refreshWindowTitle()
        #expect(window.title == "[cmux:01234567] \(remoteDirectory)")
    }

    @MainActor
    @Test func remoteWorkspacePresentedDirectoryFallsBackToTrustedRemoteWhenAgentFocused() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: sshCommand
        )
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "seepine@192.168.5.20",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: "relay-\(UUID().uuidString)",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-issue-7268-agent-focus.sock",
                terminalStartupCommand: sshCommand
            ),
            autoConnect: false
        )
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)

        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let agentPanel = try #require(workspace.newAgentSessionSurface(
            inPane: paneId,
            rendererKind: .react,
            workingDirectory: nil,
            focus: true
        ))
        #expect(workspace.panelDirectories[agentPanel.id] == remoteDirectory)
        #expect(workspace.reportedPanelDirectory(panelId: agentPanel.id) == remoteDirectory)
        let agentSnapshot = try #require(workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == agentPanel.id })
        #expect(agentSnapshot.directoryIsTrustedRemoteReport == true)

        #expect(workspace.terminalPanel(for: agentPanel.id) == nil)
        #expect(workspace.focusedPanelId == agentPanel.id)
        #expect(workspace.presentedCurrentDirectory == remoteDirectory)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "cmux.WindowTitleTemplateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func restore(_ values: [String: Any?], defaults: UserDefaults) {
        for (key, value) in values {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
