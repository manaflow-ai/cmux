import CmuxCommandPalette
import CmuxFoundation
import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Sparkle
import CmuxUpdater
// Selective imports: the app target also defines AppIconMode/StoredShortcut/etc.,
// so a blanket `import CmuxSettings` here makes those names ambiguous. Import only
// the settings symbols this file needs.
import struct CmuxSettings.AppCatalogSection
import struct CmuxSettings.QuitConfirmationStore
import struct CmuxSettings.CommandPaletteSettingsStore
import enum CmuxSettings.ConfirmQuitMode
import struct CmuxSettings.SettingCatalog
import struct CmuxSettings.UserDefaultsSettingsClient
import protocol CmuxSidebar.FeedKeyboardFocusResponder

#if canImport(cmux_DEV)
@testable import cmux_DEV
// The app target still declares legacy duplicates of these CmuxSettings
// value types; with CmuxSettings imported unconditionally the names are
// ambiguous. These tests exercise the app-side paths, so pin the app types.
private typealias StoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias StoredShortcut = cmux.StoredShortcut
#endif

final class SplitShortcutTransientFocusGuardTests: XCTestCase {
    func testSuppressesWhenFirstResponderFallsBackAndHostedViewIsTiny() {
        XCTAssertTrue(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 79, height: 0),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }

    func testSuppressesWhenFirstResponderFallsBackAndHostedViewIsDetached() {
        XCTAssertTrue(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 1051.5, height: 1207),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: false
            )
        )
    }

    func testAllowsWhenFirstResponderFallsBackButGeometryIsHealthy() {
        XCTAssertFalse(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 1051.5, height: 1207),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }

    func testAllowsWhenFirstResponderIsTerminalEvenIfViewIsTiny() {
        XCTAssertFalse(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: false,
                hostedSize: CGSize(width: 79, height: 0),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }
}

final class CommandEquivalentTransientFocusRepairTests: XCTestCase {
    func testRepairsCommandEquivalentWhenFirstResponderFallsBackToWindow() {
        XCTAssertTrue(
            shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: [.command],
                responderIsWindow: true,
                responderHasViableKeyRoutingOwner: false
            )
        )
    }

    func testRepairsCommandEquivalentWhenResponderHasNoViableOwner() {
        XCTAssertTrue(
            shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: [.command],
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: false
            )
        )
    }

    func testDoesNotRepairCommandEquivalentWhenLiveResponderDiffersFromSelectedPane() {
        XCTAssertFalse(
            shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: [.command],
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: true
            )
        )
    }

    func testDoesNotRepairCommandEquivalentWhenResponderHasViableOwner() {
        XCTAssertFalse(
            shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: [.command],
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: true
            )
        )
    }

    func testIgnoresNonCommandEvents() {
        XCTAssertFalse(
            shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: [],
                responderIsWindow: true,
                responderHasViableKeyRoutingOwner: false
            )
        )
    }
}

final class ReactGrabShortcutRouteTests: XCTestCase {
    func testFocusedBrowserRoutesDirectlyWithoutPasteback() {
        let browserId = UUID()
        let terminalId = UUID()

        let route = resolveReactGrabShortcutRoute(
            panels: [
                ReactGrabShortcutPanelSnapshot(id: terminalId, panelType: .terminal, isFocused: false),
                ReactGrabShortcutPanelSnapshot(id: browserId, panelType: .browser, isFocused: true),
            ]
        )

        XCTAssertEqual(
            route,
            ReactGrabShortcutRoute(browserPanelId: browserId, returnTerminalPanelId: nil)
        )
    }

    func testFocusedTerminalRoutesToOnlyBrowserAndRemembersPastebackTarget() {
        let browserId = UUID()
        let terminalId = UUID()

        let route = resolveReactGrabShortcutRoute(
            panels: [
                ReactGrabShortcutPanelSnapshot(id: terminalId, panelType: .terminal, isFocused: true),
                ReactGrabShortcutPanelSnapshot(id: browserId, panelType: .browser, isFocused: false),
            ]
        )

        XCTAssertEqual(
            route,
            ReactGrabShortcutRoute(browserPanelId: browserId, returnTerminalPanelId: terminalId)
        )
    }

    func testFocusedTerminalDoesNotRouteWhenMultipleBrowsersExist() {
        let route = resolveReactGrabShortcutRoute(
            panels: [
                ReactGrabShortcutPanelSnapshot(id: UUID(), panelType: .terminal, isFocused: true),
                ReactGrabShortcutPanelSnapshot(id: UUID(), panelType: .browser, isFocused: false),
                ReactGrabShortcutPanelSnapshot(id: UUID(), panelType: .browser, isFocused: false),
            ]
        )

        XCTAssertNil(route)
    }

    func testFocusedTerminalDoesNotRouteWithoutBrowser() {
        let route = resolveReactGrabShortcutRoute(
            panels: [
                ReactGrabShortcutPanelSnapshot(id: UUID(), panelType: .terminal, isFocused: true),
            ]
        )

        XCTAssertNil(route)
    }
}


@MainActor
final class ReactGrabPastebackTargetTests: XCTestCase {
    func testPrefersExplicitTerminalTargetWhenBrowserPanelIsFocused() {
        let workspace = Workspace(title: "Tests")
        guard let terminalId = workspace.focusedPanelId else {
            XCTFail("Expected initial terminal panel")
            return
        }
        guard let browserPanel = workspace.newBrowserSplit(
            from: terminalId,
            orientation: .horizontal
        ) else {
            XCTFail("Expected browser split panel")
            return
        }

        workspace.focusPanel(browserPanel.id)

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)
        XCTAssertEqual(
            AppDelegate.resolveTerminalPanelForTextSend(
                in: workspace,
                preferredPanelId: terminalId
            )?.id,
            terminalId
        )
    }

    func testDoesNotFallbackWhenPreferredTerminalTargetIsMissing() {
        let workspace = Workspace(title: "Tests")
        guard let terminalId = workspace.focusedPanelId,
              let browserPanel = workspace.newBrowserSplit(
                from: terminalId,
                orientation: .horizontal
              ) else {
            XCTFail("Expected initial workspace split")
            return
        }

        workspace.focusPanel(browserPanel.id)

        XCTAssertNil(
            AppDelegate.resolveTerminalPanelForTextSend(
                in: workspace,
                preferredPanelId: UUID()
            )
        )
    }

    func testShortcutStillRoutesTerminalPastebackWhenWebViewFocusIsDeferred() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalId = workspace.focusedPanelId,
              let browserPanel = workspace.newBrowserSplit(
                from: terminalId,
                orientation: .horizontal
              ) else {
            XCTFail("Expected initial workspace with terminal and browser split")
            return
        }

        workspace.focusPanel(terminalId)

        XCTAssertTrue(manager.toggleReactGrabFromCurrentFocus())
        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)
        XCTAssertEqual(browserPanel.pendingReactGrabReturnTargetPanelId, terminalId)
    }

    func testShortcutClearsSplitZoomBeforeRoutingToBrowserPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalId = workspace.focusedPanelId,
              let browserPanel = workspace.newBrowserSplit(
                from: terminalId,
                orientation: .horizontal
              ) else {
            XCTFail("Expected initial workspace with terminal and browser split")
            return
        }

        workspace.focusPanel(terminalId)
        XCTAssertTrue(workspace.toggleSplitZoom(panelId: terminalId))
        XCTAssertTrue(workspace.bonsplitController.isSplitZoomed)

        XCTAssertTrue(manager.toggleReactGrabFromCurrentFocus())
        XCTAssertFalse(workspace.bonsplitController.isSplitZoomed)
        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)
        XCTAssertEqual(browserPanel.pendingReactGrabReturnTargetPanelId, terminalId)
    }
}


