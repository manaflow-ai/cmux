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

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
            shouldRouteCommandPaletteSelectionNavigation(
                delta: -1,
                isInteractive: true,
                usesInlineTextHandling: false
            )
        )
        XCTAssertFalse(
            shouldRouteCommandPaletteSelectionNavigation(
                delta: -1,
                isInteractive: true,
                usesInlineTextHandling: true
            )
        )
        XCTAssertFalse(
            shouldRouteCommandPaletteSelectionNavigation(
                delta: nil,
                isInteractive: true,
                usesInlineTextHandling: false
            )
        )
        XCTAssertFalse(
            shouldRouteCommandPaletteSelectionNavigation(
                delta: 1,
                isInteractive: false,
                usesInlineTextHandling: false
            )
        )
    }
}


final class CommandPaletteOpenShortcutConsumptionTests: XCTestCase {
    func testDoesNotConsumeWhenPaletteIsNotVisible() {
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: false,
                normalizedFlags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
    }

    func testConsumesAppCommandShortcutsWhenPaletteIsVisible() {
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "t",
                keyCode: 17
            )
        )
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command, .shift],
                chars: ",",
                keyCode: 43
            )
        )
    }

    func testAllowsClipboardAndUndoShortcutsForPaletteTextEditing() {
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "v",
                keyCode: 9
            )
        )
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "z",
                keyCode: 6
            )
        )
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command, .shift],
                chars: "z",
                keyCode: 6
            )
        )
    }

    func testAllowsArrowAndDeleteEditingCommandsForPaletteTextEditing() {
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "",
                keyCode: 123
            )
        )
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "",
                keyCode: 51
            )
        )
    }

    func testConsumesEscapeWhenPaletteIsVisible() {
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [],
                chars: "",
                keyCode: 53
            )
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

        XCTAssertTrue(isCommandPaletteFocusStealingTerminalOrBrowserResponder(surfaceView))
    }

    func testTreatsTextFieldInsideTerminalHostedViewAsFocusStealer() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        hostedView.addSubview(textField)

        XCTAssertTrue(
            isCommandPaletteFocusStealingTerminalOrBrowserResponder(textField),
            "Terminal-owned overlay text inputs should not be allowed to reclaim focus from the command palette"
        )
    }

    func testDoesNotTreatUnrelatedTextFieldAsFocusStealer() {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))

        XCTAssertFalse(isCommandPaletteFocusStealingTerminalOrBrowserResponder(textField))
    }

    func testDoesNotReadTextViewDelegateForFocusStealerClassification() {
        let textView = DelegateTrackingTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))

        XCTAssertFalse(isCommandPaletteFocusStealingTerminalOrBrowserResponder(textView))
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
            isCommandPaletteFocusStealingTerminalOrBrowserResponder(textView),
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
            isCommandPaletteFocusStealingTerminalOrBrowserResponder(textView),
            "NSTextView responders should still be blocked via the NSView hierarchy walk when the delegate view is unrelated"
        )
    }
}


final class CommandPaletteRestoreFocusStateMachineTests: XCTestCase {
    func testRestoresBrowserAddressBarWhenPaletteOpenedFromFocusedAddressBar() {
        let panelId = UUID()
        XCTAssertTrue(
            ContentView.shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss(
                focusedPanelIsBrowser: true,
                focusedBrowserAddressBarPanelId: panelId,
                focusedPanelId: panelId
            )
        )
    }

    func testDoesNotRestoreBrowserAddressBarWhenFocusedPanelIsNotBrowser() {
        let panelId = UUID()
        XCTAssertFalse(
            ContentView.shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss(
                focusedPanelIsBrowser: false,
                focusedBrowserAddressBarPanelId: panelId,
                focusedPanelId: panelId
            )
        )
    }

