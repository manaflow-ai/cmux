import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Browser find, omnibar, and web content shortcut routing tests
extension AppDelegateShortcutRoutingTests {
    func testCmdFFocusedBrowserOpensBrowserFind() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              manager.openBrowser(inWorkspace: workspace.id) != nil else {
            XCTFail("Expected focused browser panel")
            return
        }

        XCTAssertNotNil(manager.focusedBrowserPanel)
        XCTAssertNil(manager.focusedBrowserPanel?.searchState)
        let initialMode = appDelegate.fileExplorerState?.mode

        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+F should open browser find when browser web content is focused"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertNotNil(manager.focusedBrowserPanel?.searchState)
        XCTAssertEqual(appDelegate.fileExplorerState?.mode, initialMode)
    }

    func testOmnibarArrowSelectionUsesResponderResolvedPanelWhenTrackedFocusWasCleared() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id) else {
            XCTFail("Expected focused browser panel")
            return
        }

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.identifier = browserOmnibarTextFieldIdentifier
        field.panelId = browserPanelId
        field.stringValue = "example"
        contentView.addSubview(field)
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: browserPanelId)
        defer {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: browserPanelId)
            field.removeFromSuperview()
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNotNil(field.currentEditor())

        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: browserPanelId)

        let moveExpectation = expectation(
            description: "Expected omnibar move-selection notification for responder-resolved panel"
        )
        var observedPanelId: UUID?
        var observedDelta: Int?
        let moveToken = NotificationCenter.default.addObserver(
            forName: .browserMoveOmnibarSelection,
            object: nil,
            queue: nil
        ) { notification in
            observedPanelId = notification.object as? UUID
            observedDelta = notification.userInfo?["delta"] as? Int
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: downArrowEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 1.0)
        XCTAssertEqual(observedPanelId, browserPanelId)
        XCTAssertEqual(observedDelta, 1)
    }

    func testOmnibarArrowSelectionDoesNotInterceptMarkedTextComposition() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id) else {
            XCTFail("Expected focused browser panel")
            return
        }

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.identifier = browserOmnibarTextFieldIdentifier
        field.panelId = browserPanelId
        field.stringValue = "ㄉㄚˋ"
        contentView.addSubview(field)
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: browserPanelId)

        defer {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: browserPanelId)
            field.removeFromSuperview()
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard let fieldEditor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected omnibar field editor")
            return
        }
        fieldEditor.setMarkedText(
            "ㄉㄚˋ",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(fieldEditor.hasMarkedText())
        NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: browserPanelId)

        let moveExpectation = expectation(
            description: "Down Arrow belongs to the input method while omnibar marked text is active"
        )
        moveExpectation.isInverted = true
        let moveToken = NotificationCenter.default.addObserver(
            forName: .browserMoveOmnibarSelection,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.object as? UUID == browserPanelId else { return }
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: downArrowEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 0.1)
    }

    func testOmnibarArrowSelectionSurvivesTransientWindowFirstResponder() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected focused browser panel")
            return
        }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.identifier = browserOmnibarTextFieldIdentifier
        field.panelId = browserPanelId
        field.stringValue = "example"
        contentView.addSubview(field)
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: browserPanelId)
        defer {
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: browserPanelId)
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: browserPanelId)
            field.removeFromSuperview()
        }

        XCTAssertTrue(appDelegate.requestBrowserAddressBarFocus(panelId: browserPanelId))
        XCTAssertEqual(appDelegate.focusedBrowserAddressBarPanelId(), browserPanelId)
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(window.firstResponder === window)

        let moveExpectation = expectation(
            description: "Expected omnibar move-selection notification while first responder is transiently the window"
        )
        var observedPanelId: UUID?
        var observedDelta: Int?
        let moveToken = NotificationCenter.default.addObserver(
            forName: .browserMoveOmnibarSelection,
            object: nil,
            queue: nil
        ) { notification in
            observedPanelId = notification.object as? UUID
            observedDelta = notification.userInfo?["delta"] as? Int
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: downArrowEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 1.0)
        XCTAssertEqual(observedPanelId, browserPanelId)
        XCTAssertEqual(observedDelta, 1)
    }

    func testReactGrabShortcutIsConsumedWhenNoBrowserRouteExists() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(action: .toggleReactGrab) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "G",
                charactersIgnoringModifiers: "g",
                isARepeat: false,
                keyCode: 5
            ) else {
                XCTFail("Failed to construct Cmd+Shift+G event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testBrowserFindCommandPreflightConsultsConfiguredFindFamilyShortcuts() {
        #if DEBUG
        let cases: [(action: KeyboardShortcutSettings.Action, modifiers: NSEvent.ModifierFlags, key: String, keyCode: UInt16)] = [
            (.find, [.command], "f", 3),
            (.findInDirectory, [.command, .shift], "f", 3),
            (.findNext, [.command], "g", 5),
            (.findPrevious, [.command, .option], "g", 5),
            (.hideFind, [.command, .option, .shift], "f", 3),
            (.useSelectionForFind, [.command], "e", 14),
        ]

        for testCase in cases {
            var observedActions: [KeyboardShortcutSettings.Action] = []
            KeyboardShortcutSettings.shortcutLookupObserver = { action in
                observedActions.append(action)
            }

            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.key,
                charactersIgnoringModifiers: testCase.key,
                keyCode: testCase.keyCode
            )

            _ = shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event)

            XCTAssertTrue(
                observedActions.contains(testCase.action),
                "Browser find command preflight must read the configured \(testCase.action.rawValue) shortcut instead of matching a literal combo"
            )
        }
        #else
        XCTFail("shortcutLookupObserver is only available in DEBUG")
        #endif
    }

    // MARK: - Browser find shortcut routing tests

    func testBrowserFirstFindShortcutRoutingRecognizesBrowserLocalFindCommandFamily() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-g", [.command], "g", 5),
            ("cmd-option-g", [.command, .option], "g", 5),
            ("cmd-option-shift-f", [.command, .option, .shift], "f", 3),
            ("cmd-e", [.command], "e", 14),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )
            XCTAssertTrue(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Expected browser-first routing for \(testCase.name)"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingExcludesAppOwnedFindCommands() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-f", [.command], "f", 3),
            ("cmd-shift-f", [.command, .shift], "f", 3),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )

            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "\(testCase.name) belongs to cmux find routing, not browser-first routing"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingFallsBackToKeyCodeForNonLatinInput() {
        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "",
            charactersIgnoringModifiers: "п", // Cyrillic p from a non-Latin input source
            keyCode: 5 // kVK_ANSI_G
        )

        XCTAssertTrue(
            shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
            "Expected browser-first routing to keep Cmd+G eligible under non-Latin input"
        )
    }

    func testBrowserFirstFindShortcutRoutingDoesNotUseANSIPositionsForMismatchedASCIICharacters() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-u-on-ansi-f", [.command], "u", 3),
            ("cmd-o-on-ansi-g", [.command], "o", 5),
            ("cmd-period-on-ansi-e", [.command], ".", 14),
            ("cmd-shift-u-on-ansi-f", [.command, .shift], "u", 3),
            ("cmd-shift-o-on-ansi-g", [.command, .shift], "o", 5),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )

            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Did not expect browser-first routing for mismatched ASCII shortcut \(testCase.name)"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingExcludesWebInspectorResponders() {
        let inspectorContainer = FakeWKInspectorContainerView(frame: .zero)
        let inspectorChild = NSView(frame: .zero)
        inspectorContainer.addSubview(inspectorChild)

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "g",
            charactersIgnoringModifiers: "g",
            keyCode: 5
        )

        XCTAssertFalse(
            shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
                event,
                responder: inspectorChild
            ),
            "Did not expect browser-first routing while a Web Inspector responder is focused"
        )
    }

    func testBrowserFirstFindShortcutRoutingExcludesNonFindCommands() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-n", [.command], "n", 45),
            ("cmd-w", [.command], "w", 13),
            ("cmd-l", [.command], "l", 37),
            ("cmd-option-f", [.command, .option], "f", 3),
            ("cmd-shift-g-toggle-react-grab", [.command, .shift], "g", 5),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )
            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Did not expect browser-first routing for \(testCase.name)"
            )
        }
    }

    func testInlineVSCodeCommandPaletteShortcutRoutesThroughWebContentForTrackedServeWebOrigin() {
        let event = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "P",
            charactersIgnoringModifiers: "p",
            keyCode: 35
        )
        let pageURL = URL(string: "http://127.0.0.1:63266/?folder=%2FUsers%2Ftester%2Fproject")!

        XCTAssertTrue(
            shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
                event,
                pageURL: pageURL,
                inlineVSCodeURLMatcher: { $0 == pageURL },
                shortcutForAction: { action in
                    XCTAssertEqual(action, .commandPalette)
                    return StoredShortcut(key: "p", command: true, shift: true, option: false, control: false, keyCode: 35)
                }
            ),
            "Expected Cmd+Shift+P to stay inside inline VS Code when the focused browser URL belongs to the live serve-web process"
        )
    }

    func testInlineVSCodeCommandPaletteShortcutDoesNotRouteForUntrackedLocalhostPage() {
        let event = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "P",
            charactersIgnoringModifiers: "p",
            keyCode: 35
        )
        let pageURL = URL(string: "http://127.0.0.1:3000/?folder=%2FUsers%2Ftester%2Fproject")!

        XCTAssertFalse(
            shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
                event,
                pageURL: pageURL,
                inlineVSCodeURLMatcher: { _ in false },
                shortcutForAction: { _ in
                    StoredShortcut(key: "p", command: true, shift: true, option: false, control: false, keyCode: 35)
                }
            ),
            "A localhost page with a folder query must not steal cmux's command palette shortcut unless it is the tracked VS Code serve-web origin"
        )
    }

    func testInlineVSCodeCommandPaletteShortcutDoesNotRouteUnrelatedShortcut() {
        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "l",
            charactersIgnoringModifiers: "l",
            keyCode: 37
        )
        let pageURL = URL(string: "http://127.0.0.1:63266/?folder=%2FUsers%2Ftester%2Fproject")!

        XCTAssertFalse(
            shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
                event,
                pageURL: pageURL,
                inlineVSCodeURLMatcher: { $0 == pageURL },
                shortcutForAction: { _ in
                    StoredShortcut(key: "p", command: true, shift: true, option: false, control: false, keyCode: 35)
                }
            ),
            "Only the configured command palette shortcut should bypass cmux for inline VS Code"
        )
    }

    // MARK: - Non-Latin keyboard layout shortcut tests

}
