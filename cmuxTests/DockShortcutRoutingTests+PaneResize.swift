import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension DockShortcutRoutingTests {
    @Test("Pane resizing and key repeat target the Dock without resizing the workspace")
    @MainActor
    func paneResizeTargetsFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let action = try #require(
                    KeyboardShortcutSettings.Action(rawValue: "resize-pane-left")
                )
                let defaults = UserDefaults.standard
                let originalStep = defaults.object(forKey: "paneResizeStepPixels")
                defaults.set(20, forKey: "paneResizeStepPixels")
                defer {
                    if let originalStep { defaults.set(originalStep, forKey: "paneResizeStepPixels") }
                    else { defaults.removeObject(forKey: "paneResizeStepPixels") }
                }
                let first = try #require(harness.dock.newSurface(
                    kind: .terminal, inPane: harness.rootPane, focus: true
                ))
                let focused = try #require(harness.dock.newSplit(
                    kind: .terminal, orientation: .horizontal, insertFirst: false,
                    sourcePanelId: first, focus: true
                ))
                let controller = harness.dock.bonsplitController
                controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1000, height: 500))
                let mainBefore = harness.mainWorkspace.bonsplitController.treeSnapshot()
                let split = try #require(Self.splitNodes(in: controller.treeSnapshot()).first)
                let splitId = try #require(UUID(uuidString: split.id))
                #expect(controller.setDividerPosition(0.5, forSplit: splitId))
                KeyboardShortcutSettings.setShortcut(action.defaultShortcut, for: action)
                for index in 1...3 {
                    #expect(Self.dispatch(action.defaultShortcut, in: harness, isARepeat: index > 1))
                    let updated = try #require(Self.splitNodes(in: controller.treeSnapshot()).first)
                    #expect(abs(updated.dividerPosition - (0.5 - 0.02 * Double(index))) < 0.000_001)
                    #expect(harness.mainWorkspace.bonsplitController.treeSnapshot() == mainBefore)
                    #expect(harness.dock.focusedPanelId == focused)
                }
            }
        }
    }

}