final class FullScreenShortcutTests: XCTestCase {
    func testMatchesCommandControlF() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testMatchesCommandControlFFromKeyCodeWhenCharsAreUnavailable() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "",
                keyCode: 3,
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testDoesNotFallbackToANSIWhenLayoutTranslationReturnsNonFCharacter() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "",
                keyCode: 3,
                layoutCharacterProvider: { _, _ in "u" }
            )
        )
    }

    func testMatchesCommandControlFWhenCommandAwareLayoutTranslationProvidesF() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "",
                keyCode: 3,
                layoutCharacterProvider: { _, modifierFlags in
                    modifierFlags.contains(.command) ? "f" : "u"
                }
            )
        )
    }

    func testMatchesCommandControlFWhenCharsAreControlSequence() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "\u{06}",
                keyCode: 3,
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testRejectsPhysicalFWhenCharacterRepresentsDifferentLayoutKey() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "u",
                keyCode: 3
            )
        )
    }

    func testIgnoresCapsLockForCommandControlF() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control, .capsLock],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsWhenControlIsMissing() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsAdditionalModifiers() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control, .shift],
                chars: "f",
                keyCode: 3
            )
        )
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control, .option],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsWhenCommandIsMissing() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.control],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsNonFKey() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "r",
                keyCode: 15
            )
        )
    }
}


@MainActor final class CommandPaletteKeyboardNavigationTests: XCTestCase {
    func testArrowKeysMoveSelectionWithoutModifiers() {
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [],
                chars: "",
                keyCode: 125
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [],
                chars: "",
                keyCode: 126
            ),
            -1
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.shift],
                chars: "",
                keyCode: 125
            )
        )
    }

    func testControlLetterNavigationSupportsPrintableAndControlCharsForNPOnly() {
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "n",
                keyCode: 45
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0e}",
                keyCode: 45
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "p",
                keyCode: 35
            ),
            -1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{10}",
                keyCode: 35
            ),
            -1
        )
    }

    func testNavigationIgnoresCapsLockModifier() {
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.capsLock],
                chars: "",
                keyCode: 125
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control, .capsLock],
                chars: "p",
                keyCode: 35
            ),
            -1
        )
    }

    func testDoesNotTreatControlJKAsPaletteNavigation() {
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "j",
                keyCode: 38
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0a}",
                keyCode: 38
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "k",
                keyCode: 40
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0b}",
                keyCode: 40
            )
        )
    }

    func testIgnoresUnsupportedModifiersAndKeys() {
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control, .shift],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "x",
                keyCode: 7
            )
        )
    }

    func testInlineTextHandlingDisablesPaletteSelectionNavigationRouting() {
        XCTAssertTrue(
            CommandPaletteSelectionNavigation(
                delta: -1,
                isInteractive: true,
                usesInlineTextHandling: false
            ).shouldRoute
        )
        XCTAssertFalse(
            CommandPaletteSelectionNavigation(
                delta: -1,
                isInteractive: true,
                usesInlineTextHandling: true
            ).shouldRoute
        )
        XCTAssertFalse(
            CommandPaletteSelectionNavigation(
                delta: nil,
                isInteractive: true,
                usesInlineTextHandling: false
            ).shouldRoute
        )
        XCTAssertFalse(
            CommandPaletteSelectionNavigation(
                delta: 1,
                isInteractive: false,
                usesInlineTextHandling: false
            ).shouldRoute
        )
    }
}


final class CommandPaletteOpenShortcutConsumptionTests: XCTestCase {
    func testDoesNotConsumeWhenPaletteIsNotVisible() {
        XCTAssertFalse(
            CommandPaletteKeystroke(keyCode: 45, modifierFlags: [.command], characters: "n")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: false)
        )
    }

    func testConsumesAppCommandShortcutsWhenPaletteIsVisible() {
        XCTAssertTrue(
            CommandPaletteKeystroke(keyCode: 45, modifierFlags: [.command], characters: "n")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
        XCTAssertTrue(
            CommandPaletteKeystroke(keyCode: 17, modifierFlags: [.command], characters: "t")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
        XCTAssertTrue(
            CommandPaletteKeystroke(keyCode: 43, modifierFlags: [.command, .shift], characters: ",")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
    }

    func testAllowsClipboardAndUndoShortcutsForPaletteTextEditing() {
        XCTAssertFalse(
            CommandPaletteKeystroke(keyCode: 9, modifierFlags: [.command], characters: "v")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
        XCTAssertFalse(
            CommandPaletteKeystroke(keyCode: 6, modifierFlags: [.command], characters: "z")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
        XCTAssertFalse(
            CommandPaletteKeystroke(keyCode: 6, modifierFlags: [.command, .shift], characters: "z")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
    }

    func testAllowsArrowAndDeleteEditingCommandsForPaletteTextEditing() {
        XCTAssertFalse(
            CommandPaletteKeystroke(keyCode: 123, modifierFlags: [.command], characters: "")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
        XCTAssertFalse(
            CommandPaletteKeystroke(keyCode: 51, modifierFlags: [.command], characters: "")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
    }

    func testConsumesEscapeWhenPaletteIsVisible() {
        XCTAssertTrue(
            CommandPaletteKeystroke(keyCode: 53, modifierFlags: [], characters: "")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
    }
}


final class CommandPaletteFocusStealerClassificationTests: XCTestCase {
    private final class NonViewTextDelegate: NSObject, NSTextViewDelegate {}
    private final class UnrelatedViewTextDelegate: NSView, NSTextViewDelegate {}
    private final class DelegateTrackingTextView: NSTextView {
        private(set) var delegateReadCount = 0

        override var delegate: NSTextViewDelegate? {
            get {
                delegateReadCount += 1
                return super.delegate
            }
            set {
                super.delegate = newValue
            }
        }
    }

    func testTreatsGhosttySurfaceViewAsFocusStealer() {
        let surfaceView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))

        XCTAssertTrue(surfaceView.isCommandPaletteFocusStealingTerminalOrBrowser)
    }

    func testTreatsTextFieldInsideTerminalHostedViewAsFocusStealer() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        hostedView.addSubview(textField)

        XCTAssertTrue(
            textField.isCommandPaletteFocusStealingTerminalOrBrowser,
            "Terminal-owned overlay text inputs should not be allowed to reclaim focus from the command palette"
        )
    }

    func testDoesNotTreatUnrelatedTextFieldAsFocusStealer() {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))

        XCTAssertFalse(textField.isCommandPaletteFocusStealingTerminalOrBrowser)
    }

    func testDoesNotReadTextViewDelegateForFocusStealerClassification() {
        let textView = DelegateTrackingTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))

        XCTAssertFalse(textView.isCommandPaletteFocusStealingTerminalOrBrowser)
        XCTAssertEqual(
            textView.delegateReadCount,
            0,
            "Command palette focus-stealer classification must avoid NSTextView.delegate because AppKit exposes it as unsafe-unretained"
        )
    }

    func testTreatsTextViewInsideTerminalHostedViewAsFocusStealerWhenDelegateIsNotAView() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let delegate = NonViewTextDelegate()
        textView.delegate = delegate
        hostedView.addSubview(textView)

        XCTAssertTrue(
            textView.isCommandPaletteFocusStealingTerminalOrBrowser,
            "NSTextView responders should still be blocked via the NSView hierarchy walk when the delegate is not a view"
        )
    }

    func testTreatsTextViewInsideTerminalHostedViewAsFocusStealerWhenDelegateViewIsUnrelated() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let delegateView = UnrelatedViewTextDelegate(frame: .zero)
        textView.delegate = delegateView
        hostedView.addSubview(textView)

        XCTAssertTrue(
            textView.isCommandPaletteFocusStealingTerminalOrBrowser,
            "NSTextView responders should still be blocked via the NSView hierarchy walk when the delegate view is unrelated"
        )
    }
}


