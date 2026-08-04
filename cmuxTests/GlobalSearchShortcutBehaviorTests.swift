import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct GlobalSearchShortcutBehaviorTests {}

extension GlobalSearchShortcutBehaviorTests {
    @MainActor @Suite final class GlobalSearchLocalMonitorChainTests {
    private let originalSettingsFileStore: KeyboardShortcutSettingsFileStore

    init() {
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-monitor-chain-\(UUID().uuidString).json")
                .path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()
    }

    deinit {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    @Test func visibleSearchClosesForRemappedCommandShortcutThroughLocalMonitorChain() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        let shortcut = StoredShortcut(
            key: "j",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)
        #expect(
            KeyboardShortcutSettings.shortcut(for: .globalSearch) == shortcut,
            "The monitor-chain fixture must install a valid, unclaimed Command shortcut"
        )
        appDelegate.toggleGlobalSearchPalette()
        let popoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover and its local key monitor must be active"
        )

        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "j",
                modifiers: [.command],
                keyCode: 38,
                windowNumber: popoverWindow.windowNumber
            )
        )

        #expect(
            waitUntilGlobalSearchCloses(),
            "The popover monitor must route the configured toggle before consuming generic Command keys"
        )
#else
        Issue.record("Global Search local-monitor routing requires a DEBUG app-host build")
#endif
    }

    @Test func visibleSearchClosesForRemappedChordThroughLocalMonitorChain() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "k",
                command: true,
                shift: false,
                option: false,
                control: false,
                chordKey: "g"
            ),
            for: .globalSearch
        )
        appDelegate.toggleGlobalSearchPalette()
        let popoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover and its local key monitor must be active"
        )

        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "k",
                modifiers: [.command],
                keyCode: 40,
                windowNumber: popoverWindow.windowNumber
            )
        )
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())

        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "g",
                modifiers: [],
                keyCode: 5,
                windowNumber: popoverWindow.windowNumber
            )
        )

        #expect(
            waitUntilGlobalSearchCloses(),
            "The popover monitor must let the shared router arm and complete Global Search chords"
        )
#else
        Issue.record("Global Search local-monitor routing requires a DEBUG app-host build")
#endif
    }

    @Test func visibleSearchChordEditingSuffixCompletesThroughLocalMonitorChain() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "k",
                command: true,
                shift: false,
                option: false,
                control: false,
                chordKey: "c",
                chordCommand: true
            ),
            for: .globalSearch
        )
        appDelegate.toggleGlobalSearchPalette()
        let popoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover and its local key monitor must be active"
        )

        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "k",
                modifiers: [.command],
                keyCode: 40,
                windowNumber: popoverWindow.windowNumber
            )
        )
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())

        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "c",
                modifiers: [.command],
                keyCode: 8,
                windowNumber: popoverWindow.windowNumber
            )
        )

        #expect(
            waitUntilGlobalSearchCloses(),
            "An editing-key suffix must complete an already-active Global Search chord"
        )
#else
        Issue.record("Global Search local-monitor routing requires a DEBUG app-host build")
#endif
    }

    @Test func visibleSearchCompletesEditingSuffixFromPromotedChordState() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        let shortcut = StoredShortcut(
            key: "k",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "c",
            chordCommand: true
        )
        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)
        appDelegate.toggleGlobalSearchPalette()
        let popoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover and its local key monitor must be active"
        )
        appDelegate.activeConfiguredShortcutChordPrefixForCurrentEvent =
            shortcut.firstStroke

        let route = appDelegate.routeVisibleGlobalSearchShortcutFromLocalMonitor(
            try makeKeyDownEvent(
                key: "c",
                modifiers: [.command],
                keyCode: 8,
                windowNumber: popoverWindow.windowNumber
            )
        )

        guard case .handled = route else {
            Issue.record(
                "An editing-key suffix must complete a promoted Global Search chord"
            )
            return
        }
        #expect(waitUntilGlobalSearchCloses())
#else
        Issue.record("Global Search local-monitor routing requires a DEBUG app-host build")
#endif
    }

    @Test func unrelatedChordSuffixPreservesPendingPrefixForDownstreamMonitor() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        let shortcut = StoredShortcut(
            key: "k",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "g"
        )
        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)
        appDelegate.toggleGlobalSearchPalette()
        let popoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover and its local key monitor must be active"
        )
        let unrelatedSuffixEvent = try makeKeyDownEvent(
            key: "s",
            modifiers: [],
            keyCode: 1,
            windowNumber: popoverWindow.windowNumber
        )
        let chordWindowNumber = appDelegate.configuredShortcutChordWindowNumber(
            for: unrelatedSuffixEvent
        )
        appDelegate.pendingConfiguredShortcutChord = AppDelegate.PendingConfiguredShortcutChord(
            firstStroke: shortcut.firstStroke,
            windowNumber: chordWindowNumber
        )

        let route = appDelegate.routeVisibleGlobalSearchShortcutFromLocalMonitor(
            unrelatedSuffixEvent
        )

        guard case .notApplicable = route else {
            Issue.record("An unrelated suffix must continue to the downstream shortcut monitor")
            return
        }
        #expect(
            appDelegate.pendingConfiguredShortcutChord?.firstStroke == shortcut.firstStroke,
            "The Search popover monitor must not destroy another chord sharing the prefix"
        )
        #expect(
            appDelegate.pendingConfiguredShortcutChord?.windowNumber == chordWindowNumber
        )
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())
#else
        Issue.record("Global Search local-monitor routing requires a DEBUG app-host build")