    func testDoesNotRestoreBrowserAddressBarWhenAnotherPanelHadAddressBarFocus() {
        XCTAssertFalse(
            ContentView.shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss(
                focusedPanelIsBrowser: true,
                focusedBrowserAddressBarPanelId: UUID(),
                focusedPanelId: UUID()
            )
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
        XCTAssertTrue(CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled(defaults: defaults))
    }

    func testReturnsFalseWhenStoredFalse() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
        XCTAssertFalse(CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled(defaults: defaults))
    }

    func testReturnsTrueWhenStoredTrue() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
        XCTAssertTrue(CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled(defaults: defaults))
    }
}

final class CommandPaletteAuthCommandTests: XCTestCase {
    func testSignedOutContextShowsSignInCommandOnly() {
        var context = ContentView.CommandPaletteContextSnapshot()
        context.setBool(ContentView.CommandPaletteContextKeys.authSignedIn, false)
        context.setBool(ContentView.CommandPaletteContextKeys.authWorking, false)

        let visibleCommandIds = visibleAuthCommandIds(context)

        XCTAssertEqual(visibleCommandIds, [ContentView.commandPaletteAuthSignInCommandId])
    }

    func testSignedInContextShowsSignOutCommandOnly() {
        var context = ContentView.CommandPaletteContextSnapshot()
        context.setBool(ContentView.CommandPaletteContextKeys.authSignedIn, true)
        context.setBool(ContentView.CommandPaletteContextKeys.authWorking, false)

        let visibleCommandIds = visibleAuthCommandIds(context)

        XCTAssertEqual(visibleCommandIds, [ContentView.commandPaletteAuthSignOutCommandId])
    }

    func testWorkingAuthContextHidesSignInAndSignOutCommands() {
        for signedIn in [false, true] {
            var context = ContentView.CommandPaletteContextSnapshot()
            context.setBool(ContentView.CommandPaletteContextKeys.authSignedIn, signedIn)
            context.setBool(ContentView.CommandPaletteContextKeys.authWorking, true)

            XCTAssertTrue(visibleAuthCommandIds(context).isEmpty)
        }
    }

    private func visibleAuthCommandIds(_ context: ContentView.CommandPaletteContextSnapshot) -> [String] {
        ContentView.commandPaletteAuthCommandContributions()
            .filter { $0.when(context) }
            .map(\.commandId)
    }
}


final class CommandPaletteSelectionScrollBehaviorTests: XCTestCase {
    func testFirstEntryPinsToTopAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 0,
            resultCount: 20
        )
        XCTAssertEqual(anchor, UnitPoint.top)
    }

    func testLastEntryPinsToBottomAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 19,
            resultCount: 20
        )
        XCTAssertEqual(anchor, UnitPoint.bottom)
    }

    func testMiddleEntryUsesNilAnchorForMinimalScroll() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 6,
            resultCount: 20
        )
        XCTAssertNil(anchor)
    }

    func testEmptyResultsProduceNoAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 0,
            resultCount: 0
        )
        XCTAssertNil(anchor)
    }
}


@MainActor
final class CommandPaletteOverlayPromotionPolicyTests: XCTestCase {
    func testShouldPromoteWhenBecomingVisible() {
        XCTAssertTrue(
            CommandPaletteOverlayPromotionPolicy.shouldPromote(
                previouslyVisible: false,
                isVisible: true
            )
        )
    }

    func testShouldNotPromoteWhenAlreadyVisible() {
        XCTAssertFalse(
            CommandPaletteOverlayPromotionPolicy.shouldPromote(
                previouslyVisible: true,
                isVisible: true
            )
        )
    }

    func testShouldNotPromoteWhenHidden() {
        XCTAssertFalse(
            CommandPaletteOverlayPromotionPolicy.shouldPromote(
                previouslyVisible: true,
                isVisible: false
            )
        )
        XCTAssertFalse(
            CommandPaletteOverlayPromotionPolicy.shouldPromote(
                previouslyVisible: false,
                isVisible: false
            )
        )
    }
}