final class CommandPaletteRestoreFocusStateMachineTests: XCTestCase {
    func testRestoresBrowserAddressBarWhenPaletteOpenedFromFocusedAddressBar() {
        let panelId = UUID()
        XCTAssertTrue(
            CommandPaletteBrowserAddressBarRestorePolicy(
                focusedPanelIsBrowser: true,
                focusedBrowserAddressBarPanelId: panelId,
                focusedPanelId: panelId
            ).shouldRestore
        )
    }

    func testDoesNotRestoreBrowserAddressBarWhenFocusedPanelIsNotBrowser() {
        let panelId = UUID()
        XCTAssertFalse(
            CommandPaletteBrowserAddressBarRestorePolicy(
                focusedPanelIsBrowser: false,
                focusedBrowserAddressBarPanelId: panelId,
                focusedPanelId: panelId
            ).shouldRestore
        )
    }

    func testDoesNotRestoreBrowserAddressBarWhenAnotherPanelHadAddressBarFocus() {
        XCTAssertFalse(
            CommandPaletteBrowserAddressBarRestorePolicy(
                focusedPanelIsBrowser: true,
                focusedBrowserAddressBarPanelId: UUID(),
                focusedPanelId: UUID()
            ).shouldRestore
        )
    }

    func testTerminalFocusTextBoxCommandRestoresTextBoxAfterPaletteDismiss() {
        XCTAssertEqual(
            ContentView.commandPalettePostRunRestoreFocusIntent(forCommandId: "palette.terminalFocusTextBoxInput"),
            .terminal(.textBoxInput)
        )
    }

    func testTerminalAttachTextBoxFileCommandRestoresTextBoxAfterPaletteDismiss() {
        XCTAssertEqual(
            ContentView.commandPalettePostRunRestoreFocusIntent(forCommandId: "palette.terminalAttachTextBoxFile"),
            .terminal(.textBoxInput)
        )
    }

    func testOtherCommandPaletteCommandsDoNotForcePostRunFocusRestore() {
        XCTAssertNil(
            ContentView.commandPalettePostRunRestoreFocusIntent(forCommandId: "palette.terminalToggleTextBoxInput")
        )
    }
}


final class CommandPaletteRenameSelectionSettingsTests: XCTestCase {
    private let suiteName = "cmux.tests.commandPaletteRenameSelection.\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDefaultsToSelectAllWhenUnset() {
        let defaults = makeDefaults()
        XCTAssertTrue(CommandPaletteSettingsStore(defaults: defaults).renameSelectsAllOnFocus)
    }

    func testReturnsFalseWhenStoredFalse() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppCatalogSection().renameSelectsExistingName.userDefaultsKey)
        XCTAssertFalse(CommandPaletteSettingsStore(defaults: defaults).renameSelectsAllOnFocus)
    }

    func testReturnsTrueWhenStoredTrue() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppCatalogSection().renameSelectsExistingName.userDefaultsKey)
        XCTAssertTrue(CommandPaletteSettingsStore(defaults: defaults).renameSelectsAllOnFocus)
    }
}

final class CommandPaletteAuthCommandTests: XCTestCase {
    func testSignedOutContextShowsSignInCommandOnly() {
        var context = CommandPaletteContextSnapshot()
        context.setBool(CommandPaletteContextKeys.authSignedIn, false)
        context.setBool(CommandPaletteContextKeys.authWorking, false)

        let visibleCommandIds = visibleAuthCommandIds(context)

        XCTAssertEqual(visibleCommandIds, [ContentView.commandPaletteAuthSignInCommandId])
    }

    func testSignedInContextShowsSignOutCommandOnly() {
        var context = CommandPaletteContextSnapshot()
        context.setBool(CommandPaletteContextKeys.authSignedIn, true)
        context.setBool(CommandPaletteContextKeys.authWorking, false)

        let visibleCommandIds = visibleAuthCommandIds(context)

        XCTAssertEqual(visibleCommandIds, [ContentView.commandPaletteAuthSignOutCommandId])
    }

    func testWorkingAuthContextHidesSignInAndSignOutCommands() {
        for signedIn in [false, true] {
            var context = CommandPaletteContextSnapshot()
            context.setBool(CommandPaletteContextKeys.authSignedIn, signedIn)
            context.setBool(CommandPaletteContextKeys.authWorking, true)

            XCTAssertTrue(visibleAuthCommandIds(context).isEmpty)
        }
    }

    private func visibleAuthCommandIds(_ context: CommandPaletteContextSnapshot) -> [String] {
        ContentView.commandPaletteAuthCommandContributions()
            .filter { $0.when(context) }
            .map(\.commandId)
    }
}