#endif
    }

    private func makeMainWindow(appDelegate: AppDelegate) throws -> NSWindow {
        let windowId = appDelegate.createMainWindow()
        let identifier = "cmux.main.\(windowId.uuidString)"
        let window = try #require(
            NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
        )
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        return window
    }

    private func waitForSearchPopoverWindow(
        excluding mainWindow: NSWindow,
        timeout: TimeInterval = 2
    ) -> NSWindow? {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if let window = NSApp.windows.first(where: {
                $0 !== mainWindow
                    && $0.isVisible
                    && $0.firstResponder is NSTextView
            }) {
                return window
            }
            _ = RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date.now.addingTimeInterval(0.01))
            )
        } while Date.now < deadline
        return nil
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) throws -> NSEvent {
        try #require(
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
        )
    }

    private func waitUntilGlobalSearchCloses(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if !GlobalSearchCoordinator.shared.isPaletteVisible() {
                return true
            }
            _ = RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date.now.addingTimeInterval(0.01))
            )
        } while Date.now < deadline
        return !GlobalSearchCoordinator.shared.isPaletteVisible()
    }

    private func closeWindow(_ window: NSWindow, appDelegate: AppDelegate) {
        GlobalSearchCoordinator.shared.dismissPalette()
        _ = waitUntilGlobalSearchCloses()
#if DEBUG
        appDelegate.debugResetShortcutRoutingStateForTesting()
        let originalConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
#endif
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
    }
    }
}

extension GlobalSearchShortcutBehaviorTests {
    @MainActor
    @Test func reopeningSearchClearsRetainedQuery() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        appDelegate.toggleGlobalSearchPalette()
        let firstPopoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover must focus its query field"
        )
        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "z",
                modifiers: [],
                keyCode: 6,
                windowNumber: firstPopoverWindow.windowNumber
            )
        )
        #expect(
            waitForSearchFieldText("z", in: firstPopoverWindow),
            "The fixture must type through the real Search query field"
        )

        GlobalSearchCoordinator.shared.dismissPalette()
        #expect(waitUntilGlobalSearchCloses())
        appDelegate.toggleGlobalSearchPalette()
        let reopenedPopoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The retained Search popover must reopen with its query field focused"
        )

        #expect(
            waitForSearchFieldText("", in: reopenedPopoverWindow),
            "Each Search presentation must start with an empty query"
        )
#else
        Issue.record("Global Search lifecycle coverage requires a DEBUG app-host build")
#endif
    }

    @MainActor
    @Test func returnActivatesSelectedBrowseResultAfterReopen() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }
        let windowID = try #require(appDelegate.mainWindowId(from: window))
        let tabManager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        let targetWorkspace = tabManager.addWorkspace(
            title: "Return target \(UUID().uuidString)",
            select: false,
            eagerLoadTerminal: true,
            autoWelcomeIfNeeded: false
        )
        let targetPanelID = try #require(targetWorkspace.focusedPanelId)
        let browseResults = GlobalSearchCoordinator.shared.browseOpenPanels()
        let targetIndex = try #require(
            browseResults.firstIndex(where: {
                $0.workspaceID == targetWorkspace.id && $0.panelID == targetPanelID
            }),
            "The real main-window fixture must expose the inactive target in browse results"
        )

        appDelegate.toggleGlobalSearchPalette()
        _ = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The first Search presentation must show before it is closed"
        )
        GlobalSearchCoordinator.shared.dismissPalette()
        #expect(waitUntilGlobalSearchCloses())

        appDelegate.toggleGlobalSearchPalette()
        let reopenedPopoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The retained Search popover must reopen with a selected browse result"
        )
        for _ in 0..<targetIndex {
            NSApp.sendEvent(
                try makeKeyDownEvent(
                    key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                    modifiers: [],
                    keyCode: 125,
                    windowNumber: reopenedPopoverWindow.windowNumber
                )
            )
        }
        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "\r",
                modifiers: [],
                keyCode: 36,
                windowNumber: reopenedPopoverWindow.windowNumber
            )
        )

        #expect(
            waitUntilGlobalSearchCloses(),
            "Return must activate the selected result after the retained popover reopens"
        )
        #expect(
            tabManager.selectedWorkspace?.id == targetWorkspace.id,
            "Return must select the chosen result's workspace, not merely close Search"
        )
        #expect(targetWorkspace.focusedPanelId == targetPanelID)
#else
        Issue.record("Global Search lifecycle coverage requires a DEBUG app-host build")
