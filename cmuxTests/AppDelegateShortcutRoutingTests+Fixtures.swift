import AppKit
import CmuxCanvasUI
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CanvasViewportSpy: CanvasViewportControlling {
    var revealedPanelIds: [UUID] = []
    var overviewToggleCount = 0
    var modelDidChangeCount = 0
    var resetZoomCount = 0
    var currentMagnification: CGFloat = 1
    var currentCenterInCanvas: CGPoint = .zero

    func revealPane(_ panelId: UUID, animated: Bool) { revealedPanelIds.append(panelId) }
    func toggleOverview() { overviewToggleCount += 1 }
    func zoom(by factor: CGFloat) {}
    func resetZoom() { resetZoomCount += 1 }
    func setViewport(center: CGPoint, magnification: CGFloat?) {}
    func modelDidChangeExternally(animated: Bool) { modelDidChangeCount += 1 }
}

@MainActor
extension AppDelegateShortcutRoutingTests {
    func makeKeyEvent(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }
}

#if DEBUG
@MainActor
extension AppDelegateOptionDigitShortcutRoutingTests {
    func withIsolatedShortcutRoutingState(_ body: () async throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let defaults = UserDefaults.standard
            let chiefEnabledKey = ChiefCatalogSection().enabled.userDefaultsKey
            let originalChiefEnabled = defaults.object(forKey: chiefEnabledKey)
            // These fixtures number ordinary terminal workspaces from index zero.
            // Home is a separate persistent group anchor when Chief is enabled.
            ChiefSettings.setEnabled(false, in: defaults)
            defer {
                if let originalChiefEnabled {
                    defaults.set(originalChiefEnabled, forKey: chiefEnabledKey)
                } else {
                    defaults.removeObject(forKey: chiefEnabledKey)
                }
            }
            let actionsWithPersistedShortcut = Set(
                KeyboardShortcutSettings.Action.allCases.filter {
                    UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
                }
            )
            let savedShortcutsByAction = Dictionary(
                uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                    (action, KeyboardShortcutSettings.shortcut(for: action))
                }
            )
            KeyboardShortcutRecorderActivity.resetForTesting()
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
            let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
                prefix: "cmux-option-digit-shortcut-routing"
            )
            KeyboardShortcutSettings.resetAll()
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()

            defer {
                KeyboardShortcutRecorderActivity.resetForTesting()
                AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
                KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
                for action in KeyboardShortcutSettings.Action.allCases {
                    if actionsWithPersistedShortcut.contains(action),
                       let savedShortcut = savedShortcutsByAction[action] {
                        KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
                    } else {
                        KeyboardShortcutSettings.resetShortcut(for: action)
                    }
                }
                AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
            }

            try await body()
        }
    }
}
#endif