final class CommandPaletteSelectionScrollBehaviorTests: XCTestCase {
    func testFirstEntryPinsToTopAnchor() {
        let anchor = CommandPaletteSelectionNavigation.scrollPositionAnchor(
            selectedIndex: 0,
            resultCount: 20
        )
        XCTAssertEqual(anchor, UnitPoint.top)
    }

    func testLastEntryPinsToBottomAnchor() {
        let anchor = CommandPaletteSelectionNavigation.scrollPositionAnchor(
            selectedIndex: 19,
            resultCount: 20
        )
        XCTAssertEqual(anchor, UnitPoint.bottom)
    }

    func testMiddleEntryUsesNilAnchorForMinimalScroll() {
        let anchor = CommandPaletteSelectionNavigation.scrollPositionAnchor(
            selectedIndex: 6,
            resultCount: 20
        )
        XCTAssertNil(anchor)
    }

    func testEmptyResultsProduceNoAnchor() {
        let anchor = CommandPaletteSelectionNavigation.scrollPositionAnchor(
            selectedIndex: 0,
            resultCount: 0
        )
        XCTAssertNil(anchor)
    }
}


final class ShortcutHintModifierPolicyTests: XCTestCase {
    func testTitlebarShortcutHintActionSlotsIncludeFocusHistoryNavigation() {
        XCTAssertEqual(
            TitlebarShortcutHintActionSlot.allCases.map(\.action),
            [
                .toggleSidebar,
                .showNotifications,
                .newTab,
                .focusHistoryBack,
                .focusHistoryForward,
            ]
        )
    }

    func testTitlebarShortcutHintAlwaysShowAllowsBoundNonCommandShortcut() {
        let controlShortcut = StoredShortcut(key: "R", command: false, shift: false, option: false, control: true)
        let commandShortcut = StoredShortcut(key: "R", command: true, shift: false, option: false, control: false)

        XCTAssertTrue(
            controlShortcut.titlebarHintShouldShow(
                alwaysShowShortcutHints: true,
                modifierPressed: false
            )
        )
        XCTAssertFalse(
            controlShortcut.titlebarHintShouldShow(
                alwaysShowShortcutHints: false,
                modifierPressed: true
            )
        )
        XCTAssertTrue(
            commandShortcut.titlebarHintShouldShow(
                alwaysShowShortcutHints: false,
                modifierPressed: true
            )
        )
        XCTAssertFalse(
            StoredShortcut.unbound.titlebarHintShouldShow(
                alwaysShowShortcutHints: true,
                modifierPressed: true
            )
        )
    }

    func testShortcutHintRequiresEnabledCommandOrControlOnlyModifier() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.command]))
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.control]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: []))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.command, .shift]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.control, .shift]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.command, .option]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.control, .option]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.command, .control]))
        }
    }

    func testShortcutHintShowsForControlModifier() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.control]))
        }
    }

    func testControlOnlyShortcutHintRequiresControlModifier() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowControlHints(for: [.control]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowControlHints(for: [.command]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowControlHints(for: [.control, .shift]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowControlHints(for: [.control, .option]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowControlHints(for: []))
        }
    }

    func testCommandOnlyShortcutHintRequiresCommandModifier() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowCommandHints(for: [.command]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowCommandHints(for: [.control]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowCommandHints(for: [.command, .shift]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowCommandHints(for: [.command, .option]))
            XCTAssertFalse(ShortcutHintModifierPolicy(defaults: defaults).shouldShowCommandHints(for: []))
        }
    }

    func testCommandAndControlHintsAreHardcodedEnabled() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.command]))
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.control]))
        }
    }

    func testShortcutHintIgnoresCustomizedWorkspaceShortcutModifiers() {
        let action = KeyboardShortcutSettings.Action.selectWorkspaceByNumber
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "1", command: false, shift: false, option: false, control: true),
            for: action
        )

        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.command]))
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.control]))
        }
    }

    func testShortcutHintIgnoresWorkspaceShortcutChords() {
        let action = KeyboardShortcutSettings.Action.selectWorkspaceByNumber
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "1",
                command: false,
                shift: false,
                option: false,
                control: true,
                chordKey: "2",
                chordCommand: true,
                chordShift: false,
                chordOption: false,
                chordControl: false
            ),
            for: action
        )

        withDefaultsSuite { defaults in
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.command]))
            XCTAssertTrue(ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(for: [.control]))
        }
    }

    func testShortcutHintUsesIntentionalHoldDelay() {
        XCTAssertEqual(ShortcutHintModifierPolicy.intentionalHoldDelay, 0.30, accuracy: 0.001)
    }

    func testCurrentWindowRequiresHostWindowToBeKeyAndMatchEventWindow() {
        XCTAssertTrue(
            ShortcutHintModifierPolicy().isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: 42,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            ShortcutHintModifierPolicy().isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: 7,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            ShortcutHintModifierPolicy().isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: false,
                eventWindowNumber: 42,
                keyWindowNumber: 42
            )
        )
    }

    func testWindowScopedShortcutHintsUseKeyWindowWhenNoEventWindowIsAvailable() {
        withDefaultsSuite { defaults in
            XCTAssertTrue(
                ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(
                    for: [.command],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 42
                )
            )

            XCTAssertFalse(
                ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(
                    for: [.command],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 7
                )
            )

            XCTAssertTrue(
                ShortcutHintModifierPolicy(defaults: defaults).shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 42
                )
            )
        }
    }

    private func withDefaultsSuite(_ body: (UserDefaults) -> Void) {
        let suiteName = "ShortcutHintModifierPolicyTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        body(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }
}


