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
private final class CanvasRoutingViewportSpy: CanvasViewportControlling {
    var revealedPanelIds: [UUID] = []
    var resetZoomCount = 0
    var currentMagnification: CGFloat = 1
    var currentCenterInCanvas: CGPoint = .zero

    func revealPane(_ panelId: UUID, animated: Bool) { revealedPanelIds.append(panelId) }
    func resetZoom() { resetZoomCount += 1 }
    func toggleOverview() {}
    func zoom(by factor: CGFloat) {}
    func setViewport(center: CGPoint, magnification: CGFloat?) {}
    func modelDidChangeExternally(animated: Bool) {}
}

@Suite("Canvas shortcut context")
struct CanvasShortcutContextTests {
    @Test
    func canvasOnlyShortcutDefaultWhenClausesRequireCanvasLayout() {
        var splitContext = ShortcutFocusState(browser: false, markdown: false, sidebar: false).context
        splitContext.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, false)

        var canvasContext = ShortcutFocusState(browser: false, markdown: false, sidebar: false).context
        canvasContext.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, true)

        #expect(
            KeyboardShortcutSettings.effectiveWhenClause(for: .toggleCanvasLayout).evaluate(splitContext),
            "The layout toggle must stay available outside canvas mode"
        )

        for action in KeyboardShortcutSettings.Action.canvasActions where action != .toggleCanvasLayout {
            let clause = KeyboardShortcutSettings.effectiveWhenClause(for: action)
            #expect(
                !clause.evaluate(splitContext),
                "\(action.rawValue) must not claim its shortcut while the workspace uses split layout"
            )
            #expect(
                clause.evaluate(canvasContext),
                "\(action.rawValue) must be available when the workspace uses canvas layout"
            )
        }
    }

    @Test
    func canvasLayoutContextOverlapsNormalTerminalFocusShortcuts() {
        let canvas = KeyboardShortcutSettings.Action.canvasOverview.shortcutContext
        let nonBrowser = KeyboardShortcutSettings.Action.renameTab.shortcutContext
        let browser = KeyboardShortcutSettings.Action.browserReload.shortcutContext
        let markdown = KeyboardShortcutSettings.Action.markdownZoomIn.shortcutContext
        let sidebar = KeyboardShortcutSettings.Action.fileExplorerOpenSelection.shortcutContext

        #expect(canvas == .canvasLayout)
        #expect(nonBrowser == .nonBrowserPanel)
        #expect(canvas.isAvailable(
            focusedBrowserPanel: false,
            focusedMarkdownPanel: false,
            rightSidebarFocused: false,
            workspaceCanvasLayout: true
        ))
        #expect(nonBrowser.isAvailable(
            focusedBrowserPanel: false,
            focusedMarkdownPanel: false,
            rightSidebarFocused: false,
            workspaceCanvasLayout: true
        ))
        #expect(canvas.overlaps(nonBrowser))
        #expect(nonBrowser.overlaps(canvas))
        #expect(canvas.overlaps(browser))
        #expect(browser.overlaps(canvas))
        #expect(canvas.overlaps(markdown))
        #expect(markdown.overlaps(canvas))
        #expect(canvas.overlaps(sidebar))
        #expect(sidebar.overlaps(canvas))
    }

    @Test
    func canvasActualSizeSharesCommandZeroWithBrowserAndMarkdownActualSize() {
        let canvasActualSize = KeyboardShortcutSettings.Action.canvasZoomReset.defaultShortcut
        let browserActualSize = KeyboardShortcutSettings.Action.browserZoomReset.defaultShortcut
        let markdownActualSize = KeyboardShortcutSettings.Action.markdownZoomReset.defaultShortcut
        let canvasActualSizeContext = KeyboardShortcutSettings.Action.canvasZoomReset.shortcutContext
        let canvasActualSizeWhen = KeyboardShortcutSettings.effectiveWhenClause(for: .canvasZoomReset)
        var backgroundCanvasContext = ShortcutFocusState(browser: false, markdown: false, sidebar: false).context
        backgroundCanvasContext.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, true)
        var browserCanvasContext = ShortcutFocusState(browser: true, markdown: false, sidebar: false).context
        browserCanvasContext.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, true)
        var markdownCanvasContext = ShortcutFocusState(browser: false, markdown: true, sidebar: false).context
        markdownCanvasContext.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, true)

        #expect(canvasActualSize == StoredShortcut(key: "0", command: true, shift: false, option: false, control: false))
        #expect(browserActualSize == canvasActualSize)
        #expect(markdownActualSize == canvasActualSize)
        #expect(canvasActualSizeContext == .canvasLayoutOutsideFocusedContent)
        #expect(canvasActualSizeWhen.evaluate(backgroundCanvasContext))
        #expect(!canvasActualSizeWhen.evaluate(browserCanvasContext))
        #expect(!canvasActualSizeWhen.evaluate(markdownCanvasContext))
        #expect(!KeyboardShortcutSettings.Action.browserZoomReset.conflicts(
            with: canvasActualSize,
            proposedAction: .canvasZoomReset,
            configuredShortcut: browserActualSize
        ))
        #expect(!KeyboardShortcutSettings.Action.markdownZoomReset.conflicts(
            with: canvasActualSize,
            proposedAction: .canvasZoomReset,
            configuredShortcut: markdownActualSize
        ))
    }
}

