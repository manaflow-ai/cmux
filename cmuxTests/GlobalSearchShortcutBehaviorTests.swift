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
        _ = try #require(
            GlobalSearchCoordinator.shared.browseOpenPanels().first,
            "The real main-window fixture must provide a selected browse result"
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
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if predicate() {
                return true
            }
            await Task.yield()
        } while Date.now < deadline
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