final class RightSidebarModeShortcutHintTests: XCTestCase {
    private let touchedShortcutActions: [KeyboardShortcutSettings.Action] = [
        .focusRightSidebar,
        .switchRightSidebarToFiles,
        .switchRightSidebarToFind,
        .switchRightSidebarToSessions,
        .switchRightSidebarToFeed,
        .switchRightSidebarToDock,
    ]
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
    private var savedShortcutData: [KeyboardShortcutSettings.Action: Data?] = [:]
    private var temporaryDirectoryURL: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        savedShortcutData = Dictionary(
            uniqueKeysWithValues: touchedShortcutActions.map { action in
                (action, UserDefaults.standard.data(forKey: action.defaultsKey))
            }
        )

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        temporaryDirectoryURL = directoryURL
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: directoryURL.appendingPathComponent("cmux.json", isDirectory: false).path,
            fallbackPath: nil,
            startWatching: false
        )
        for action in touchedShortcutActions {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
        KeyboardShortcutSettings.notifySettingsFileDidChange()
    }

    override func tearDownWithError() throws {
        for action in touchedShortcutActions {
            if case let .some(.some(data)) = savedShortcutData[action] {
                UserDefaults.standard.set(data, forKey: action.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: action.defaultsKey)
            }
        }
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.notifySettingsFileDidChange()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    func testModeShortcutActionsMatchModeSwitchingActions() {
        XCTAssertEqual(RightSidebarMode.files.shortcutAction, .switchRightSidebarToFiles)
        XCTAssertEqual(RightSidebarMode.find.shortcutAction, .switchRightSidebarToFind)
        XCTAssertEqual(RightSidebarMode.sessions.shortcutAction, .switchRightSidebarToSessions)
        XCTAssertEqual(RightSidebarMode.feed.shortcutAction, .switchRightSidebarToFeed)
        XCTAssertEqual(RightSidebarMode.dock.shortcutAction, .switchRightSidebarToDock)
    }

    func testModeShortcutsUsePrivateControlDigitDefaults() {
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "1", modifiers: [.control], keyCode: 18)),
            .files
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "2", modifiers: [.control], keyCode: 19)),
            .find
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "3", modifiers: [.control], keyCode: 20)),
            .sessions
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "4", modifiers: [.control], keyCode: 21)),
            .feed
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "5", modifiers: [.control], keyCode: 23)),
            .dock
        )
    }

    func testModeShortcutUsesConfiguredBindings() {
        let customFilesShortcut = StoredShortcut(
            key: "4",
            command: false,
            shift: false,
            option: false,
            control: true
        )
        KeyboardShortcutSettings.setShortcut(customFilesShortcut, for: .switchRightSidebarToFiles)

        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "4", modifiers: [.control], keyCode: 21)),
            .files
        )
        XCTAssertNil(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "1", modifiers: [.control], keyCode: 18))
        )
    }

    func testModeShortcutHonorsActionGate() {
        let feedEvent = makeKeyDownEvent(key: "4", modifiers: [.control], keyCode: 21)

        XCTAssertNil(
            RightSidebarMode.modeShortcut(for: feedEvent) { action in
                action != .switchRightSidebarToFeed
            }
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: feedEvent) { action in
                action == .switchRightSidebarToFeed
            },
            .feed
        )
    }

    func testModeShortcutUsesSettingsFileBindings() throws {
        let settingsFileURL = try XCTUnwrap(temporaryDirectoryURL)
            .appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "switchRightSidebarToFiles": "ctrl+8"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        KeyboardShortcutSettings.settingsFileStore.reload()
        KeyboardShortcutSettings.notifySettingsFileDidChange()

        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "8", modifiers: [.control], keyCode: 28)),
            .files
        )
        XCTAssertNil(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "1", modifiers: [.control], keyCode: 18))
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "2", modifiers: [.control], keyCode: 19)),
            .find
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "3", modifiers: [.control], keyCode: 20)),
            .sessions
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "4", modifiers: [.control], keyCode: 21)),
            .feed
        )
        XCTAssertEqual(
            RightSidebarMode.modeShortcut(for: makeKeyDownEvent(key: "5", modifiers: [.control], keyCode: 23)),
            .dock
        )
    }

    func testFocusRightSidebarShortcutCanBeOverwrittenForHintRendering() {
        let customShortcut = StoredShortcut(
            key: "e",
            command: true,
            shift: true,
            option: true,
            control: false
        )
        KeyboardShortcutSettings.setShortcut(customShortcut, for: .focusRightSidebar)

        let resolvedShortcut = KeyboardShortcutSettings.shortcut(for: .focusRightSidebar)
        XCTAssertEqual(resolvedShortcut, customShortcut)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.focusRightSidebar.displayedShortcutString(for: resolvedShortcut),
            ShortcutDisplayFormatter().displayString(customShortcut)
        )
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }
}

final class MainWindowFocusControllerRightSidebarHideTests: XCTestCase {
    private final class TestRightSidebarResponder: NSView, FeedKeyboardFocusResponder {
        override var acceptsFirstResponder: Bool { true }
    }

    @MainActor
    func testHiddenRightSidebarClearsFocusIntentWhenNoTerminalCanRestore() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState(),
            surfaceFocusResolver: AppTerminalSurfaceFocusResolver()
        )
        let workspaceId = UUID()
        let panelId = UUID()

        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
        controller.noteRightSidebarInteraction(mode: .feed)
        XCTAssertFalse(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))

        XCTAssertFalse(controller.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded())
        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
    }

    @MainActor
    func testHiddenRightSidebarDoesNotRestoreWhenTerminalAlreadyOwnsFocus() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState(),
            surfaceFocusResolver: AppTerminalSurfaceFocusResolver()
        )
        let workspaceId = UUID()
        let panelId = UUID()

        controller.noteTerminalInteraction(workspaceId: workspaceId, panelId: panelId)

        XCTAssertFalse(controller.shouldRestoreTerminalFocusWhenRightSidebarHides(currentResponder: nil))
        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
    }

    @MainActor
    func testMainPanelInteractionKeepsFeedSelectionInactive() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState(),
            surfaceFocusResolver: AppTerminalSurfaceFocusResolver()
        )
        let itemId = UUID()
        let workspaceId = UUID()
        let panelId = UUID()

        XCTAssertTrue(controller.selectFeedItem(itemId, focusFeed: false))
        XCTAssertEqual(controller.feedFocusSnapshot().selectedItemId, itemId)
        XCTAssertTrue(controller.feedFocusSnapshot().isKeyboardActive)

        controller.noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)

        XCTAssertEqual(controller.feedFocusSnapshot().selectedItemId, itemId)
        XCTAssertFalse(controller.feedFocusSnapshot().isKeyboardActive)
        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
        XCTAssertEqual(controller.focusToggleDestination(), .rightSidebar)
    }

    @MainActor
    func testFocusShortcutToggleUsesActualRightSidebarResponderOverStaleIntent() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState(),
            surfaceFocusResolver: AppTerminalSurfaceFocusResolver()
        )
        let responder = TestRightSidebarResponder(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

        let workspaceId = UUID()
        let panelId = UUID()
        controller.noteTerminalInteraction(workspaceId: workspaceId, panelId: panelId)

        XCTAssertEqual(controller.focusToggleDestination(currentResponder: responder), .terminal)
        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
    }

    @MainActor
    func testPendingSessionsFocusSurvivesStaleFeedResponderDuringModeSwitch() {
        let fileExplorerState = FileExplorerState()
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: fileExplorerState,
            surfaceFocusResolver: AppTerminalSurfaceFocusResolver()
        )
        let staleFeedResponder = TestRightSidebarResponder(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

        XCTAssertTrue(controller.selectFeedItem(UUID(), focusFeed: false))
        XCTAssertTrue(controller.focusRightSidebar(mode: .sessions, focusFirstItem: true))
        XCTAssertEqual(controller.intent, .rightSidebar(mode: .sessions))
        XCTAssertEqual(fileExplorerState.mode, .sessions)
        XCTAssertEqual(controller.debugPendingRightSidebarFocusMode, .sessions)

        controller.debugSyncAfterResponderChange(responder: staleFeedResponder)

        XCTAssertEqual(controller.intent, .rightSidebar(mode: .sessions))
        XCTAssertEqual(controller.debugPendingRightSidebarFocusMode, .sessions)
    }

    @MainActor
    func testPendingSessionsFocusCompletesWhenRightSidebarHostRegisters() {
        let fileExplorerState = FileExplorerState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = contentView
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: window,
            tabManager: TabManager(),
            fileExplorerState: fileExplorerState,
            surfaceFocusResolver: AppTerminalSurfaceFocusResolver()
        )

        XCTAssertTrue(controller.focusRightSidebar(mode: .sessions, focusFirstItem: true))
        XCTAssertEqual(controller.debugPendingRightSidebarFocusMode, .sessions)

        let focusHost = RightSidebarKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        defer {
            _ = window.makeFirstResponder(nil)
            focusHost.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }
        contentView.addSubview(focusHost)
        controller.registerRightSidebarHost(focusHost)

        XCTAssertNil(controller.debugPendingRightSidebarFocusMode)
        XCTAssertTrue(window.firstResponder === focusHost)
    }

    @MainActor
    func testFocusShortcutToggleClearsRightSidebarIntentWhenTerminalIsUnavailable() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState(),
            surfaceFocusResolver: AppTerminalSurfaceFocusResolver()
        )
        let workspaceId = UUID()
        let panelId = UUID()

        controller.noteRightSidebarInteraction(mode: .feed)
        XCTAssertFalse(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))

        XCTAssertFalse(controller.toggleRightSidebarOrTerminalFocus())
        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
    }
}

