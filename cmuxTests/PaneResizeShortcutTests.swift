import AppKit
import Bonsplit
import struct CmuxSettings.AppCatalogSection
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Pane resize shortcuts", .serialized)
@MainActor
struct PaneResizeShortcutTests {
    @Test(arguments: ["left", "right", "up", "down"])
    func configuredShortcutAndRepeatMoveDivider(direction: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let delegate = try #require(AppDelegate.shared)
            let action = try #require(KeyboardShortcutSettings.Action(rawValue: "resize-pane-\(direction)"))
            let originalStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "pane-resize")
            let defaults = UserDefaults.standard
            let originalShortcut = defaults.object(forKey: action.defaultsKey)
            let originalStep = defaults.object(forKey: "paneResizeStepPixels")
            defer {
                if let originalShortcut { defaults.set(originalShortcut, forKey: action.defaultsKey) }
                else { defaults.removeObject(forKey: action.defaultsKey) }
                if let originalStep { defaults.set(originalStep, forKey: "paneResizeStepPixels") }
                else { defaults.removeObject(forKey: "paneResizeStepPixels") }
                KeyboardShortcutSettings.settingsFileStore = originalStore
            }

            let windowId = delegate.createMainWindow()
            let window = try #require(delegate.mainWindow(for: windowId))
            defer { window.performClose(nil) }
            let manager = try #require(delegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let first = try #require(workspace.focusedPanelId)
            let horizontal = direction == "left" || direction == "right"
            let second = try #require(workspace.newTerminalSplit(
                from: first,
                orientation: horizontal ? .horizontal : .vertical
            ))
            let negative = direction == "left" || direction == "up"
            let focused = negative ? second.id : first
            workspace.focusPanel(focused)
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let controller = workspace.bonsplitController
            controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1000, height: 1000))
            let split = try rootSplit(controller)
            #expect(controller.setDividerPosition(0.5, forSplit: try #require(UUID(uuidString: split.id))))
            workspace.didProgrammaticallyChangeSplitGeometry()

            let shortcut = StoredShortcut(key: "y", command: true, shift: true, option: false, control: true)
            KeyboardShortcutSettings.setShortcut(shortcut, for: action)
            defaults.set(25, forKey: "paneResizeStepPixels")
            let sign = negative ? -1.0 : 1.0
            for index in 1...3 {
                let event = try keyEvent(in: window, repeat: index > 1)
                #expect(delegate.debugHandleCustomShortcut(event: event))
                let updated = try rootSplit(controller)
                #expect(abs(updated.dividerPosition - (0.5 + sign * 0.025 * Double(index))) < 0.000_001)
                #expect(workspace.focusedPanelId == focused)
                try expectCachedFramesMatch(workspace)
            }

            // The step changes on the next event without a restart.
            defaults.set(50, forKey: "paneResizeStepPixels")
            #expect(delegate.debugHandleCustomShortcut(event: try keyEvent(in: window, repeat: true)))
            #expect(abs(try rootSplit(controller).dividerPosition - (0.5 + sign * 0.125)) < 0.000_001)

            KeyboardShortcutSettings.setShortcut(.unbound, for: action)
            let before = try rootSplit(controller).dividerPosition
            _ = delegate.debugHandleCustomShortcut(event: try keyEvent(in: window, repeat: false))
            #expect(try rootSplit(controller).dividerPosition == before)
        }
    }

    @Test(arguments: [1, 20, 200])
    func settingsFileAppliesStepAndRemapping(step: Int) throws {
        try withSettings("""
        {"app":{"paneResizeStepPixels":\(step)},
         "shortcuts":{"bindings":{"resize-pane-left":"cmd+ctrl+y","resize-pane-right":null}}}
        """) { store, defaults in
            let left = try #require(KeyboardShortcutSettings.Action(rawValue: "resize-pane-left"))
            let right = try #require(KeyboardShortcutSettings.Action(rawValue: "resize-pane-right"))
            #expect(defaults.integer(forKey: "paneResizeStepPixels") == step)
            #expect(store.override(for: left) == StoredShortcut(key: "y", command: true, shift: false, option: false, control: true))
            #expect(store.override(for: right) == .unbound)
        }
    }

    @Test(arguments: ["0", "201", "-1", "1.5", "true", "\"bad\""])
    func invalidStepDoesNotDiscardOtherAppSettings(value: String) throws {
        try withSettings("""
        {"app":{"paneResizeStepPixels":\(value),"confirmQuit":"never"}}
        """) { _, defaults in
            #expect(defaults.object(forKey: "paneResizeStepPixels") == nil)
            #expect(defaults.string(forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey) == "never")
        }
    }

    private func withSettings(
        _ json: String,
        body: (KeyboardShortcutSettingsFileStore, UserDefaults) throws -> Void
    ) throws {
        let suite = "PaneResizeShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        try json.write(to: file, atomically: true, encoding: .utf8)
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: file.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            userDefaults: defaults,
            startWatching: false
        )
        try body(store, defaults)
    }

    private func rootSplit(_ controller: BonsplitController) throws -> ExternalSplitNode {
        guard case .split(let split) = controller.treeSnapshot() else {
            throw TestFailure.missingSplit
        }
        return split
    }

    private func keyEvent(in window: NSWindow, repeat isRepeat: Bool) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: [.command, .control, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "y", charactersIgnoringModifiers: "y",
            isARepeat: isRepeat, keyCode: 16
        ))
    }

    private func expectCachedFramesMatch(_ workspace: Workspace) throws {
        let cached = try #require(workspace.tmuxLayoutSnapshot)
        let live = workspace.bonsplitController.layoutSnapshot()
        #expect(cached.panes.count == live.panes.count)
        for pane in live.panes {
            let previous = try #require(cached.panes.first { $0.paneId == pane.paneId })
            #expect(previous.frame == pane.frame)
        }
    }

    private enum TestFailure: Error { case missingSplit }
}