#endif
    }

    @MainActor
    @Test func closingSearchPreventsInFlightSearchFromReplacingResults() async throws {
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        let refreshFinished = GlobalSearchAsyncSignal()
        let searchStarted = GlobalSearchAsyncSignal()
        let releaseSearch = GlobalSearchAsyncSignal()
        let debounce = ControlledGlobalSearchDebounceScheduler()
        let presentation = GlobalSearchPopoverPresentation(
            coordinator: GlobalSearchCoordinator.shared,
            refreshLiveIndex: { refreshFinished.signal() },
            search: { _ in
                searchStarted.signal()
                await releaseSearch.wait()
                return []
            },
            scheduleSearchDebounce: { _, action in
                debounce.schedule(action)
            }
        )
        defer {
            presentation.endPresentation()
            releaseSearch.signal()
            closeWindow(window, appDelegate: appDelegate)
        }

        presentation.beginPresentation()
        await refreshFinished.wait()
        try #require(
            !presentation.results.isEmpty,
            "The fixture must start with browse results that stale search work could replace"
        )
        let browseResults = presentation.results
        presentation.query = "missing\(UUID().uuidString)"
        debounce.fire()
        await searchStarted.wait()

        let cancelledSearchTask = try #require(
            presentation.endPresentation(),
            "The in-flight search task must remain awaitable after cancellation"
        )
        releaseSearch.signal()
        await cancelledSearchTask.value

        #expect(
            presentation.results == browseResults,
            "Canceled search work must finish without replacing the closed presentation's results"
        )
    }

    @MainActor
    @Test func everyPresentationRefreshesFullLiveIndex() async throws {
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        let refreshCount = GlobalSearchCounter()
        let presentation = GlobalSearchPopoverPresentation(
            coordinator: GlobalSearchCoordinator.shared,
            refreshLiveIndex: {
                refreshCount.increment()
            }
        )
        defer {
            presentation.endPresentation()
            closeWindow(window, appDelegate: appDelegate)
        }

        presentation.beginPresentation()
        #expect(
            await waitUntil { refreshCount.value == 1 },
            "The first presentation must refresh the complete live index"
        )
        presentation.endPresentation()

        presentation.beginPresentation()
        #expect(
            await waitUntil { refreshCount.value == 2 },
            "A retained popover must refresh the complete live index on every presentation"
        )
    }

    @MainActor
    @Test func newQueryResultsResetSelectionToFirstRow() async throws {
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        let refreshFinished = GlobalSearchAsyncSignal()
        let debounce = ControlledGlobalSearchDebounceScheduler()
        let firstHits = [
            makeSearchHit(id: "first-0", title: "First zero"),
            makeSearchHit(id: "first-1", title: "First one")
        ]
        let secondHits = [
            makeSearchHit(id: "second-0", title: "Second zero"),
            makeSearchHit(id: "second-1", title: "Second one")
        ]
        let presentation = GlobalSearchPopoverPresentation(
            coordinator: GlobalSearchCoordinator.shared,
            refreshLiveIndex: { refreshFinished.signal() },
            search: { query in
                query == "first" ? firstHits : secondHits
            },
            scheduleSearchDebounce: { _, action in
                debounce.schedule(action)
            }
        )
        defer {
            presentation.endPresentation()
            closeWindow(window, appDelegate: appDelegate)
        }

        presentation.beginPresentation()
        await refreshFinished.wait()
        presentation.query = "first"
        debounce.fire()
        #expect(
            await waitUntil { presentation.results.map(\.hit.id) == firstHits.map(\.id) }
        )
        presentation.selectResult(at: 1)
        #expect(presentation.selectedIndex == 1)

        presentation.query = "second"
        debounce.fire()
        #expect(
            await waitUntil { presentation.results.map(\.hit.id) == secondHits.map(\.id) }
        )
        #expect(
            presentation.selectedIndex == 0,
            "Replacing ranked results must not retain a selection made in the prior result set"
        )
    }

    @MainActor
    @Test func sameQueryIndexChangesCoalesceAndPreserveLatestSelection() async throws {
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        let refreshFinished = GlobalSearchAsyncSignal()
        let refreshSearchStarted = GlobalSearchAsyncSignal()
        let releaseRefreshSearch = GlobalSearchAsyncSignal()
        let debounce = ControlledGlobalSearchDebounceScheduler()
        let stableHit = makeSearchHit(id: "stable", title: "Stable")
        let initialHits = [
            makeSearchHit(id: "initial-0", title: "Initial zero"),
            stableHit,
            makeSearchHit(id: "initial-2", title: "Initial two")
        ]
        let updatedHits = [
            makeSearchHit(id: "updated-0", title: "Updated zero"),
            makeSearchHit(id: "updated-1", title: "Updated one"),
            stableHit
        ]
        let hitStore = GlobalSearchHitStore(hits: initialHits)
        let searchCount = GlobalSearchCounter()
        let presentation = GlobalSearchPopoverPresentation(
            coordinator: GlobalSearchCoordinator.shared,
            refreshLiveIndex: { refreshFinished.signal() },
            search: { _ in
                searchCount.increment()
                if searchCount.value == 2 {
                    refreshSearchStarted.signal()
                    await releaseRefreshSearch.wait()
                }
                return hitStore.hits
            },
            scheduleSearchDebounce: { _, action in
                debounce.schedule(action)
            }
        )
        defer {
            releaseRefreshSearch.signal()
            presentation.endPresentation()
            closeWindow(window, appDelegate: appDelegate)
        }

        presentation.beginPresentation()
        await refreshFinished.wait()
        presentation.query = "same"
        debounce.fire()
        #expect(
            await waitUntil {
                presentation.results.map(\.hit.id) == initialHits.map(\.id)
            }
        )

        hitStore.hits = updatedHits
        presentation.searchIndexDidChange()
        presentation.searchIndexDidChange()
        debounce.fire()
        await refreshSearchStarted.wait()
        presentation.selectResult(at: 1)
        releaseRefreshSearch.signal()

        #expect(
            await waitUntil {
                presentation.results.map(\.hit.id) == updatedHits.map(\.id)
            }
        )
        #expect(
            searchCount.value == 2,
            "Repeated index invalidations must coalesce into one rerun"
        )
        #expect(
            presentation.selectedIndex == 2,
            "A same-query rerun must follow the currently highlighted hit by stable ID"
        )
        #expect(presentation.results[presentation.selectedIndex].hit.id == stableHit.id)
    }

    @MainActor
    @Test func emptyQueryIndexChangesDoNotReloadBrowseResults() async throws {
        let appDelegate = try #require(AppDelegate.shared)
        let harness = try makeNamedMainWindow(
            appDelegate: appDelegate,
            initialWorkspaceTitle: "Browse first"
        )
        let tabManager = try #require(appDelegate.tabManagerFor(windowId: harness.windowID))
        _ = tabManager.addWorkspace(
            title: "Browse second",
            select: false,
            eagerLoadTerminal: true,
            autoWelcomeIfNeeded: false
        )
        let refreshCount = GlobalSearchCounter()
        let presentation = GlobalSearchPopoverPresentation(
            coordinator: GlobalSearchCoordinator.shared,
            refreshLiveIndex: { refreshCount.increment() }
        )
        defer {
            presentation.endPresentation()
            closeWindow(harness.window, appDelegate: appDelegate)
        }

        presentation.beginPresentation()
        #expect(await waitUntil { refreshCount.value == 1 })
        await Task.yield()
        try #require(presentation.results.count >= 2)
        presentation.selectResult(at: 1)
        let browseResultIDs = presentation.results.map(\.hit.id)

        presentation.searchIndexDidChange()
        await Task.yield()

        #expect(presentation.query.isEmpty)
        #expect(presentation.results.map(\.hit.id) == browseResultIDs)
        #expect(
            presentation.selectedIndex == 1,
            "Indexed content cannot change empty-query browse rows, so it must not reset their selection"
        )
    }

    @MainActor
    @Test func globalSearchContextsUseWorkspaceOwnedPanelTitles() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let harness = try makeNamedMainWindow(
            appDelegate: appDelegate,
            initialWorkspaceTitle: "Workspace"
        )
        defer { closeWindow(harness.window, appDelegate: appDelegate) }
        let tabManager = try #require(appDelegate.tabManagerFor(windowId: harness.windowID))
        let workspace = try #require(tabManager.selectedWorkspace)
        let panelID = try #require(workspace.panels.keys.first)
        let customTitle = "Custom \(UUID().uuidString)"
        #expect(workspace.setPanelCustomTitle(panelId: panelID, title: customTitle))

        let listedContext = try #require(
            appDelegate.globalSearchPanelContexts().first(where: {
                $0.windowID == harness.windowID && $0.panelID == panelID
            })
        )
        let resolvedContext = try #require(
            appDelegate.globalSearchContext(
                forPanelID: panelID,
                preferredWorkspaceID: workspace.id
            )
        )

        #expect(listedContext.panelTitle == customTitle)
        #expect(resolvedContext.panelTitle == customTitle)
    }

    @MainActor
    @Test func cancelledIndexDeletionsLeaveDocumentsIntact() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let index = try SearchIndex(databaseURL: directoryURL.appendingPathComponent("search.sqlite3"))
        let panelID = UUID()
        let panelDocument = makeSearchDocument(
            id: "panel-document",
            panelID: panelID,
            token: "panelcancellationtoken"
        )
        let singleDocument = makeSearchDocument(
            id: "single-document",
            panelID: UUID(),
            token: "documentcancellationtoken"
        )
        try await index.upsert(panelDocument)
        try await index.upsert(singleDocument)

        await expectCancelledMutation {
            try await index.deletePanel(panelID)
        }
        await expectCancelledMutation {
            try await index.deleteDocument(id: singleDocument.id)
        }
        await expectCancelledMutation {
            try await index.deleteAll()
        }

        #expect(try await index.search("panelcancellationtoken").map(\.id) == [panelDocument.id])
        #expect(try await index.search("documentcancellationtoken").map(\.id) == [singleDocument.id])
    }

    @MainActor
    @Test func reopeningSearchRefreshesLiveIndex() async throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let firstToken = "first\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let secondToken = "second\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let harness = try makeNamedMainWindow(
            appDelegate: appDelegate,
            initialWorkspaceTitle: firstToken
        )
        defer { closeWindow(harness.window, appDelegate: appDelegate) }
        let tabManager = try #require(appDelegate.tabManagerFor(windowId: harness.windowID))
        let firstWorkspace = try #require(tabManager.selectedWorkspace)

        appDelegate.toggleGlobalSearchPalette()
        _ = try #require(waitForSearchPopoverWindow(excluding: harness.window))
        #expect(
            await waitForSearchHit(query: firstToken, workspaceID: firstWorkspace.id),
            "The first presentation must finish its live-index refresh"
        )
        GlobalSearchCoordinator.shared.dismissPalette()
        #expect(waitUntilGlobalSearchCloses())

        let secondWorkspace = tabManager.addWorkspace(
            title: secondToken,
            select: false,
            eagerLoadTerminal: true,
            autoWelcomeIfNeeded: false
        )
        _ = try #require(
            appDelegate.globalSearchPanelContexts().first(where: {
                $0.workspaceID == secondWorkspace.id
            }),
            "The new workspace must be visible to the live-index source before reopen"
        )

        appDelegate.toggleGlobalSearchPalette()
        _ = try #require(waitForSearchPopoverWindow(excluding: harness.window))

        #expect(
            await waitForSearchHit(query: secondToken, workspaceID: secondWorkspace.id),
            "Every Search presentation must refresh panels created after the prior close"
        )