final class ShortcutHintDebugSettingsTests: XCTestCase {
    func testClampKeepsValuesWithinSupportedRange() {
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(0.0), 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(4.0), 4.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(-100.0), ShortcutHintDebugSettings.offsetRange.lowerBound)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(100.0), ShortcutHintDebugSettings.offsetRange.upperBound)
    }

    func testDefaultOffsetsMatchCurrentBadgePlacements() {
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintY, -5.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultRightSidebarCloseHintX, -10.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultRightSidebarCloseHintY, 3.3)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultRightSidebarFocusHintX, -1.6)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultRightSidebarFocusHintY, 1.7)
        XCTAssertFalse(ShortcutHintDebugSettings.defaultAlwaysShowHints)
        XCTAssertTrue(ShortcutHintDebugSettings.defaultShowHintsOnCommandHold)
        XCTAssertTrue(ShortcutHintDebugSettings.defaultShowHintsOnControlHold)
    }

    func testAlwaysShowHintsIsOnlyEnabledForUITests() {
        XCTAssertFalse(ShortcutHintDebugSettings(environment: [:]).alwaysShowHints)
        XCTAssertTrue(
            ShortcutHintDebugSettings(
                environment: ["CMUX_UI_TEST_SHORTCUT_HINTS_ALWAYS_SHOW": "1"]
            ).alwaysShowHints
        )
    }

    func testShowHintsOnCommandHoldIsHardcodedEnabled() {
        let suiteName = "ShortcutHintDebugSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ShortcutHintDebugSettings(defaults: defaults).showHintsOnCommandHoldEnabled)
    }

    func testShowHintsOnControlHoldIsHardcodedEnabled() {
        let suiteName = "ShortcutHintDebugSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ShortcutHintDebugSettings(defaults: defaults).showHintsOnControlHoldEnabled)
    }
}


final class DevBuildBannerDebugSettingsTests: XCTestCase {
    func testShowSidebarBannerDefaultsToVisible() {
        let suiteName = "DevBuildBannerDebugSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
        XCTAssertTrue(DevBuildBannerDebugSettings(defaults: defaults).showSidebarBanner)
    }

    func testShowSidebarBannerRespectsStoredValue() {
        let suiteName = "DevBuildBannerDebugSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
        XCTAssertFalse(DevBuildBannerDebugSettings(defaults: defaults).showSidebarBanner)

        defaults.set(true, forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
        XCTAssertTrue(DevBuildBannerDebugSettings(defaults: defaults).showSidebarBanner)
    }
}


final class ShortcutHintLanePlannerTests: XCTestCase {
    func testAssignLanesKeepsSeparatedIntervalsOnSingleLane() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 28...40, 48...64]
        XCTAssertEqual(ShortcutHintLanePlanner(intervals: intervals, minSpacing: 4).lanes, [0, 0, 0])
    }

    func testAssignLanesStacksOverlappingIntervalsIntoAdditionalLanes() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 22...38, 40...56]
        XCTAssertEqual(ShortcutHintLanePlanner(intervals: intervals, minSpacing: 4).lanes, [0, 1, 2, 0])
    }
}


final class ShortcutHintHorizontalPlannerTests: XCTestCase {
    func testAssignRightEdgesResolvesOverlapWithMinimumSpacing() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 30...46]
        let rightEdges = ShortcutHintHorizontalPlanner(intervals: intervals, minSpacing: 6).rightEdges

        XCTAssertEqual(rightEdges.count, intervals.count)

        let adjustedIntervals = zip(intervals, rightEdges).map { interval, rightEdge in
            let width = interval.upperBound - interval.lowerBound
            return (rightEdge - width)...rightEdge
        }

        XCTAssertGreaterThanOrEqual(adjustedIntervals[1].lowerBound - adjustedIntervals[0].upperBound, 6)
        XCTAssertGreaterThanOrEqual(adjustedIntervals[2].lowerBound - adjustedIntervals[1].upperBound, 6)
    }

    func testAssignRightEdgesKeepsAlreadySeparatedIntervalsInPlace() {
        let intervals: [ClosedRange<CGFloat>] = [0...12, 20...32, 40...52]
        let rightEdges = ShortcutHintHorizontalPlanner(intervals: intervals, minSpacing: 4).rightEdges
        XCTAssertEqual(rightEdges, [12, 32, 52])
    }

    func testAssignRightEdgesKeepsCrowdedHintsInsideLeadingEdge() {
        let intervals: [ClosedRange<CGFloat>] = [-2...24, 27...50, 50...76, 78...102, 104...128]
        let rightEdges = ShortcutHintHorizontalPlanner(intervals: intervals, minSpacing: 6).rightEdges

        let adjustedIntervals = zip(intervals, rightEdges).map { interval, rightEdge in
            let width = interval.upperBound - interval.lowerBound
            return (rightEdge - width)...rightEdge
        }

        XCTAssertGreaterThanOrEqual(adjustedIntervals[0].lowerBound, 0)
        for index in 1..<adjustedIntervals.count {
            XCTAssertGreaterThanOrEqual(
                adjustedIntervals[index].lowerBound - adjustedIntervals[index - 1].upperBound,
                6
            )
        }
    }
}


