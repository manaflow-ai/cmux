import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct JumpToLastPromptTests {
    private typealias Target = AppDelegate.LastPromptTarget

    private static func target(_ seconds: TimeInterval, workspace: UUID = UUID(), panel: UUID = UUID()) -> Target {
        Target(workspaceId: workspace, panelId: panel, submittedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func newestIsNilWithoutCandidates() {
        #expect(Target.newest(in: []) == nil)
    }

    @Test func newestPicksTheMostRecentSubmit() {
        let older = Self.target(100)
        let newest = Self.target(300)
        let middle = Self.target(200)

        #expect(Target.newest(in: [older, newest, middle]) == newest)
        #expect(Target.newest(in: [middle, older, newest]) == newest)
    }

    /// The jump tries targets in this order, so a window that cannot take focus
    /// falls through to the next most recent prompt instead of a beep.
    @Test func newestFirstOrdersEveryCandidateFromTheMostRecentSubmit() {
        let older = Self.target(100)
        let newest = Self.target(300)
        let middle = Self.target(200)

        #expect(Target.newestFirst([older, newest, middle]) == [newest, middle, older])
        #expect(Target.newestFirst([older, newest, middle]).first == Target.newest(in: [middle, older, newest]))
    }

    @Test func equalSubmitTimesResolveTheSameWayInAnyOrder() throws {
        let lowWorkspace = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highWorkspace = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let a = Self.target(100, workspace: lowWorkspace)
        let b = Self.target(100, workspace: highWorkspace)

        #expect(Target.newest(in: [a, b]) == a)
        #expect(Target.newest(in: [b, a]) == a)
    }

    @Test func workspaceOffersOnlyLivePanelsWithAPrompt() throws {
        let workspace = Workspace()
        let livePanel = try #require(workspace.focusedPanelId)
        let closedPanel = UUID()
        workspace.panelPrompts[livePanel] = SidebarPanelPromptState(
            message: "live",
            submittedAt: Date(timeIntervalSince1970: 100)
        )
        workspace.panelPrompts[closedPanel] = SidebarPanelPromptState(
            message: "gone",
            submittedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(workspace.lastPromptTargets == [
            Target(workspaceId: workspace.id, panelId: livePanel, submittedAt: Date(timeIntervalSince1970: 100)),
        ])
    }

    @Test func workspaceWithoutPromptsOffersNothing() {
        #expect(Workspace().lastPromptTargets.isEmpty)
    }

    @Test func newestPromptWinsAcrossWorkspaces() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let firstPanel = try #require(first.focusedPanelId)
        let secondPanel = try #require(second.focusedPanelId)
        first.panelPrompts[firstPanel] = SidebarPanelPromptState(
            message: "older",
            submittedAt: Date(timeIntervalSince1970: 100)
        )
        second.panelPrompts[secondPanel] = SidebarPanelPromptState(
            message: "newer",
            submittedAt: Date(timeIntervalSince1970: 200)
        )

        let picked = Target.newest(in: manager.tabs.flatMap { $0.lastPromptTargets })

        #expect(picked?.workspaceId == second.id)
        #expect(picked?.panelId == secondPanel)
    }

    /// Cmd+Shift+B was Open Browser's default before it moved to Cmd+Shift+L.
    /// A user who bound it back keeps it: the newer jump default yields in
    /// the key handler and the View menu instead of stealing the stroke.
    @Test func explicitBindingOnCommandShiftBOutranksTheJumpDefault() throws {
        let jump = KeyboardShortcutSettings.Action.jumpToLastPrompt
        let commandShiftB = jump.defaultShortcut
        let settingsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-jump-last-prompt-\(UUID().uuidString).json", isDirectory: false)
        try """
        { "shortcuts": { "bindings": { "openBrowser": "cmd+shift+b" } } }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let isolatedActions: [KeyboardShortcutSettings.Action] = [jump, .openBrowser]
        let savedDefaults = isolatedActions.map { defaults.object(forKey: $0.defaultsKey) }
        isolatedActions.forEach { defaults.removeObject(forKey: $0.defaultsKey) }
        let originalStore = KeyboardShortcutSettings.settingsFileStore
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalStore
            for (action, saved) in zip(isolatedActions, savedDefaults) {
                if let saved {
                    defaults.set(saved, forKey: action.defaultsKey)
                } else {
                    defaults.removeObject(forKey: action.defaultsKey)
                }
            }
            try? FileManager.default.removeItem(at: settingsFileURL)
        }

        _ = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cmux-jump-last-prompt-empty")
        #expect(KeyboardShortcutSettings.shortcut(for: jump) == commandShiftB)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        #expect(KeyboardShortcutSettings.shortcut(for: .openBrowser) == commandShiftB)
        #expect(KeyboardShortcutSettings.shortcut(for: jump).isUnbound)
        #expect(KeyboardShortcutSettings.menuShortcut(for: jump).isUnbound)

        defaults.set(try JSONEncoder().encode(commandShiftB), forKey: jump.defaultsKey)
        #expect(KeyboardShortcutSettings.shortcut(for: jump) == commandShiftB)
    }
}