#else
        Issue.record("Global Search lifecycle coverage requires a DEBUG app-host build")
#endif
    }

    @MainActor
    @Test func initialMarkdownRefreshReturnsAfterContentIsSearchable() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let token = "markdown\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let fileURL = directoryURL.appendingPathComponent("notes.md")
        try "# Notes\n\n\(token)\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let workspaceID = UUID()
        let panel = MarkdownPanel(workspaceId: workspaceID, filePath: fileURL.path)
        let index = try SearchIndex(databaseURL: directoryURL.appendingPathComponent("search.sqlite3"))
        let captureManager = GlobalSearchPanelCaptureManager(
            indexProvider: { index },
            cancelPanelPurge: { _ in }
        )
        defer {
            captureManager.cancelCaptures(forPanelID: panel.id)
            panel.close()
        }
        let context = GlobalSearchPanelContext(
            windowID: UUID(),
            windowTitle: "Window",
            workspaceID: workspaceID,
            workspaceTitle: "Workspace",
            panelID: panel.id,
            panelTitle: panel.displayTitle,
            panel: panel
        )

        await captureManager.refreshPanelContent(for: context)

        #expect(
            try await index.search(token).contains(where: {
                $0.panelID == panel.id && $0.kind == .markdown
            }),
            "A completed live refresh must make a newly discovered Markdown panel searchable"
        )
    }

    @MainActor
    @Test func reopeningSearchRecapturesDynamicBrowserContent() async throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let firstToken = "browserfirst\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let secondToken = "browsersecond\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let html = "<html><head><title>Dynamic page</title></head><body>\(firstToken)</body></html>"
        let encodedHTML = try #require(html.data(using: .utf8)).base64EncodedString()
        let initialURL = try #require(URL(string: "data:text/html;base64,\(encodedHTML)"))
        let harness = try makeNamedMainWindow(
            appDelegate: appDelegate,
            initialWorkspaceTitle: "Browser workspace"
        )
        defer { closeWindow(harness.window, appDelegate: appDelegate) }
        let tabManager = try #require(appDelegate.tabManagerFor(windowId: harness.windowID))
        let workspace = try #require(tabManager.selectedWorkspace)
        let browserPanelID = try #require(
            tabManager.openBrowser(
                inWorkspace: workspace.id,
                url: initialURL,
                preferSplitRight: true
            )
        )
        let browserPanel = try #require(workspace.browserPanel(for: browserPanelID))

        #expect(
            await waitForBrowserBody(firstToken, panel: browserPanel),
            "The browser fixture must finish its initial same-document load"
        )
        await GlobalSearchCoordinator.shared.refreshLiveIndex()
        #expect(
            await waitForSearchHit(query: firstToken, workspaceID: workspace.id),
            "The first browser content capture must become searchable"
        )

        let updatedBody = try await browserPanel.evaluateJavaScript(
            "document.body.textContent = '\(secondToken)'; document.body.textContent"
        ) as? String
        #expect(updatedBody == secondToken)
        let staleHits = await GlobalSearchCoordinator.shared.search(query: secondToken)
        #expect(
            !staleHits.contains(where: { $0.panelID == browserPanel.id }),
            "The fixture must mutate the DOM without an automatic browser lifecycle capture"
        )

        let refreshFinished = GlobalSearchAsyncSignal()
        let debounce = ControlledGlobalSearchDebounceScheduler()
        let presentation = GlobalSearchPopoverPresentation(
            coordinator: GlobalSearchCoordinator.shared,
            refreshLiveIndex: {
                await GlobalSearchCoordinator.shared.refreshLiveIndex()
                refreshFinished.signal()
            },
            search: { query in
                await GlobalSearchCoordinator.shared.search(query: query)
            },
            scheduleSearchDebounce: { _, action in
                debounce.schedule(action)
            }
        )
        defer { presentation.endPresentation() }

        presentation.beginPresentation()
        presentation.query = secondToken
        await refreshFinished.wait()
        debounce.fire()

        #expect(
            await waitUntil {
                presentation.results.contains(where: {
                    $0.hit.panelID == browserPanel.id && $0.hit.kind == .browser
                })
            },
            "A completed live refresh must recapture browser DOM changes before rerunning the active query"
        )