final class LastSurfaceCloseShortcutSettingsTests: XCTestCase {
    func testDefaultClosesWorkspace() {
        let suiteName = "LastSurfaceCloseShortcutSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SettingCatalog().app.keepWorkspaceOpenWhenClosingLastSurface
        XCTAssertTrue(UserDefaultsSettingsClient(defaults: defaults).value(for: key))
    }

    func testStoredTrueClosesWorkspace() {
        let suiteName = "LastSurfaceCloseShortcutSettingsTests.Enabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SettingCatalog().app.keepWorkspaceOpenWhenClosingLastSurface
        defaults.set(true, forKey: key.userDefaultsKey)
        XCTAssertTrue(UserDefaultsSettingsClient(defaults: defaults).value(for: key))
    }

    func testStoredFalseKeepsWorkspaceOpen() {
        let suiteName = "LastSurfaceCloseShortcutSettingsTests.Disabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SettingCatalog().app.keepWorkspaceOpenWhenClosingLastSurface
        defaults.set(false, forKey: key.userDefaultsKey)
        XCTAssertFalse(UserDefaultsSettingsClient(defaults: defaults).value(for: key))
    }
}

final class QuitWarningSettingsTests: XCTestCase {
    func testDefaultWarnBeforeQuitIsEnabledWhenUnset() {
        let suiteName = "QuitWarningSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey)

        XCTAssertTrue(QuitConfirmationStore(defaults: defaults).isEnabled)
    }

    func testStoredPreferenceOverridesDefault() {
        let suiteName = "QuitWarningSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey)
        XCTAssertFalse(QuitConfirmationStore(defaults: defaults).isEnabled)

        defaults.set(true, forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey)
        XCTAssertTrue(QuitConfirmationStore(defaults: defaults).isEnabled)
    }

    func testShouldShowConfirmationFollowsEnabledPreference() {
        let suiteName = "QuitWarningSettingsTests.ShouldShow.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey)
        XCTAssertTrue(
            QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                isQuitWarningConfirmed: false,
                hasDirtyWorkspaces: true,
                isDevBuild: BuildFlavor.stable == .dev
            )
        )

        XCTAssertFalse(
            QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                isQuitWarningConfirmed: true,
                hasDirtyWorkspaces: true,
                isDevBuild: BuildFlavor.stable == .dev
            )
        )

        defaults.set(false, forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey)
        XCTAssertFalse(
            QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                isQuitWarningConfirmed: false,
                hasDirtyWorkspaces: true,
                isDevBuild: BuildFlavor.stable == .dev
            )
        )
        XCTAssertFalse(
            QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                isQuitWarningConfirmed: true,
                hasDirtyWorkspaces: true,
                isDevBuild: BuildFlavor.stable == .dev
            )
        )
    }

    func testSetEnabledWritesConfirmQuitAndLegacyFallback() {
        let suiteName = "QuitWarningSettingsTests.SetEnabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        QuitConfirmationStore(defaults: defaults).setEnabled(false)
        XCTAssertEqual(defaults.string(forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey), ConfirmQuitMode.never.rawValue)
        XCTAssertEqual(defaults.object(forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey) as? Bool, false)
        XCTAssertEqual(QuitConfirmationStore(defaults: defaults).confirmQuitMode, .never)

        QuitConfirmationStore(defaults: defaults).setEnabled(true)
        XCTAssertEqual(defaults.string(forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey), ConfirmQuitMode.always.rawValue)
        XCTAssertEqual(defaults.object(forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey) as? Bool, true)
        XCTAssertEqual(QuitConfirmationStore(defaults: defaults).confirmQuitMode, .always)
    }
}

final class BuildFlavorTests: XCTestCase {
    func testDetectsDevFromBundleName() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux DEV noqdlg", bundleIdentifier: "com.cmuxterm.app"),
            .dev
        )
    }

    func testDetectsDevBeforeTagTextCanLookNightly() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux DEV nightly", bundleIdentifier: "com.cmuxterm.app"),
            .dev
        )
    }

    func testDetectsNightlyFromBundleIdentifier() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app.nightly"),
            .nightly
        )
    }

    func testDetectsStableByDefault() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app"),
            .stable
        )
    }
}

