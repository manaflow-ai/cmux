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

// MARK: - Text box focus and escape routing tests
extension AppDelegateShortcutRoutingTests {
    func testFocusTextBoxShortcutMovesFocusBackToTerminalWhenTextBoxIsFirstResponder() {
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
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        textBoxView.onToggleFocus = { _ = terminalPanel.focusTextBoxInputOrTerminal() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before TextBox focus"
        )

        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        XCTAssertTrue(window.firstResponder === textBoxView, "Expected TextBox to own first responder")
        XCTAssertEqual(
            terminalPanel.captureFocusIntent(in: window),
            .terminal(.textBoxInput),
            "TextBox focus must be represented as a terminal panel focus intent"
        )

        let focusTextBoxShortcut = StoredShortcut(
            key: "a",
            command: true,
            shift: true,
            option: false,
            control: false,
            keyCode: 0
        )
        guard let event = makeKeyDownEvent(
            shortcut: focusTextBoxShortcut,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+A event")
            return
        }

        withTemporaryShortcut(action: .focusTextBoxInput, shortcut: focusTextBoxShortcut) {
            window.sendEvent(event)
        }
        waitFor(
            timeout: 1.0,
            until: { terminalPanel.hostedView.isSurfaceViewFirstResponder() }
        )

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Cmd+Shift+A from TextBox must move AppKit first responder back to the terminal"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Terminal must be the only focused input endpoint")
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.surface))
    }

    func testTextBoxSecondEscapeDoesNotHideWhenAnotherResponderOwnsFocus() {
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
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        let otherView = FocusableTestView(frame: NSRect(x: 0, y: 36, width: 120, height: 24))
        contentView.addSubview(textBoxScrollView)
        contentView.addSubview(otherView)
        defer {
            textBoxScrollView.removeFromSuperview()
            otherView.removeFromSuperview()
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        XCTAssertTrue(window.firstResponder === textBoxView)
        terminalPanel.handleTextBoxEscape()
        XCTAssertTrue(terminalPanel.isTextBoxActive)
        XCTAssertTrue(window.makeFirstResponder(otherView))

        XCTAssertFalse(terminalPanel.consumeTextBoxHideEscapeIfArmed(in: window))
        XCTAssertTrue(
            terminalPanel.isTextBoxActive,
            "Second Escape must not hide TextBox while another main-window control owns focus"
        )
    }

    func testTextBoxSecondEscapeHidesWhenTerminalSurfaceOwnsFocus() {
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
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        terminalPanel.handleTextBoxEscape()
        waitFor(
            timeout: 1.0,
            until: { terminalPanel.hostedView.isSurfaceViewFirstResponder() }
        )

        XCTAssertTrue(terminalPanel.hostedView.isSurfaceViewFirstResponder())
        XCTAssertTrue(terminalPanel.consumeTextBoxHideEscapeIfArmed(in: window))
        XCTAssertFalse(terminalPanel.isTextBoxActive)
    }

    func testTextBoxSecondEscapeAfterFocusMovesToAnotherSplitClearsArmWithoutHiding() {
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
              let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal, focus: false) else {
            XCTFail("Expected split terminal panels")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        leftPanel.hostedView.setVisibleInUI(true)
        leftPanel.hostedView.setActive(true)
        leftPanel.hostedView.moveFocus()
        leftPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(leftPanel.toggleTextBoxInput())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })

        leftPanel.handleTextBoxEscape()
        XCTAssertTrue(leftPanel.isTextBoxActive)
#if DEBUG
        XCTAssertTrue(leftPanel.debugHasTextBoxHideEscapeArm)
#endif
        workspace.focusPanel(rightPanel.id)
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
#if DEBUG
        XCTAssertFalse(leftPanel.debugHasTextBoxHideEscapeArm)
