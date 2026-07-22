import AppKit
import Carbon.HIToolbox
import CmuxCanvasUI
import CmuxCommandPalette
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
    var overviewToggleCount = 0
    var isOverviewEnabled = false
    var resetZoomCount = 0
    var currentMagnification: CGFloat = 1
    var currentCenterInCanvas: CGPoint = .zero

    func revealPane(_ panelId: UUID, animated: Bool) { revealedPanelIds.append(panelId) }
    func resetZoom() { resetZoomCount += 1 }
    func toggleOverview() {
        overviewToggleCount += 1
        isOverviewEnabled.toggle()
    }
    func zoom(by factor: CGFloat) {}
    func setViewport(center: CGPoint, magnification: CGFloat?) {}
    func modelDidChangeExternally(animated: Bool) {}
}

@Suite("Canvas shortcut context")
struct CanvasShortcutContextTests {
    @Test
    @MainActor
    func viewportActionsReportAnUnmountedCanvasTarget() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panelID = try #require(workspace.focusedPanelId)
        workspace.setLayoutMode(.canvas)
        workspace.canvasModel.viewport = nil
        let executor = CanvasActionExecutor(workspace: workspace)

        for action in [
            CanvasAction.revealFocusedPane,
            .toggleOverview,
            .zoomIn,
            .zoomOut,
            .zoomReset,
        ] {
            #expect(
                executor.performWithOutcome(action, targetPanelID: panelID) == .targetUnavailable,
                "\(action) must not report success without a mounted viewport"
            )
            #expect(!executor.perform(action, targetPanelID: panelID))
        }
    }

    @Test
    @MainActor
    func paletteReportsEveryCanvasExecutorOutcomePrecisely() {
        let result = ContentView.commandPaletteCanvasResult(.notApplicable)

        guard case .failed(let code, _) = result else {
            Issue.record("Expected a typed not-applicable failure")
            return
        }
        #expect(code == "not_applicable")
        #expect(
            ContentView.commandPaletteCanvasResult(.completed) == .completed
        )
        #expect(
            ContentView.commandPaletteCanvasResult(.targetUnavailable) == .targetUnavailable
        )
    }

    @Test
    func canvasTogglesDeclareAnOptionalBooleanState() throws {
        let contributions = ContentView.commandPaletteCanvasCommandContributions()
        let enabledArgument = CmuxActionArgumentDefinition(
            name: "enabled",
            valueType: .boolean,
            required: false
        )
        let toggleIDs = ["palette.canvas.toggleLayout", "palette.canvas.overview"]

        for commandID in toggleIDs {
            let contribution = try #require(
                contributions.first(where: { $0.commandId == commandID })
            )
            #expect(contribution.arguments == [enabledArgument])
        }
        for contribution in contributions where !toggleIDs.contains(contribution.commandId) {
            #expect(contribution.arguments.isEmpty)
        }
    }

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
        var filePreviewTextEditorCanvasContext = ShortcutFocusState(browser: false, markdown: false, sidebar: false, filePreviewTextEditor: true).context
        filePreviewTextEditorCanvasContext.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, true)
        let browserActualSizeWhen = KeyboardShortcutSettings.effectiveWhenClause(for: .browserZoomReset)

        #expect(canvasActualSize == StoredShortcut(key: "0", command: true, shift: false, option: false, control: false))
        #expect(browserActualSize == canvasActualSize)
        #expect(markdownActualSize == canvasActualSize)
        #expect(canvasActualSizeContext == .canvasLayoutOutsideFocusedContent)
        #expect(canvasActualSizeWhen.evaluate(backgroundCanvasContext))
        #expect(!canvasActualSizeWhen.evaluate(browserCanvasContext))
        #expect(!canvasActualSizeWhen.evaluate(markdownCanvasContext))
        #expect(!canvasActualSizeWhen.evaluate(filePreviewTextEditorCanvasContext))
        #expect(browserActualSizeWhen.evaluate(filePreviewTextEditorCanvasContext))
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
    @Test func paletteFailsPreciselyWhenItsExactBackgroundCanvasIsUnmounted() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(manager.tabs.first)
        let targetWorkspace = manager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false
        )
        let targetPanelID = try #require(targetWorkspace.focusedPanelId)
        targetWorkspace.setLayoutMode(.canvas)
        targetWorkspace.canvasModel.viewport = nil

        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        AppDelegate.shared = appDelegate
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }

        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: targetWorkspace.id,
                panelID: targetPanelID
            ),
            tabManager: manager,
            owningWindowID: windowID
        )
        let contentView = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: windowID
        )
        var registry = CommandPaletteHandlerRegistry()
        contentView.registerCanvasCommandHandlers(&registry, context: context)
        let handler = try #require(registry.handler(for: "palette.canvas.zoomIn"))

        for source in [CmuxActionInvocationSource.automation, .commandPalette] {
            let result = handler(CmuxActionInvocation(source: source))
            guard case .failed(let code, _) = result else {
                Issue.record("Expected an unmounted exact canvas target to fail for \(source)")
                continue
            }
            #expect(code == "target_unavailable")
        }
        #expect(manager.selectedWorkspace?.id == selectedWorkspace.id)
    }

    @Test func everyCanvasPaletteHandlerReportsAConcreteOutcome() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panelID = try #require(workspace.focusedPanelId)
        let viewport = CanvasRoutingViewportSpy()
        workspace.canvasModel.viewport = viewport

        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        AppDelegate.shared = appDelegate
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }

        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                panelID: panelID
            ),
            tabManager: manager,
            owningWindowID: windowID
        )
        let contentView = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: windowID
        )
        var registry = CommandPaletteHandlerRegistry()
        contentView.registerCanvasCommandHandlers(&registry, context: context)

        for contribution in ContentView.commandPaletteCanvasCommandContributions() {
            let handler = try #require(registry.handler(for: contribution.commandId))
            for source in [CmuxActionInvocationSource.automation, .commandPalette] {
                workspace.setLayoutMode(.canvas)
                let result = handler(CmuxActionInvocation(source: source))
                switch result {
                case .completed, .failed:
                    break
                case .queued, .presented,
                     .requiresArguments, .invalidArguments, .invalidArgumentValues:
                    Issue.record(
                        "\(contribution.commandId) returned non-final canvas outcome \(result) for \(source)"
                    )
                }
            }
        }

        let layoutHandler = try #require(
            registry.handler(for: "palette.canvas.toggleLayout")
        )
        workspace.setLayoutMode(.splits)
        #expect(
            layoutHandler(CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "true"]
            )) == .completed
        )
        #expect(workspace.layoutMode == .canvas)
        #expect(
            layoutHandler(CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "true"]
            )) == .completed
        )
        #expect(workspace.layoutMode == .canvas)
        #expect(
            layoutHandler(CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "false"]
            )) == .completed
        )
        #expect(workspace.layoutMode == .splits)
        #expect(
            layoutHandler(CmuxActionInvocation(source: .commandPalette)) == .completed
        )
        #expect(workspace.layoutMode == .canvas)

        let overviewHandler = try #require(
            registry.handler(for: "palette.canvas.overview")
        )
        viewport.isOverviewEnabled = false
        viewport.overviewToggleCount = 0
        #expect(
            overviewHandler(CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "true"]
            )) == .completed
        )
        #expect(viewport.isOverviewEnabled)
        #expect(viewport.overviewToggleCount == 1)
        #expect(
            overviewHandler(CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "true"]
            )) == .completed
        )
        #expect(viewport.isOverviewEnabled)
        #expect(viewport.overviewToggleCount == 1)
        #expect(
            overviewHandler(CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "false"]
            )) == .completed
        )
        #expect(!viewport.isOverviewEnabled)
        #expect(viewport.overviewToggleCount == 2)
        #expect(
            overviewHandler(CmuxActionInvocation(source: .commandPalette)) == .completed
        )
        #expect(viewport.isOverviewEnabled)
        #expect(viewport.overviewToggleCount == 3)
    }

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

    @Test func cmdZeroInCanvasDoesNotResetCanvasZoomWhenTextPreviewEditorIsFocused() throws {
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

            let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
            let fileURL = try temporaryTextFile(contents: "preview text")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let panel = try #require(workspace.newFilePreviewSurface(
                inPane: firstPane,
                filePath: fileURL.path,
                focus: true
            ))

            let textView = SavingTextView.makeFilePreviewTextView()
            textView.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
            textView.string = "preview text"
            textView.panel = panel
            panel.attachTextView(textView)
            window.contentView?.addSubview(textView)
            defer { textView.removeFromSuperview() }
            #expect(window.makeFirstResponder(textView))
            #expect(workspace.focusedPanelId == panel.id)
            #expect(manager.focusedTextFilePreviewPanel === panel)