final class QuitConfirmationPolicyTests: XCTestCase {
    func testDevAlwaysSkipsQuitConfirmation() {
        withIsolatedDefaults { defaults in
            defaults.set(ConfirmQuitMode.always.rawValue, forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey)
            XCTAssertFalse(
                QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: true,
                    isDevBuild: BuildFlavor.dev == .dev
                )
            )

            defaults.set(ConfirmQuitMode.dirtyOnly.rawValue, forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey)
            XCTAssertFalse(
                QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: true,
                    isDevBuild: BuildFlavor.dev == .dev
                )
            )
        }
    }

    func testStableHonorsConfirmQuitModes() {
        withIsolatedDefaults { defaults in
            defaults.set(ConfirmQuitMode.always.rawValue, forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey)
            XCTAssertTrue(
                QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: false,
                    isDevBuild: BuildFlavor.stable == .dev
                )
            )

            defaults.set(ConfirmQuitMode.dirtyOnly.rawValue, forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey)
            XCTAssertFalse(
                QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: false,
                    isDevBuild: BuildFlavor.stable == .dev
                )
            )
            XCTAssertTrue(
                QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: true,
                    isDevBuild: BuildFlavor.stable == .dev
                )
            )

            defaults.set(ConfirmQuitMode.never.rawValue, forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey)
            XCTAssertFalse(
                QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: true,
                    isDevBuild: BuildFlavor.stable == .dev
                )
            )
        }
    }

    func testNightlyHonorsConfirmQuitModes() {
        withIsolatedDefaults { defaults in
            defaults.set(ConfirmQuitMode.dirtyOnly.rawValue, forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey)
            XCTAssertFalse(
                QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: false,
                    isDevBuild: BuildFlavor.nightly == .dev
                )
            )
            XCTAssertTrue(
                QuitConfirmationStore(defaults: defaults).shouldShowConfirmation(
                    isQuitWarningConfirmed: false,
                    hasDirtyWorkspaces: true,
                    isDevBuild: BuildFlavor.nightly == .dev
                )
            )
        }
    }

    func testLegacyWarnBeforeQuitMapsWhenConfirmQuitUnset() {
        withIsolatedDefaults { defaults in
            defaults.set(false, forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey)
            XCTAssertEqual(QuitConfirmationStore(defaults: defaults).confirmQuitMode, .never)

            defaults.set(true, forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey)
            XCTAssertEqual(QuitConfirmationStore(defaults: defaults).confirmQuitMode, .always)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "QuitConfirmationPolicyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}


final class UpdateChannelSettingsTests: XCTestCase {
    func testResolvedFeedFallsBackWhenInfoFeedMissing() {
        let resolver = UpdateFeedResolver()
        let resolved = resolver.resolve(infoFeedURL: nil)
        XCTAssertEqual(resolved.url, resolver.fallbackFeedURL)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertTrue(resolved.usedFallback)
    }

    func testResolvedFeedFallsBackWhenInfoFeedEmpty() {
        let resolver = UpdateFeedResolver()
        let resolved = resolver.resolve(infoFeedURL: "")
        XCTAssertEqual(resolved.url, resolver.fallbackFeedURL)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertTrue(resolved.usedFallback)
    }

    func testResolvedFeedUsesInfoFeedForStableChannel() {
        let infoFeed = "https://example.com/custom/appcast.xml"
        let resolved = UpdateFeedResolver().resolve(infoFeedURL: infoFeed)
        XCTAssertEqual(resolved.url, infoFeed)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertFalse(resolved.usedFallback)
    }

    func testResolvedFeedDetectsNightlyFromInfoFeedURL() {
        let resolved = UpdateFeedResolver().resolve(
            infoFeedURL: "https://example.com/nightly/appcast.xml"
        )
        XCTAssertEqual(resolved.url, "https://example.com/nightly/appcast.xml")
        XCTAssertTrue(resolved.isNightly)
        XCTAssertFalse(resolved.usedFallback)
    }
}


final class UpdateSettingsTests: XCTestCase {
    func testApplyEnablesAutomaticChecksAndDailySchedule() {
        let defaults = makeDefaults()
        UpdateSettings().apply(to: defaults)

        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        XCTAssertEqual(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey), UpdateSettings().scheduledCheckInterval)
        XCTAssertFalse(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        XCTAssertFalse(defaults.bool(forKey: UpdateSettings.sendProfileInfoKey))
        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.migrationKey))
    }

    func testApplyRepairsLegacyDisabledAutomaticChecksOnce() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
        defaults.set(0, forKey: UpdateSettings.scheduledCheckIntervalKey)
        defaults.set(true, forKey: UpdateSettings.automaticallyUpdateKey)

        UpdateSettings().apply(to: defaults)

        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        XCTAssertEqual(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey), UpdateSettings().scheduledCheckInterval)
        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))

        defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
        UpdateSettings().apply(to: defaults)

        XCTAssertFalse(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UpdateSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
final class UpdateViewModelPresentationTests: XCTestCase {
    func testDetectedBackgroundUpdateShowsPillWhileIdle() {
        let viewModel = UpdateStateModel()

        viewModel.debugSetDetectedVersion("9.9.9")

        XCTAssertTrue(viewModel.showsPill)
        XCTAssertTrue(viewModel.showsDetectedBackgroundUpdate)
        XCTAssertEqual(viewModel.text, "Update Available: 9.9.9")
        XCTAssertEqual(viewModel.iconName, "shippingbox.fill")
    }

    func testActiveUpdateStateTakesPrecedenceOverDetectedBackgroundVersion() {
        let viewModel = UpdateStateModel()

        viewModel.debugSetDetectedVersion("9.9.9")
        viewModel.setState(.checking(.init(cancel: {})))

        XCTAssertTrue(viewModel.showsPill)
        XCTAssertFalse(viewModel.showsDetectedBackgroundUpdate)
        XCTAssertEqual(viewModel.text, "Checking for Updates…")
    }

    func testDismissDetectedAvailableUpdateRepliesAndClearsState() throws {
        let viewModel = UpdateStateModel()
        let item = try XCTUnwrap(makeAppcastItem(displayVersion: "9.9.9"))
        let recorder = UpdateChoiceRecorder()

        viewModel.recordDetectedUpdate(item)
        viewModel.setState(.updateAvailable(.init(
            appcastItem: item,
            reply: { recorder.record($0) }
        )))

        viewModel.dismissDetectedAvailableUpdate()

        XCTAssertEqual(recorder.snapshot(), [.dismiss])
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(viewModel.detectedUpdateVersion)
        XCTAssertNil(viewModel.detectedUpdateItem)
        XCTAssertFalse(viewModel.showsPill)
    }

    func testCancelActiveStateForNewCheckDismissesAndClearsTransientState() throws {
        let viewModel = UpdateStateModel()
        let item = try XCTUnwrap(makeAppcastItem(displayVersion: "9.9.9"))
        let recorder = UpdateChoiceRecorder()

        viewModel.setState(.updateAvailable(.init(
            appcastItem: item,
            reply: { recorder.record($0) }
        )))
        viewModel.setOverrideState(.checking(.init(cancel: {})))

        viewModel.cancelActiveStateForNewCheck()

        XCTAssertEqual(recorder.snapshot(), [.dismiss])
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(viewModel.overrideState)
    }

    func testApplyDriverStateRecordsDetectedUpdateMetadata() throws {
        let viewModel = UpdateStateModel()
        let item = try XCTUnwrap(makeAppcastItem(displayVersion: "9.9.9"))

        viewModel.applyDriverState(.updateAvailable(.init(
            appcastItem: item,
            reply: { _ in }
        )))
        viewModel.setState(.idle)

        XCTAssertEqual(viewModel.detectedUpdateVersion, "9.9.9")
        XCTAssertTrue(viewModel.hasCachedDetectedUpdateDetails)
        XCTAssertTrue(viewModel.showsDetectedBackgroundUpdate)
    }

    private func makeAppcastItem(displayVersion: String) -> SUAppcastItem? {
        let enclosure: [String: Any] = [
            "url": "https://example.com/cmux.zip",
            "length": "1024",
            "sparkle:version": displayVersion,
            "sparkle:shortVersionString": displayVersion,
        ]
        let dict: [String: Any] = [
            "title": "cmux \(displayVersion)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": enclosure,
        ]
        return SUAppcastItem(dictionary: dict)
    }
}

private final class UpdateChoiceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var choices: [SPUUserUpdateChoice] = []

    func record(_ choice: SPUUserUpdateChoice) {
        lock.lock()
        choices.append(choice)
        lock.unlock()
    }

    func snapshot() -> [SPUUserUpdateChoice] {
        lock.lock()
        defer { lock.unlock() }
        return choices
    }
}