#else
        Issue.record("Dynamic browser indexing coverage requires a DEBUG app-host build")
#endif
    }

    @MainActor
    @Test func liveRefreshAwaitsBrowserCaptureSupersededByLifecycleEvent() async throws {
#if DEBUG
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-browser-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let appDelegate = try #require(AppDelegate.shared)
        let token = "browsersuperseded\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let html = "<html><head><title>Lifecycle page</title></head><body>\(token)</body></html>"
        let encodedHTML = try #require(html.data(using: .utf8)).base64EncodedString()
        let initialURL = try #require(URL(string: "data:text/html;base64,\(encodedHTML)"))
        let harness = try makeNamedMainWindow(
            appDelegate: appDelegate,
            initialWorkspaceTitle: "Browser lifecycle workspace"
        )
        defer { closeWindow(harness.window, appDelegate: appDelegate) }
        let tabManager = try #require(appDelegate.tabManagerFor(windowId: harness.windowID))
        let workspace = try #require(tabManager.selectedWorkspace)
        let browserPanelID = try #require(
            tabManager.openBrowser(
                inWorkspace: workspace.id,
                url: initialURL,
                preferSplitRight: true
            )
        )
        let browserPanel = try #require(workspace.browserPanel(for: browserPanelID))
        #expect(
            await waitForBrowserBody(token, panel: browserPanel),
            "The browser fixture must finish loading before capture starts"
        )

        let index = try SearchIndex(databaseURL: directoryURL.appendingPathComponent("search.sqlite3"))
        let firstIndexRequestStarted = GlobalSearchAsyncSignal()
        let releaseFirstIndexRequest = GlobalSearchAsyncSignal()
        let indexRequestCount = GlobalSearchCounter()
        let captureManager = GlobalSearchPanelCaptureManager(
            indexProvider: {
                indexRequestCount.increment()
                if indexRequestCount.value == 1 {
                    firstIndexRequestStarted.signal()
                    await releaseFirstIndexRequest.wait()
                }
                return index
            },
            cancelPanelPurge: { _ in }
        )
        defer {
            releaseFirstIndexRequest.signal()
            captureManager.cancelCaptures(forPanelID: browserPanel.id)
        }
        let context = try #require(
            appDelegate.globalSearchContext(
                forPanelID: browserPanel.id,
                preferredWorkspaceID: workspace.id
            )
        )

        let refreshTask = Task { @MainActor in
            await captureManager.refreshPanelContent(for: context)
        }
        await firstIndexRequestStarted.wait()
        captureManager.captureBrowserPanel(browserPanel)
        releaseFirstIndexRequest.signal()
        await refreshTask.value

        #expect(
            try await index.search(token).contains(where: {
                $0.panelID == browserPanel.id && $0.kind == .browser
            }),
            "A live refresh must await the replacement when a browser lifecycle event supersedes its capture"
        )