#endif

        XCTAssertFalse(manager.consumeFocusedTerminalTextBoxHideEscapeIfArmed(in: window))
        XCTAssertTrue(
            leftPanel.isTextBoxActive,
            "Escape after moving to another split should not hide or refocus the stale split"
        )
    }

    func testTextBoxFilePanelFocusRestorerRefocusesAfterSheetEnds() {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let otherView = FocusableTestView(frame: NSRect(x: 0, y: 40, width: 320, height: 40))
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textBoxScrollView.documentView = textView
        contentView.addSubview(otherView)
        contentView.addSubview(textBoxScrollView)
        hostWindow.animationBehavior = .none
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = contentView
        hostWindow.makeKeyAndOrderFront(nil)
        Self.retainedTextBoxUndoWindows.append(hostWindow)
        defer { hostWindow.orderOut(nil) }

        XCTAssertTrue(hostWindow.makeFirstResponder(otherView))
        XCTAssertTrue(hostWindow.firstResponder === otherView)

        let restorer = TextBoxFilePanelFocusRestorer(textView: textView)
        restorer.install(parentWindow: hostWindow)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: hostWindow)
        waitFor(timeout: 1.0, until: { hostWindow.firstResponder === textView })

        XCTAssertTrue(hostWindow.firstResponder === textView)

        XCTAssertTrue(hostWindow.makeFirstResponder(otherView))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: hostWindow)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(hostWindow.firstResponder === otherView)
    }

    func testFocusTextBoxShortcutRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstPanel = firstManager.selectedWorkspace?.focusedTerminalPanel,
              let secondPanel = secondManager.selectedWorkspace?.focusedTerminalPanel else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        let focusTextBoxShortcut = StoredShortcut(
            key: "a",
            command: true,
            shift: true,
            option: false,
            control: false,
            keyCode: 0
        )
        guard let event = makeKeyDownEvent(
            shortcut: focusTextBoxShortcut,
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+A event")
            return
        }

        withTemporaryShortcut(action: .focusTextBoxInput, shortcut: focusTextBoxShortcut) {
#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        XCTAssertFalse(firstPanel.isTextBoxActive, "Cmd+Shift+A must not activate TextBox in the stale active window")
        XCTAssertTrue(secondPanel.isTextBoxActive, "Cmd+Shift+A should activate TextBox in the event window")
    }

    func testTextBoxFocusIntentRestoresAfterYieldToAnotherPanel() {
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
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)

        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        XCTAssertTrue(window.firstResponder === textBoxView, "Expected TextBox focus before yielding")
        XCTAssertTrue(terminalPanel.yieldFocusIntent(.terminal(.textBoxInput), in: window))
        XCTAssertFalse(window.firstResponder === textBoxView, "Yielding to another panel must release AppKit first responder")
        XCTAssertEqual(
            terminalPanel.preferredFocusIntentForActivation(),
            .terminal(.textBoxInput),
            "Yielding TextBox focus should preserve the user's preferred left-pane input target"
        )

        XCTAssertTrue(terminalPanel.restoreFocusIntent(.terminal(.textBoxInput)))
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )
        XCTAssertTrue(window.firstResponder === textBoxView, "Returning to the panel should restore TextBox focus")
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.textBoxInput))
    }

    func testTextBoxShortcutReturnsToTextBoxAfterTerminalRegainsFocus() {
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
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })

        XCTAssertTrue(window.makeFirstResponder(terminalView))
        terminalPanel.terminalDidBecomeFocused()
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.surface))

        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })
        XCTAssertTrue(window.firstResponder === textBoxView, "Shortcut should focus the TextBox after terminal focus is recorded")
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.textBoxInput))
    }

    func testTextBoxFocusInNonFocusedSplitUpdatesFocusedPanel() {
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
              let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        workspace.focusPanel(leftPanel.id)
        waitFor(
            timeout: 1.0,
            until: { workspace.focusedPanelId == leftPanel.id }
        )
        XCTAssertEqual(workspace.focusedPanelId, leftPanel.id, "Test should start with the left split focused")

        let rightTextBoxInputView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        rightTextBoxInputView.onFocusTextBox = {
            rightPanel.textBoxDidBecomeFocused()
            workspace.focusPanel(rightPanel.id, trigger: .terminalFirstResponder)
        }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = rightTextBoxInputView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }
        rightPanel.registerTextBoxInputView(rightTextBoxInputView)

        window.makeFirstResponder(rightTextBoxInputView)
        waitFor(
            timeout: 2.0,
            until: {
                return workspace.focusedPanelId == rightPanel.id &&
                    window.firstResponder === rightTextBoxInputView
            }
        )

        XCTAssertEqual(
            workspace.focusedPanelId,
            rightPanel.id,
            "Focusing a TextBox in another split must move the workspace focus to its owning panel"
        )
        XCTAssertTrue(
            window.firstResponder === rightPanel.textBoxInputView,
            "The TextBox should remain the only focused input endpoint after the split focus update"
        )
        XCTAssertEqual(rightPanel.captureFocusIntent(in: window), .terminal(.textBoxInput))
    }

    func testTextBoxPendingFocusIsCanceledOnUnfocusBeforeViewRegisters() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
