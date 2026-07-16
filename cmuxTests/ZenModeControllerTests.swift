import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("ZenModeController", .serialized)
@MainActor
final class ZenModeControllerTests {
    private let defaultsSuiteName: String
    private let defaults: UserDefaults

    init() {
        defaultsSuiteName = "ZenModeControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    @Test
    func entersAndRestoresOnlyStateItChanges() {
        let defaults = resetDefaults()
        defaults.set(1120.0, forKey: SessionContentWidthSettings.rememberedMaxWidthKey)
        let controller = ZenModeController(defaults: defaults)
        let windowID = UUID()

        let session = controller.begin(
            windowID: windowID,
            isSidebarVisible: true,
            isFullScreen: false
        )

        #expect(session == ZenModeController.Session(
            windowID: windowID,
            restoresSidebarVisibility: true,
            exitsFullScreen: true
        ))
        #expect(WorkspacePresentationModeSettings.isMinimal(defaults: defaults))
        #expect(defaults.double(forKey: SessionContentWidthSettings.maxWidthKey) == 1120)

        #expect(controller.end() == session)
        #expect(defaults.object(forKey: WorkspacePresentationModeSettings.modeKey) == nil)
        #expect(defaults.object(forKey: SessionContentWidthSettings.maxWidthKey) == nil)
    }

    @Test
    func preservesStateAlreadyMatchingZenMode() {
        let defaults = resetDefaults()
        defaults.set(
            WorkspacePresentationModeSettings.Mode.minimal.rawValue,
            forKey: WorkspacePresentationModeSettings.modeKey
        )
        defaults.set(760.0, forKey: SessionContentWidthSettings.maxWidthKey)
        let controller = ZenModeController(defaults: defaults)

        let session = controller.begin(
            windowID: UUID(),
            isSidebarVisible: false,
            isFullScreen: true
        )

        #expect(session?.restoresSidebarVisibility == false)
        #expect(session?.exitsFullScreen == false)
        _ = controller.end()
        #expect(WorkspacePresentationModeSettings.isMinimal(defaults: defaults))
        #expect(defaults.double(forKey: SessionContentWidthSettings.maxWidthKey) == 760)
    }

    @Test
    func doesNotOverwriteSettingsChangedWhileZenModeIsActive() {
        let defaults = resetDefaults()
        let controller = ZenModeController(defaults: defaults)
        _ = controller.begin(windowID: UUID(), isSidebarVisible: true, isFullScreen: false)

        defaults.set(
            WorkspacePresentationModeSettings.Mode.standard.rawValue,
            forKey: WorkspacePresentationModeSettings.modeKey
        )
        defaults.set(1400.0, forKey: SessionContentWidthSettings.maxWidthKey)
        _ = controller.end()

        #expect(!WorkspacePresentationModeSettings.isMinimal(defaults: defaults))
        #expect(defaults.double(forKey: SessionContentWidthSettings.maxWidthKey) == 1400)
    }

    @Test
    func restoresTemporaryGlobalSettingsAfterInterruptedSession() {
        let defaults = resetDefaults()
        let windowID = UUID()
        defaults.set(
            WorkspacePresentationModeSettings.Mode.standard.rawValue,
            forKey: WorkspacePresentationModeSettings.modeKey
        )
        defaults.set(
            SessionContentWidthSettings.noMaximumWidth,
            forKey: SessionContentWidthSettings.maxWidthKey
        )
        let interruptedController = ZenModeController(defaults: defaults)
        _ = interruptedController.begin(windowID: windowID, isSidebarVisible: true, isFullScreen: false)

        _ = ZenModeController(defaults: defaults)

        #expect(
            defaults.string(forKey: WorkspacePresentationModeSettings.modeKey) ==
                WorkspacePresentationModeSettings.Mode.standard.rawValue
        )
        #expect(
            defaults.double(forKey: SessionContentWidthSettings.maxWidthKey) ==
                SessionContentWidthSettings.noMaximumWidth
        )

        // A second startup crash before session restoration must not lose the
        // pending sidebar repair.
        let secondRecoveredController = ZenModeController(defaults: defaults)
        #expect(secondRecoveredController.consumeInterruptedSidebarVisibilityRecovery(windowID: windowID))
        #expect(!secondRecoveredController.consumeInterruptedSidebarVisibilityRecovery(windowID: windowID))
        #expect(!ZenModeController(defaults: defaults).consumeInterruptedSidebarVisibilityRecovery(windowID: windowID))
    }

    @Test
    func terminationReturnsWindowStateLedgerForSynchronousRestoration() {
        let defaults = resetDefaults()
        let controller = ZenModeController(defaults: defaults)
        let windowID = UUID()
        let session = controller.begin(windowID: windowID, isSidebarVisible: true, isFullScreen: false)

        #expect(controller.restoreForTermination() == session)
        #expect(defaults.object(forKey: WorkspacePresentationModeSettings.modeKey) == nil)
        #expect(defaults.object(forKey: SessionContentWidthSettings.maxWidthKey) == nil)
        #expect(!ZenModeController(defaults: defaults).consumeInterruptedSidebarVisibilityRecovery(windowID: windowID))
    }

    @Test
    func usesVSCodeZenModeShortcutAndPublishesItInSettings() {
        let shortcut = KeyboardShortcutSettings.Action.toggleZenMode.defaultShortcut

        #expect(shortcut.firstStroke == ShortcutStroke(
            key: "k",
            command: true,
            shift: false,
            option: false,
            control: false
        ))
        #expect(shortcut.secondStroke == ShortcutStroke(
            key: "z",
            command: false,
            shift: false,
            option: false,
            control: false
        ))
        #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(.toggleZenMode))
        #expect(ShortcutAction.settingsVisibleActions.contains(.toggleZenMode))
        #expect(ShortcutAction.toggleZenMode.defaultShortcut == CmuxSettings.StoredShortcut(
            first: CmuxSettings.ShortcutStroke(key: "k", command: true),
            second: CmuxSettings.ShortcutStroke(key: "z")
        ))
    }

    private func resetDefaults() -> UserDefaults {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}