#else
        Issue.record("Browser lifecycle capture coverage requires a DEBUG app-host build")
#endif
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func liveRefreshAwaitsLatestMarkdownCaptureWithinDeadline() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-markdown-churn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("notes.md")
        try "# Notes\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let workspaceID = UUID()
        let panel = MarkdownPanel(workspaceId: workspaceID, filePath: fileURL.path)
        let index = try SearchIndex(databaseURL: directoryURL.appendingPathComponent("search.sqlite3"))
        let firstIndexRequestStarted = GlobalSearchAsyncSignal()
        let secondIndexRequestStarted = GlobalSearchAsyncSignal()
        let thirdIndexRequestStarted = GlobalSearchAsyncSignal()
        let releaseFirstIndexRequest = GlobalSearchAsyncSignal()
        let releaseSecondIndexRequest = GlobalSearchAsyncSignal()
        let releaseThirdIndexRequest = GlobalSearchAsyncSignal()
        let indexRequestCount = GlobalSearchCounter()
        let captureManager = GlobalSearchPanelCaptureManager(
            indexProvider: {
                indexRequestCount.increment()
                switch indexRequestCount.value {
                case 1:
                    firstIndexRequestStarted.signal()
                    await releaseFirstIndexRequest.wait()
                case 2:
                    secondIndexRequestStarted.signal()
                    await releaseSecondIndexRequest.wait()
                case 3:
                    thirdIndexRequestStarted.signal()
                    await releaseThirdIndexRequest.wait()
                default:
                    break
                }
                return index
            },
            cancelPanelPurge: { _ in }
        )
        defer {
            releaseFirstIndexRequest.signal()
            releaseSecondIndexRequest.signal()
            releaseThirdIndexRequest.signal()
            captureManager.cancelCaptures(forPanelID: panel.id)
            panel.close()
        }
        let context = GlobalSearchPanelContext(
            windowID: UUID(),
            windowTitle: "Window",
            workspaceID: workspaceID,
            workspaceTitle: "Workspace",
            panelID: panel.id,
            panelTitle: panel.displayTitle,
            panel: panel
        )
        let refreshFinishedCount = GlobalSearchCounter()
        let refreshTask = Task { @MainActor in
            await captureManager.refreshPanelContent(for: context)
            refreshFinishedCount.increment()
        }

        await firstIndexRequestStarted.wait()
        captureManager.captureMarkdownPanel(panel)
        releaseFirstIndexRequest.signal()

        await secondIndexRequestStarted.wait()
        captureManager.captureMarkdownPanel(panel)
        releaseSecondIndexRequest.signal()

        await thirdIndexRequestStarted.wait()
        #expect(
            refreshFinishedCount.value == 0,
            "A presentation refresh must keep following the latest capture while its deadline remains"
        )

        releaseThirdIndexRequest.signal()
        #expect(
            await waitUntil(timeout: 1) {
                refreshFinishedCount.value == 1
            },
            "The refresh must finish after the latest capture commits"
        )
        await refreshTask.value
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func browserRefreshDeadlineReusesAnUnresponsiveCapture() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-browser-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let workspaceID = UUID()
        let panel = BrowserPanel(
            workspaceId: workspaceID,
            renderInitialNavigation: false
        )
        let index = try SearchIndex(databaseURL: directoryURL.appendingPathComponent("search.sqlite3"))
        let indexRequestStarted = GlobalSearchAsyncSignal()
        let releaseIndexRequest = GlobalSearchAsyncSignal()
        let indexRequestCount = GlobalSearchCounter()
        let captureManager = GlobalSearchPanelCaptureManager(
            indexProvider: {
                indexRequestCount.increment()
                indexRequestStarted.signal()
                await releaseIndexRequest.wait()
                return index
            },
            cancelPanelPurge: { _ in }
        )
        defer {
            releaseIndexRequest.signal()
            captureManager.cancelCaptures(forPanelID: panel.id)
            panel.close()
        }
        let context = GlobalSearchPanelContext(
            windowID: UUID(),
            windowTitle: "Window",
            workspaceID: workspaceID,
            workspaceTitle: "Workspace",
            panelID: panel.id,
            panelTitle: panel.displayTitle,
            panel: panel
        )

        let firstRefreshFinished = GlobalSearchCounter()
        let firstRefreshTask = Task { @MainActor in
            await captureManager.refreshPanelContent(for: context)
            firstRefreshFinished.increment()
        }
        await indexRequestStarted.wait()
        #expect(
            await waitUntil(timeout: 2) {
                firstRefreshFinished.value == 1
            },
            "One unresponsive browser capture must not hold the presentation refresh forever"
        )

        let secondRefreshFinished = GlobalSearchCounter()
        let secondRefreshTask = Task { @MainActor in
            await captureManager.refreshPanelContent(for: context)
            secondRefreshFinished.increment()
        }
        #expect(
            await waitUntil(timeout: 2) {
                secondRefreshFinished.value == 1
            },
            "A later presentation must share the same bounded in-flight browser capture"
        )
        #expect(
            indexRequestCount.value == 1,
            "Repeated presentations must not accumulate unresponsive WebKit capture work"
        )

        releaseIndexRequest.signal()
        await firstRefreshTask.value
        await secondRefreshTask.value
    }

    @MainActor
    @Test func discardedBrowserRefreshPreservesPreviouslyIndexedContent() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-discarded-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let workspaceID = UUID()
        let windowID = UUID()
        let panel = BrowserPanel(
            workspaceId: workspaceID,
            renderInitialNavigation: false
        )
        let index = try SearchIndex(databaseURL: directoryURL.appendingPathComponent("search.sqlite3"))
        let token = "discardedbrowser\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let document = SearchIndexDocument(
            id: SearchIndexDocument.panelStableID(panelID: panel.id, kind: .browser),
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panel.id,
            kind: .browser,
            title: "Indexed page",
            location: "https://example.com/indexed",
            anchor: "https://example.com/indexed",
            text: token
        )
        try await index.upsert(document)

        let captureManager = GlobalSearchPanelCaptureManager(
            indexProvider: { index },
            cancelPanelPurge: { _ in }
        )
        defer {
            captureManager.cancelCaptures(forPanelID: panel.id)
            panel.close()
        }
        let context = GlobalSearchPanelContext(
            windowID: windowID,
            windowTitle: "Window",
            workspaceID: workspaceID,
            workspaceTitle: "Workspace",
            panelID: panel.id,
            panelTitle: panel.displayTitle,
            panel: panel
        )

        #expect(
            try await index.search(token).contains(where: { $0.panelID == panel.id }),
            "The fixture must begin with the browser's prior DOM text in the stable document"
        )
        panel.hiddenWebViewDiscardManager.markDiscarded(
            reason: "test.global_search",
            now: Date()
        )

        await captureManager.refreshPanelContent(for: context)

        #expect(
            try await index.search(token).contains(where: { $0.panelID == panel.id }),
            "Refreshing an unloaded discarded browser shell must preserve its previously indexed DOM text"
        )
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func presentationDeadlineAdvancesPastUnresponsiveBrowserCaptures() async throws {
        let workspaceID = UUID()
        let firstPanel = BrowserPanel(
            workspaceId: workspaceID,
            renderInitialNavigation: false
        )
        let secondPanel = BrowserPanel(
            workspaceId: workspaceID,
            renderInitialNavigation: false
        )
        let indexRequestStarted = GlobalSearchAsyncSignal()
        let secondIndexRequestStarted = GlobalSearchAsyncSignal()
        let releaseFirstIndexRequest = GlobalSearchAsyncSignal()
        let indexRequestCount = GlobalSearchCounter()
        let firstRefreshFinished = GlobalSearchCounter()
        let captureManager = GlobalSearchPanelCaptureManager(
            indexProvider: {
                indexRequestCount.increment()
                if indexRequestCount.value == 1 {
                    indexRequestStarted.signal()
                    await releaseFirstIndexRequest.wait()
                } else if indexRequestCount.value == 2 {
                    secondIndexRequestStarted.signal()
                }
                return nil
            },
            cancelPanelPurge: { _ in }
        )
        defer {
            releaseFirstIndexRequest.signal()
            captureManager.cancelCaptures(forPanelID: firstPanel.id)
            captureManager.cancelCaptures(forPanelID: secondPanel.id)
            firstPanel.close()
            secondPanel.close()
        }
        let contexts = [firstPanel, secondPanel].map { panel in
            GlobalSearchPanelContext(
                windowID: UUID(),
                windowTitle: "Window",
                workspaceID: workspaceID,
                workspaceTitle: "Workspace",
                panelID: panel.id,
                panelTitle: panel.displayTitle,
                panel: panel
            )
        }

        let refreshTask = Task { @MainActor in
            await captureManager.refreshPanelContent(for: contexts)
            firstRefreshFinished.increment()
        }
        await indexRequestStarted.wait()
        #expect(
            await waitUntil(timeout: 2) {
                firstRefreshFinished.value == 1
            },
            "One presentation-wide deadline must bound the complete panel refresh"
        )
        #expect(
            indexRequestCount.value == 1,
            "An expired presentation budget must not start a capture for the next browser panel"
        )

        let secondRefreshFinished = GlobalSearchCounter()
        let secondRefreshTask = Task { @MainActor in
            await captureManager.refreshPanelContent(for: contexts)
            secondRefreshFinished.increment()
        }
        await secondIndexRequestStarted.wait()
        #expect(
            indexRequestCount.value == 2,
            "The next presentation must advance to the browser skipped by the prior deadline"
        )
        #expect(
            await waitUntil(timeout: 2) {
                secondRefreshFinished.value == 1
            },
            "The next presentation must remain bounded while revisiting the earlier in-flight capture"
        )

        releaseFirstIndexRequest.signal()
        await refreshTask.value
        await secondRefreshTask.value
    }

    private func makeSearchHit(id: String, title: String) -> SearchIndexHit {
        SearchIndexHit(
            id: id,
            windowID: UUID(),
            workspaceID: UUID(),
            panelID: UUID(),
            kind: .title,
            title: title,
            location: "Window > Workspace",
            anchor: "title",
            snippet: title,
            rank: 0,
            timestamp: .now
        )
    }

    private func makeSearchDocument(
        id: String,
        panelID: UUID,
        token: String
    ) -> SearchIndexDocument {
        SearchIndexDocument(
            id: id,
            windowID: UUID(),
            workspaceID: UUID(),
            panelID: panelID,
            kind: .title,
            title: token,
            location: "Window > Workspace",
            anchor: "title",
            text: token
        )
    }

    @MainActor
    private func expectCancelledMutation(
        _ mutation: @escaping @MainActor @Sendable () async throws -> Void
    ) async {
        let releaseMutation = GlobalSearchAsyncSignal()
        let task = Task { @MainActor in
            await releaseMutation.wait()
            try await mutation()
        }
        task.cancel()
        releaseMutation.signal()

        switch await task.result {
        case .success:
            Issue.record("The canceled index mutation unexpectedly committed")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        repeat {
            if predicate() {
                return true
            }
            await Task.yield()
        } while clock.now < deadline
        return predicate()
    }

    @MainActor
    private func makeMainWindow(appDelegate: AppDelegate) throws -> NSWindow {
        let windowId = appDelegate.createMainWindow()
        let identifier = "cmux.main.\(windowId.uuidString)"
        let window = try #require(
            NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
        )
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        return window
    }

    @MainActor
    private func makeNamedMainWindow(
        appDelegate: AppDelegate,
        initialWorkspaceTitle: String
    ) throws -> (windowID: UUID, window: NSWindow) {
        let windowID = appDelegate.createMainWindow(
            initialWorkspaceTitle: initialWorkspaceTitle
        )
        let identifier = "cmux.main.\(windowID.uuidString)"
        let window = try #require(
            NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
        )
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        return (windowID, window)
    }

    @MainActor
    private func waitForSearchPopoverWindow(
        excluding mainWindow: NSWindow,
        timeout: TimeInterval = 2
    ) -> NSWindow? {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if let window = NSApp.windows.first(where: {
                $0 !== mainWindow
                    && $0.isVisible
                    && $0.firstResponder is NSTextView
            }) {
                return window
            }
            _ = RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date.now.addingTimeInterval(0.01))
            )
        } while Date.now < deadline
        return nil
    }

    @MainActor
    private func waitForSearchFieldText(
        _ expectedText: String,
        in popoverWindow: NSWindow,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if (popoverWindow.firstResponder as? NSTextView)?.string == expectedText {
                return true
            }
            _ = RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date.now.addingTimeInterval(0.01))
            )
        } while Date.now < deadline
        return (popoverWindow.firstResponder as? NSTextView)?.string == expectedText
    }

    @MainActor
    private func waitForSearchHit(
        query: String,
        workspaceID: UUID,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            let hits = await GlobalSearchCoordinator.shared.search(query: query)
            if hits.contains(where: { $0.workspaceID == workspaceID }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        } while Date.now < deadline
        let hits = await GlobalSearchCoordinator.shared.search(query: query)
        return hits.contains(where: { $0.workspaceID == workspaceID })
    }

    @MainActor
    private func waitForBrowserBody(
        _ token: String,
        panel: BrowserPanel,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        repeat {
            if let body = try? await panel.evaluateJavaScript(
                "document.body?.textContent ?? ''"
            ) as? String,
               body.contains(token) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline

        let body = try? await panel.evaluateJavaScript(
            "document.body?.textContent ?? ''"
        ) as? String
        return body?.contains(token) == true
    }

    @MainActor
    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) throws -> NSEvent {
        try #require(
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
        )
    }

    @MainActor
    private func waitUntilGlobalSearchCloses(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if !GlobalSearchCoordinator.shared.isPaletteVisible() {
                return true
            }
            _ = RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date.now.addingTimeInterval(0.01))
            )
        } while Date.now < deadline
        return !GlobalSearchCoordinator.shared.isPaletteVisible()
    }

    @MainActor
    private func closeWindow(_ window: NSWindow, appDelegate: AppDelegate) {
        GlobalSearchCoordinator.shared.dismissPalette()
        _ = waitUntilGlobalSearchCloses()
#if DEBUG
        appDelegate.debugResetShortcutRoutingStateForTesting()
        let originalConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
#endif
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
private final class GlobalSearchAsyncSignal {
    private var didSignal = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        didSignal = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        guard !didSignal else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@MainActor
private final class GlobalSearchCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@MainActor
private final class GlobalSearchHitStore {
    var hits: [SearchIndexHit]

    init(hits: [SearchIndexHit]) {
        self.hits = hits
    }
}

@MainActor
private final class ControlledGlobalSearchDebounceScheduler {
    private var scheduledAction: (@MainActor () -> Void)?

    func schedule(
        _ action: @escaping @MainActor () -> Void
    ) -> GlobalSearchPopoverPresentation.DebounceCancellation {
        scheduledAction = action
        return { [weak self] in
            self?.scheduledAction = nil
        }
    }

    func fire() {
        let action = scheduledAction
        scheduledAction = nil
        action?()
    }
}