#if DEBUG
        XCTAssertTrue(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif
        terminalPanel.unfocus()
#if DEBUG
        XCTAssertFalse(
            terminalPanel.debugHasPendingTextBoxFocusRequest,
            "Panel unfocus must cancel stale pending TextBox focus and file picker requests"
        )
#endif
    }

    func testTextBoxPendingFocusRunsWhenTextViewMovesToWindow() {
        let terminalPanel = TerminalPanel(workspaceId: UUID())
        defer { terminalPanel.surface.teardownSurface() }

        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
#if DEBUG
        XCTAssertTrue(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textView.onMoveToWindow = { [weak terminalPanel] view in
            terminalPanel?.textBoxInputViewDidMoveToWindow(view)
        }
        terminalPanel.registerTextBoxInputView(textView)
#if DEBUG
        XCTAssertTrue(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif

        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostWindow.animationBehavior = .none
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        hostWindow.contentView?.addSubview(textBoxScrollView)
        hostWindow.makeKeyAndOrderFront(nil)
        Self.retainedTextBoxUndoWindows.append(hostWindow)
        defer {
            textView.onMoveToWindow = { _ in }
            hostWindow.orderOut(nil)
        }
        textBoxScrollView.documentView = textView
        XCTAssertTrue(textView.window === hostWindow)

#if DEBUG
        waitFor(timeout: 1.0, until: {
            hostWindow.firstResponder === textView
                && !terminalPanel.debugHasPendingTextBoxFocusRequest
        })
#else
        waitFor(timeout: 1.0, until: { hostWindow.firstResponder === textView })
#endif
        XCTAssertTrue(hostWindow.firstResponder === textView)
#if DEBUG
        XCTAssertFalse(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif
    }

    func testTextBoxFocusShortcutReportsUnhandledWhenTerminalCannotReceiveFocus() {
        let terminalPanel = TerminalPanel(workspaceId: UUID())
        defer { terminalPanel.surface.teardownSurface() }

        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
        XCTAssertFalse(
            terminalPanel.focusTextBoxInputOrTerminal(),
            "Returning from TextBox focus to the terminal should only consume the shortcut when terminal focus succeeds"
        )
    }

    func testTextBoxSessionRestoreShowsDraftWithoutStealingFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("restore me")]
        ))

        XCTAssertTrue(terminalPanel.isTextBoxActive)
        XCTAssertEqual(terminalPanel.textBoxContent, "restore me")
        XCTAssertEqual(terminalPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))
#if DEBUG
        XCTAssertFalse(
            terminalPanel.debugHasPendingTextBoxFocusRequest,
            "Visible restored TextBox drafts must not queue first-responder focus"
        )
#endif
    }

    func testFocusedTextBoxFirstEscapeBypassesTerminalFindShortcutHandling() {
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
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected a main window with a focused terminal")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })
        XCTAssertTrue(window.firstResponder === textBoxView)

        terminalPanel.searchState = TerminalSurface.SearchState(needle: "")
        defer { terminalPanel.searchState = nil }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: UInt16(kVK_Escape),
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            cmuxCloseFocusedTerminalFindForEscape(event: escapeEvent, appDelegate: appDelegate),
            "The app-level find escape preflight must not close find while TextBox owns focus"
        )
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertNotNil(terminalPanel.searchState, "First Escape should reach the TextBox instead of closing find")
    }

}