#if DEBUG
            _ = appDelegate.debugHandleCustomShortcut(event: event)
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(viewport.resetZoomCount == 0)
        }
    }

    @Test func cmdZeroInCanvasResetsCanvasZoomWhenMarkdownSourceEditorIsFocused() throws {
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

            let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
            let fileURL = try temporaryMarkdownFile(contents: "# Preview\n")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let panel = try #require(workspace.newMarkdownSurface(
                inPane: firstPane,
                filePath: fileURL.path,
                focus: true
            ))
            panel.setDisplayMode(.text)

            let textView = SavingTextView.makeFilePreviewTextView()
            textView.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
            textView.string = panel.textContent
            textView.panel = panel
            panel.attachTextView(textView)
            window.contentView?.addSubview(textView)
            defer { textView.removeFromSuperview() }
            #expect(window.makeFirstResponder(textView))
            #expect(workspace.focusedPanelId == panel.id)
            #expect(manager.focusedTextFilePreviewPanel == nil)

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(viewport.resetZoomCount == 1)
        }
    }

    @Test func chordedViewZoomShortcutZoomsFocusedTextPreviewThroughAppRouter() throws {
        try withIsolatedShortcutSettings {
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(
                    first: ShortcutStroke(
                        key: "k",
                        command: false,
                        shift: false,
                        option: false,
                        control: true,
                        keyCode: UInt16(kVK_ANSI_K)
                    ),
                    second: ShortcutStroke(
                        key: "=",
                        command: true,
                        shift: false,
                        option: false,
                        control: false,
                        keyCode: UInt16(kVK_ANSI_Equal)
                    )
                ),
                for: .browserZoomIn
            )

            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
            let fileURL = try temporaryTextFile(contents: "preview text")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let panel = try #require(workspace.newFilePreviewSurface(
                inPane: firstPane,
                filePath: fileURL.path,
                focus: true
            ))

            let textView = SavingTextView.makeFilePreviewTextView()
            textView.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
            textView.string = "preview text"
            textView.panel = panel
            panel.attachTextView(textView)
            window.contentView?.addSubview(textView)
            defer { textView.removeFromSuperview() }
            window.makeKeyAndOrderFront(nil)
            #expect(window.makeFirstResponder(textView))
            #expect(workspace.focusedPanelId == panel.id)
            #expect(manager.focusedTextFilePreviewPanel === panel)

            let initialPointSize = try #require(textView.font?.pointSize)
            let prefix = try #require(makeKeyDownEvent(
                key: "k",
                modifiers: [.control],
                keyCode: UInt16(kVK_ANSI_K),
                windowNumber: window.windowNumber
            ))
            let suffix = try #require(makeKeyDownEvent(
                key: "=",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_Equal),
                windowNumber: window.windowNumber
            ))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: prefix))
            #expect(abs((textView.font?.pointSize ?? 0) - initialPointSize) < 0.01)
            #expect(appDelegate.debugHandleCustomShortcut(event: suffix))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            let zoomedPointSize = try #require(textView.font?.pointSize)
            #expect(zoomedPointSize > initialPointSize)
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

    private func temporaryTextFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func temporaryMarkdownFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
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
