import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
struct AgentSessionWebRendererTests {
    @MainActor
    private func withAgentChatUIFlag<T>(_ enabled: Bool, _ body: () throws -> T) throws -> T {
        let flags = CmuxFeatureFlags.shared
        let definition = try #require(CmuxFeatureFlags.allFlags.first { $0.key == "agent-chat-ui-enabled-release" })
        let previous = flags.overrideValue(for: definition)
        flags.setOverride(enabled, for: definition)
        defer { flags.setOverride(previous, for: definition) }
        return try body()
    }

    @MainActor
    private func withBrowserDisabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey) as? Bool
        let hadPrevious = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey) != nil
        BrowserAvailabilitySettings.setDisabled(true)
        defer {
            if hadPrevious, let previous {
                BrowserAvailabilitySettings.setDisabled(previous)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
                NotificationCenter.default.post(name: BrowserAvailabilitySettings.didChangeNotification, object: nil)
            }
        }
        try body()
    }

    @Test
    func testTrustedShellURLAcceptsOnlyMatchingFileURL() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expected = directory.appendingPathComponent("agent-session.html")
        let equivalent = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("agent-session.html")
        let otherBundledFile = directory.appendingPathComponent("diff-viewer.html")

        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(expected, expected: expected))
        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(equivalent, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(otherBundledFile, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(URL(string: "https://example.com"), expected: expected))
    }

    @MainActor
    @Test func performNewAgentChatActionUsesNativeSessionWhenBrowserSurfacesAreDisabled() throws {
        try withAgentChatUIFlag(true) {
            try withBrowserDisabled {
                let tabManager = TabManager()
                let didStart = AppDelegate().performNewAgentChatAction(
                    tabManager: tabManager,
                    agentChat: .default,
                    globalConfigPath: nil,
                    preferredWindow: nil
                )

                #expect(didStart)
                #expect(tabManager.tabs.count == 2)
                let workspace = try #require(tabManager.selectedWorkspace)
                #expect(workspace.customTitle == "Agent Chat")
                let panel = try #require(workspace.panels.values.first as? AgentSessionPanel)
                #expect(panel.rendererKind == .react)
                #expect(panel.currentProviderID == .codex)
            }
        }
    }

    @MainActor
    @Test func initialAgentSessionRegistersItsWorkingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.path
        let workspace = Workspace(
            workingDirectory: "  \(directory)  ",
            initialSurface: .agentSession
        )
        let panel = try #require(workspace.panels.values.first as? AgentSessionPanel)

        #expect(panel.workingDirectory == directory)
        #expect(workspace.panelDirectories[panel.id] == directory)
    }
}