@MainActor
@Suite(.serialized)
struct CanvasShortcutRoutingFeedbackTests {
    @Test func canvasSurfaceDigitsWinOverRightSidebarModeDigitsInCanvasMode() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let firstPanelId = try #require(workspace.focusedPanelId)
            let event = try #require(makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: window.windowNumber))

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            let secondPanelId = try #require(workspace.openNewCanvasPane(type: .terminal, focus: true))
            #expect(workspace.focusedPanelId == secondPanelId)

            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: window)
            let fileExplorerState = try #require(appDelegate.fileExplorerState)
            fileExplorerState.mode = .sessions

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(workspace.focusedPanelId == firstPanelId)
            #expect(
                fileExplorerState.mode == .sessions,
                "Ctrl+1 should select the first Canvas surface instead of switching the right sidebar to Files in canvas mode"
            )
        }
    }

    @Test func directionalFocusShortcutInCanvasRevealsTargetPane() throws {
        try withTemporaryShortcut(action: .focusRight) {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let firstPanelId = try #require(workspace.focusedPanelId)
            let event = try #require(makeKeyDownEvent(
                key: "→",
                modifiers: [.command, .option],
                keyCode: 124,
                windowNumber: window.windowNumber
            ))

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            let secondPanelId = try #require(workspace.openNewCanvasPane(type: .terminal, focus: true, direction: .right))
            let viewport = CanvasRoutingViewportSpy()
            workspace.canvasModel.viewport = viewport
            workspace.focusPanel(firstPanelId)

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(workspace.focusedPanelId == secondPanelId)
            #expect(viewport.revealedPanelIds.last == secondPanelId)
        }
    }

    @Test func cmdZeroInCanvasResetsCanvasZoom() throws {
        try withTemporaryShortcut(action: .canvasZoomReset) {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let event = try #require(makeKeyDownEvent(
                key: "0",
                modifiers: [.command],
                keyCode: 29,
                windowNumber: window.windowNumber
            ))

            window.makeKeyAndOrderFront(nil)
            workspace.setLayoutMode(.canvas)
            let viewport = CanvasRoutingViewportSpy()
            workspace.canvasModel.viewport = viewport

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(viewport.resetZoomCount == 1)
        }
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags = [.control],
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func withTemporaryShortcut(action: KeyboardShortcutSettings.Action, _ body: () throws -> Void) rethrows {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            hadPersistedShortcut ? KeyboardShortcutSettings.setShortcut(originalShortcut, for: action) : KeyboardShortcutSettings.resetShortcut(for: action)
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        KeyboardShortcutSettings.setShortcut(action.defaultShortcut, for: action)
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        try body()
    }

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
        let actions = Set(KeyboardShortcutSettings.Action.allCases.filter { UserDefaults.standard.object(forKey: $0.defaultsKey) != nil })
        let saved = Dictionary(uniqueKeysWithValues: actions.map { ($0, KeyboardShortcutSettings.shortcut(for: $0)) })
        let originalStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cmux-canvas-shortcut-routing")
        KeyboardShortcutSettings.resetAll()
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalStore
            for action in KeyboardShortcutSettings.Action.allCases {
                if actions.contains(action), let shortcut = saved[action] {
                    KeyboardShortcutSettings.setShortcut(shortcut, for: action)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: action)
                }
            }
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        try body()
    }

    private func mainWindow(for windowId: UUID) -> NSWindow? {
        AppDelegate.shared?.windowForMainWindowId(windowId)
    }

    private func closeWindow(withId windowId: UUID) {
        mainWindow(for: windowId)?.close()
    }
}
