import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cross-window Dock routing over the socket API: Dock-scoped commands anchor
/// to the Dock's owning window, explicitly contradictory selectors fail
/// closed, the legacy Global Dock alias keeps routing to the caller's window,
/// and the focused-close shortcut acts on its own window's Dock only.
/// See https://github.com/manaflow-ai/cmux/issues/7142.
@Suite("Window Dock socket routing", .serialized)
struct WindowDockRoutingSocketTests {
    private static let socketWorkerQueue = DispatchQueue(
        label: "com.cmux.tests.floating-note-socket-worker"
    )

    @MainActor
    private func v2Envelope(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    @MainActor
    private func v2Result(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let envelope = try v2Envelope(method: method, params: params)
        if envelope["ok"] as? Bool != true {
            Issue.record("Expected \(method) to succeed: \(envelope)")
        }
        return try #require(envelope["result"] as? [String: Any])
    }

    @MainActor
    private func v2EnvelopeOnSocketWorker(
        method: String,
        params: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let controller = TerminalController.shared
        let raw = await withCheckedContinuation { continuation in
            Self.socketWorkerQueue.async {
                continuation.resume(returning: controller.handleSocketLine(requestLine))
            }
        }
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    @MainActor
    private func withDockEnabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let key = RightSidebarBetaFeatureSettings.dockEnabledKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try body()
    }

    @MainActor
    private func withDockEnabled(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let key = RightSidebarBetaFeatureSettings.dockEnabledKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try await body()
    }

    @MainActor
    private func withSocketAppContext(
        fileExplorerState: FileExplorerState? = nil,
        _ body: (TabManager, Workspace, UUID) throws -> Void
    ) throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        if let fileExplorerState {
            appDelegate.fileExplorerState = fileExplorerState
        }
        TerminalController.shared.setActiveTabManager(manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager,
            fileExplorerState: fileExplorerState
        )
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            // Unregistering the window context also tears down that window's Dock.
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.tabs.first)
        try body(manager, workspace, windowId)
    }

    @MainActor
    private func withSocketAppContext(
        fileExplorerState: FileExplorerState? = nil,
        _ body: @MainActor (TabManager, Workspace, UUID) async throws -> Void
    ) async rethrows {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            if let fileExplorerState {
                appDelegate.fileExplorerState = fileExplorerState
            }
            TerminalController.shared.setActiveTabManager(manager)
            let windowId = appDelegate.registerMainWindowContextForTesting(
                tabManager: manager,
                fileExplorerState: fileExplorerState
            )
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            try await body(manager, workspace, windowId)
        }
    }

    @Test("Legacy global Dock alias workspace_id routes to the caller window's Dock")
    @MainActor
    func legacyDockAliasRoutesToCallerWindowDock() throws {
        try withDockEnabled {
            try withSocketAppContext { _, _, windowId in
                let createResult = try v2Result(
                    method: "surface.create",
                    params: ["placement": "dock", "type": "terminal", "focus": true]
                )
                let dockSurfaceIdRaw = try #require(createResult["dock_surface_id"] as? String)
                let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))

                // The retired app-wide Global Dock's owner id keeps routing for
                // CLI compatibility: it resolves to the Dock of the window the
                // command targets, and results report that Dock's real owner id.
                let listResult = try v2Result(
                    method: "surface.list",
                    params: ["workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString]
                )
                let surfaces = try #require(listResult["surfaces"] as? [[String: Any]])
                #expect(listResult["workspace_id"] as? String == windowId.uuidString)
                #expect(surfaces.contains { $0["id"] as? String == dockSurfaceId.uuidString })

                // A supplied-but-unresolvable selector fails closed instead of
                // degrading to the focused-Dock fallback.
                let unresolvedEnvelope = try v2Envelope(method: "browser.tab.list", params: [
                    "workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString,
                    "surface_id": "",
                ])
                #expect(unresolvedEnvelope["ok"] as? Bool == false)
                let unresolvedError = try #require(unresolvedEnvelope["error"] as? [String: Any])
                #expect(unresolvedError["code"] as? String == "invalid_params")

                let closeResult = try v2Result(
                    method: "surface.close",
                    params: ["workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString]
                )
                #expect(closeResult["workspace_id"] as? String == windowId.uuidString)
                #expect(closeResult["surface_id"] as? String == dockSurfaceId.uuidString)
                let windowDock = try #require(AppDelegate.shared?.existingWindowDock(forWindowId: windowId))
                #expect(!windowDock.containsPanel(dockSurfaceId))
            }
        }
    }

    @Test("Floating Dock note writes finish before success and report persistence failures")
    @MainActor
    func floatingDockNoteWritesAreAcknowledgedAfterPersistence() async throws {
        try await withSocketAppContext { _, workspace, _ in
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-floating-note-write-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let noteURL = root.appendingPathComponent("note.md")
            let dock = WorkspaceFloatingDock(
                id: UUID(),
                workspaceId: workspace.id,
                title: "Writable note",
                frame: CGRect(x: 0, y: 0, width: 520, height: 380),
                isPresented: false,
                noteFilePath: noteURL.path,
                initialContent: nil,
                baseDirectoryProvider: { nil },
                remoteBrowserSettingsProvider: { .local }
            )
            workspace.floatingDocks.append(dock)

            let first = try await v2EnvelopeOnSocketWorker(method: "workspace.float.note.set", params: [
                "workspace_id": workspace.id.uuidString,
                "float": dock.id.uuidString,
                "text": "first",
            ])
            #expect(first["ok"] as? Bool == true)
            #expect(try String(contentsOf: noteURL, encoding: .utf8) == "first")

            let second = try await v2EnvelopeOnSocketWorker(method: "workspace.float.note.set", params: [
                "workspace_id": workspace.id.uuidString,
                "float": dock.id.uuidString,
                "text": "second",
            ])
            #expect(second["ok"] as? Bool == true)
            #expect(try String(contentsOf: noteURL, encoding: .utf8) == "second")

            let blocker = root.appendingPathComponent("not-a-directory")
            try "block".write(to: blocker, atomically: true, encoding: .utf8)
            let blockedDock = WorkspaceFloatingDock(
                id: UUID(),
                workspaceId: workspace.id,
                title: "Blocked note",
                frame: CGRect(x: 0, y: 0, width: 520, height: 380),
                isPresented: false,
                noteFilePath: blocker.appendingPathComponent("note.md").path,
                initialContent: nil,
                baseDirectoryProvider: { nil },
                remoteBrowserSettingsProvider: { .local }
            )
            workspace.floatingDocks.append(blockedDock)
            let failed = try await v2EnvelopeOnSocketWorker(method: "workspace.float.note.set", params: [
                "workspace_id": workspace.id.uuidString,
                "float": blockedDock.id.uuidString,
                "text": "must not be acknowledged",
            ])
            #expect(failed["ok"] as? Bool == false)
            #expect(blockedDock.noteTextSnapshot.isEmpty)
        }
    }

    @Test("Floating Dock socket close bypasses interactive dirty-note confirmation")
    @MainActor
    func floatingDockSocketCloseBypassesInteractiveConfirmation() async throws {
        try await withSocketAppContext { _, workspace, _ in
            let dock = try #require(workspace.createFloatingDock(initialContent: .note))
            let note = try #require(dock.notePanel)
            await note.loadTextContent().value
            note.updateTextContent("dirty note")
            #expect(note.isDirty)

            let response = try v2Envelope(method: "workspace.float.close", params: [
                "workspace_id": workspace.id.uuidString,
                "float": dock.id.uuidString,
            ])

            #expect(response["ok"] as? Bool == true)
            #expect(workspace.floatingDock(id: dock.id) == nil)
        }
    }

    @Test("Floating Dock note writer rejects stale autosave completions")
    func floatingDockNoteWriterRejectsStaleAutosaveCompletions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-floating-note-sequence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let noteURL = root.appendingPathComponent("note.md")
        let writer = WorkspaceFloatingDockNoteWriter(fileURL: noteURL)
        let staleAutosaveSequence = writer.reserveSequence()
        let socketWriteSequence = writer.reserveSequence()

        guard case .saved = writer.saveSynchronously(
            content: "socket write",
            sequence: socketWriteSequence
        ) else {
            Issue.record("Expected socket note write to succeed")
            return
        }
        guard case .saved = writer.saveSynchronously(
            content: "stale autosave",
            sequence: staleAutosaveSequence
        ) else {
            Issue.record("Expected stale autosave to be discarded without failure")
            return
        }
        #expect(try String(contentsOf: noteURL, encoding: .utf8) == "socket write")

        let reservedSocketSequence = writer.reserveSequence()
        let newerLocalEditSequence = writer.reserveSequence()
        guard case .saved = writer.saveSynchronously(
            content: "reserved socket write",
            sequence: reservedSocketSequence
        ), case .saved = writer.saveSynchronously(
            content: "newer local edit",
            sequence: newerLocalEditSequence
        ) else {
            Issue.record("Expected ordered socket and local note writes to succeed")
            return
        }
        #expect(try String(contentsOf: noteURL, encoding: .utf8) == "newer local edit")
    }

    @Test("Socket note updates follow a note moved out of its floating Dock")
    @MainActor
    func socketNoteUpdatesFollowMovedNotePanel() async throws {
        try await withSocketAppContext { _, workspace, _ in
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-floating-note-move-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let dock = WorkspaceFloatingDock(
                id: UUID(),
                workspaceId: workspace.id,
                title: "Movable note",
                frame: CGRect(x: 0, y: 0, width: 520, height: 380),
                isPresented: false,
                noteFilePath: root.appendingPathComponent("note.md").path,
                initialContent: .note,
                baseDirectoryProvider: { nil },
                remoteBrowserSettingsProvider: { .local }
            )
            workspace.floatingDocks.append(dock)
            let notePanel = try #require(dock.notePanel)
            let transfer = try #require(dock.store.detachSurface(panelId: notePanel.id))
            let destinationPane = try #require(workspace.bonsplitController.allPaneIds.first)
            #expect(workspace.attachDetachedSurface(transfer, inPane: destinationPane, focus: false) == notePanel.id)
            #expect(dock.notePanel == nil)
            #expect(workspace.filePreviewPanel(for: notePanel.id) === notePanel)

            let response = try await v2EnvelopeOnSocketWorker(method: "workspace.float.note.set", params: [
                "workspace_id": workspace.id.uuidString,
                "float": dock.id.uuidString,
                "text": "updated after move",
            ])
            #expect(response["ok"] as? Bool == true)
            #expect(notePanel.textContent == "updated after move")
            #expect(try String(contentsOfFile: dock.noteFilePath, encoding: .utf8) == "updated after move")
        }
    }

    @Test("Floating terminal reports remain owned by their workspace")
    @MainActor
    func floatingTerminalReportsRemainOwnedByWorkspace() throws {
        try withSocketAppContext { manager, workspace, _ in
            let dock = WorkspaceFloatingDock(
                id: UUID(),
                workspaceId: workspace.id,
                title: "Reporting terminal",
                frame: CGRect(x: 0, y: 0, width: 520, height: 380),
                isPresented: false,
                noteFilePath: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-report-note-\(UUID().uuidString).md").path,
                initialContent: nil,
                baseDirectoryProvider: { nil },
                remoteBrowserSettingsProvider: { .local }
            )
            workspace.floatingDocks.append(dock)
            let sourcePanel = try #require(workspace.panels.values.compactMap { $0 as? TerminalPanel }.first)
            let transfer = try #require(workspace.detachSurface(panelId: sourcePanel.id))
            let dockPane = try #require(dock.store.bonsplitController.allPaneIds.first)
            #expect(dock.store.attachDetachedSurface(transfer, inPane: dockPane, focus: true) == sourcePanel.id)
            dock.ownsInputFocus = true
            #expect(workspace.panels[sourcePanel.id] == nil)

            let pwd = TerminalController.shared.controlSurfaceReportPWD(
                workspaceID: workspace.id,
                requestedSurfaceID: sourcePanel.id,
                path: "/tmp/floating-report"
            )
            guard case .recorded(let reportedSurfaceID) = pwd else {
                Issue.record("Expected floating terminal pwd report to resolve")
                return
            }
            #expect(reportedSurfaceID == sourcePanel.id)
            #expect(workspace.panelDirectories[sourcePanel.id] == "/tmp/floating-report")

            let tty = TerminalController.shared.controlSurfaceReportTTY(
                workspaceID: workspace.id,
                requestedSurfaceID: sourcePanel.id,
                ttyName: "ttys999"
            )
            guard case .recorded(let ttySurfaceID) = tty else {
                Issue.record("Expected floating terminal tty report to resolve")
                return
            }
            #expect(ttySurfaceID == sourcePanel.id)
            #expect(workspace.surfaceTTYNames[sourcePanel.id] == "ttys999")
            #expect(TerminalController.shared.controlSidebarSetPorts(
                tabArg: workspace.id.uuidString,
                panelArg: sourcePanel.id.uuidString,
                ports: [4317]
            ) == .done)
            #expect(workspace.surfaceListeningPorts[sourcePanel.id] == [4317])

            manager.updateSurfaceShellActivity(
                tabId: workspace.id,
                surfaceId: sourcePanel.id,
                state: .commandRunning
            )
            #expect(sourcePanel.shellActivity.state == .commandRunning)
            #expect(dock.store.detachedSurfaceTransfersByPanelId[sourcePanel.id]?.shellActivityState == .commandRunning)

            dock.store.closeAllPanels()
            #expect(!dock.store.containsPanel(sourcePanel.id))
            #expect(workspace.panelDirectories[sourcePanel.id] == nil)
            #expect(workspace.surfaceTTYNames[sourcePanel.id] == nil)
            #expect(workspace.surfaceListeningPorts[sourcePanel.id] == nil)
        }
    }

    @Test("Floating Dock mutations change the session autosave fingerprint")
    @MainActor
    func floatingDockMutationsChangeSessionAutosaveFingerprint() throws {
        try withSocketAppContext { manager, workspace, _ in
            let baseline = manager.sessionAutosaveFingerprint()
            let dock = WorkspaceFloatingDock(
                id: UUID(),
                workspaceId: workspace.id,
                title: "Fingerprint",
                frame: CGRect(x: 0, y: 0, width: 520, height: 380),
                isPresented: true,
                noteFilePath: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-fingerprint-note-\(UUID().uuidString).md").path,
                initialContent: nil,
                baseDirectoryProvider: { nil },
                remoteBrowserSettingsProvider: { .local }
            )
            workspace.floatingDocks.append(dock)
            let created = manager.sessionAutosaveFingerprint()
            #expect(created != baseline)

            dock.frame.origin.x += 40
            let moved = manager.sessionAutosaveFingerprint()
            #expect(moved != created)

            dock.isPresented = false
            #expect(manager.sessionAutosaveFingerprint() != moved)
        }
    }

    @Test("Failed initial browser creation does not append an empty floating Dock")
    @MainActor
    func failedInitialBrowserCreationDoesNotAppendFloatingDock() throws {
        try withSocketAppContext { _, workspace, _ in
            let defaults = UserDefaults.standard
            let previous = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
            BrowserAvailabilitySettings.setDisabled(true, defaults: defaults)
            defer {
                if let previous {
                    defaults.set(previous, forKey: BrowserAvailabilitySettings.disabledKey)
                } else {
                    defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
                }
            }

            let initialCount = workspace.floatingDocks.count
            #expect(workspace.createFloatingDock(initialContent: .browser) == nil)
            #expect(workspace.floatingDocks.count == initialCount)
        }
    }


    @Test("Floating Dock palette surface commands stay in the Dock container")
    @MainActor
    func floatingDockPaletteSurfaceCommandsStayInDock() throws {
        try withSocketAppContext { manager, workspace, _ in
            let dock = WorkspaceFloatingDock(
                id: UUID(),
                workspaceId: workspace.id,
                title: "Palette target",
                frame: CGRect(x: 0, y: 0, width: 520, height: 380),
                isPresented: false,
                noteFilePath: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-palette-note-\(UUID().uuidString).md").path,
                initialContent: nil,
                baseDirectoryProvider: { nil },
                remoteBrowserSettingsProvider: { .local }
            )
            workspace.floatingDocks.append(dock)
            let mainPanelCount = workspace.panels.count

            #expect(dock.store.performSurfaceCommand(.create(kind: .terminal, focusAddressBar: false)))
            #expect(dock.store.panels.count == 1)
            #expect(workspace.panels.count == mainPanelCount)

            #expect(dock.store.performSurfaceCommand(.split(kind: .terminal, direction: .right)))
            #expect(dock.store.panels.count == 2)
            #expect(workspace.panels.count == mainPanelCount)

            #expect(dock.store.performSurfaceCommand(.closeFocused))
            #expect(dock.store.panels.count == 1)
            #expect(manager.selectedWorkspace === workspace)
        }
    }

    @Test("Window Dock pane routing and focused close stay in their own window's Dock")
    @MainActor
    func dockPaneRoutingAndFocusedCloseStayInDock() async throws {
#if DEBUG
        try await withDockEnabled {
            // Async app-context gate: keep the swapped-in globals ours across
            // the body even when other serialized suites use async helpers.
            try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let activeManager = TabManager(autoWelcomeIfNeeded: false)
            let dockManager = TabManager(autoWelcomeIfNeeded: false)
            let fileExplorerState = FileExplorerState()
            let activeWindowId = UUID()
            let activeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            activeWindow.isReleasedWhenClosed = false
            activeWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(activeWindowId.uuidString)")
            let dockWindowId = UUID()
            let dockWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            dockWindow.isReleasedWhenClosed = false
            dockWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(dockWindowId.uuidString)")

            AppDelegate.shared = appDelegate
            appDelegate.tabManager = activeManager
            TerminalController.shared.setActiveTabManager(activeManager)
            appDelegate.registerMainWindow(activeWindow, windowId: activeWindowId, tabManager: activeManager, sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState())
            appDelegate.registerMainWindow(dockWindow, windowId: dockWindowId, tabManager: dockManager, sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState(), fileExplorerState: fileExplorerState)
            dockWindow.orderFront(nil)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                // Unregistering each window context also tears down its Dock.
                appDelegate.unregisterMainWindowContextForTesting(windowId: activeWindowId)
                appDelegate.unregisterMainWindowContextForTesting(windowId: dockWindowId)
                activeManager.tabs.forEach { $0.teardownAllPanels() }
                dockManager.tabs.forEach { $0.teardownAllPanels() }
                activeWindow.orderOut(nil)
                activeWindow.close()
                dockWindow.orderOut(nil)
                dockWindow.close()
                AppDelegate.shared = previousAppDelegate
            }

            func expectInvalidParams(_ envelope: [String: Any]) throws {
                #expect(envelope["ok"] as? Bool == false)
                let error = try #require(envelope["error"] as? [String: Any])
                #expect(error["code"] as? String == "invalid_params")
            }

            let activeWorkspace = try #require(activeManager.tabs.first)
            let dockWorkspace = try #require(dockManager.tabs.first)
            let floatingDock = try #require(activeWorkspace.createFloatingDock(initialContent: .note))
            let floatingNote = try #require(floatingDock.notePanel)
            await floatingNote.loadTextContent().value
            let floatingNoteTextBeforeConflict = floatingNote.textContent

            // Explicit window and workspace selectors are conjunctive. A
            // window-B scope cannot mutate a floating Dock in window A, even
            // on the worker-side note-write path.
            let crossWindowNoteWrite = try await v2EnvelopeOnSocketWorker(
                method: "workspace.float.note.set",
                params: [
                    "window_id": dockWindowId.uuidString,
                    "workspace_id": activeWorkspace.id.uuidString,
                    "float": floatingDock.id.uuidString,
                    "text": "must not cross windows",
                ]
            )
            #expect(crossWindowNoteWrite["ok"] as? Bool == false)
            #expect(floatingNote.textContent == floatingNoteTextBeforeConflict)

            let crossWindowFloatCloseAll = try v2Envelope(
                method: "workspace.float.close_all",
                params: [
                    "window_id": dockWindowId.uuidString,
                    "workspace_id": activeWorkspace.id.uuidString,
                ]
            )
            #expect(crossWindowFloatCloseAll["ok"] as? Bool == false)
            #expect(activeWorkspace.floatingDock(id: floatingDock.id) === floatingDock)

            let activeWindowDock = appDelegate.windowDock(forWindowId: activeWindowId)
            let dockPane = try #require(activeWindowDock.bonsplitController.allPaneIds.first)
            let result = try v2Result(method: "surface.create", params: [
                "placement": "dock",
                "type": "terminal",
                "pane_id": dockPane.id.uuidString,
                "window_id": activeWindowId.uuidString,
            ])
            let dockSurfaceIdRaw = try #require(result["dock_surface_id"] as? String)
            let dockSurfaceId = try #require(UUID(uuidString: dockSurfaceIdRaw))
            #expect(result["window_id"] as? String == activeWindowId.uuidString)
            #expect(result["workspace_id"] as? String == activeWindowId.uuidString)
            #expect(activeWindowDock.containsPanel(dockSurfaceId))
            #expect(appDelegate.existingWindowDock(forWindowId: dockWindowId) == nil)
            #expect(activeWorkspace._dockSplit?.containsPanel(dockSurfaceId) != true)
            #expect(dockWorkspace._dockSplit?.containsPanel(dockSurfaceId) != true)

            // A registered window id is a Dock owner selector even before that
            // window's Dock has been lazily created. Contradictory create
            // routing fails closed and does not materialize the other Dock.
            let activeDockPanelCountBeforeLazyConflict = activeWindowDock.panels.count
            let lazyOwnerSurfaceCreateConflict = try v2Envelope(method: "surface.create", params: [
                "placement": "dock",
                "type": "terminal",
                "window_id": activeWindowId.uuidString,
                "workspace_id": dockWindowId.uuidString,
            ])
            try expectInvalidParams(lazyOwnerSurfaceCreateConflict)
            #expect(activeWindowDock.panels.count == activeDockPanelCountBeforeLazyConflict)
            #expect(appDelegate.existingWindowDock(forWindowId: dockWindowId) == nil)

            let lazyOwnerPaneCreateConflict = try v2Envelope(method: "pane.create", params: [
                "placement": "dock",
                "type": "terminal",
                "direction": "right",
                "window_id": activeWindowId.uuidString,
                "workspace_id": dockWindowId.uuidString,
            ])
            try expectInvalidParams(lazyOwnerPaneCreateConflict)
            #expect(activeWindowDock.panels.count == activeDockPanelCountBeforeLazyConflict)
            #expect(appDelegate.existingWindowDock(forWindowId: dockWindowId) == nil)

            // Read-style commands must fail closed too: an explicit owner id
            // for an uninitialized Dock must not fall through to a surface in
            // another window's Dock or lazily materialize the named Dock.
            let lazyOwnerReadConflict = try v2Envelope(method: "surface.list", params: [
                "workspace_id": dockWindowId.uuidString,
                "surface_id": dockSurfaceId.uuidString,
            ])
            #expect(lazyOwnerReadConflict["ok"] as? Bool == false)
            #expect(appDelegate.existingWindowDock(forWindowId: dockWindowId) == nil)

            // Seed the second window's own Dock so the focused close below has a
            // panel to act on in ITS window.
            let otherWindowDock = appDelegate.windowDock(forWindowId: dockWindowId)
            #expect(otherWindowDock !== activeWindowDock)
            let otherPane = try #require(otherWindowDock.resolvePane(requestedPaneID: nil))
            let otherDockSurfaceId = try #require(otherWindowDock.newSurface(kind: .terminal, inPane: otherPane, focus: true))

            // A Dock-owner workspace selector resolves to its concrete window.
            // It cannot authorize a floating-Dock surface owned by another window.
            let ownerFloatingSurfaceConflict = try v2Envelope(method: "surface.list", params: [
                "workspace_id": dockWindowId.uuidString,
                "surface_id": floatingNote.id.uuidString,
            ])
            #expect(ownerFloatingSurfaceConflict["ok"] as? Bool == false)

            // The CLI injects the caller's main workspace_id even when the
            // user explicitly targets a Dock pane. A non-Dock workspace_id
            // must not override the globally-unique Dock pane selector.
            let explicitForeignDockPaneCreate = try v2Result(method: "surface.create", params: [
                "placement": "dock",
                "type": "terminal",
                "workspace_id": activeWorkspace.id.uuidString,
                "pane_id": otherPane.id.uuidString,
                "focus": false,
            ])
            let explicitForeignDockSurfaceIdRaw = try #require(explicitForeignDockPaneCreate["dock_surface_id"] as? String)
            let explicitForeignDockSurfaceId = try #require(UUID(uuidString: explicitForeignDockSurfaceIdRaw))
            #expect(explicitForeignDockPaneCreate["workspace_id"] as? String == dockWindowId.uuidString)
            #expect(explicitForeignDockPaneCreate["window_id"] as? String == dockWindowId.uuidString)
            #expect(otherWindowDock.containsPanel(explicitForeignDockSurfaceId))
            #expect(!activeWindowDock.containsPanel(explicitForeignDockSurfaceId))

            let explicitForeignDockPaneSplit = try v2Result(method: "pane.create", params: [
                "placement": "dock",
                "type": "terminal",
                "workspace_id": activeWorkspace.id.uuidString,
                "pane_id": otherPane.id.uuidString,
                "direction": "right",
                "focus": false,
            ])
            let explicitForeignDockSplitSurfaceIdRaw = try #require(explicitForeignDockPaneSplit["dock_surface_id"] as? String)
            let explicitForeignDockSplitSurfaceId = try #require(UUID(uuidString: explicitForeignDockSplitSurfaceIdRaw))
            #expect(explicitForeignDockPaneSplit["workspace_id"] as? String == dockWindowId.uuidString)
            #expect(explicitForeignDockPaneSplit["window_id"] as? String == dockWindowId.uuidString)
            #expect(otherWindowDock.containsPanel(explicitForeignDockSplitSurfaceId))
            #expect(!activeWindowDock.containsPanel(explicitForeignDockSplitSurfaceId))

            // An explicit window_id that contradicts the Dock named by
            // workspace_id fails closed instead of re-homing the report.
            let crossListEnvelope = try v2Envelope(method: "surface.list", params: [
                "workspace_id": activeWindowId.uuidString,
                "window_id": dockWindowId.uuidString,
            ])
            #expect(crossListEnvelope["ok"] as? Bool == false)

            // A Dock-owner workspace_id alone routes to (and reports) the
            // owning window, wherever the caller runs.
            let ownerList = try v2Result(method: "surface.list", params: [
                "workspace_id": activeWindowId.uuidString,
            ])
            #expect(ownerList["workspace_id"] as? String == activeWindowId.uuidString)
            #expect(ownerList["window_id"] as? String == activeWindowId.uuidString)

            // Explicitly naming two different windows' Docks fails closed.
            let conflictEnvelope = try v2Envelope(method: "browser.tab.list", params: [
                "workspace_id": activeWindowId.uuidString,
                "surface_id": otherDockSurfaceId.uuidString,
            ])
            try expectInvalidParams(conflictEnvelope)

            // Read-style Dock commands share the same fail-closed selector
            // semantics; they do not have later surface/pane containment guards.
            let readSurfaceConflict = try v2Envelope(method: "surface.list", params: [
                "workspace_id": activeWindowId.uuidString,
                "surface_id": otherDockSurfaceId.uuidString,
            ])
            #expect(readSurfaceConflict["ok"] as? Bool == false)
            let readPaneConflict = try v2Envelope(method: "pane.list", params: [
                "workspace_id": activeWindowId.uuidString,
                "pane_id": otherPane.id.uuidString,
            ])
            #expect(readPaneConflict["ok"] as? Bool == false)
            let aliasSurfaceConflict = try v2Envelope(method: "surface.list", params: [
                "workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString,
                "surface_id": otherDockSurfaceId.uuidString,
            ])
            #expect(aliasSurfaceConflict["ok"] as? Bool == false)
            let aliasPaneConflict = try v2Envelope(method: "pane.list", params: [
                "workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString,
                "pane_id": otherPane.id.uuidString,
            ])
            #expect(aliasPaneConflict["ok"] as? Bool == false)

            // A workspace_id naming a NON-Dock scope contradicts a Dock surface
            // selector the same way.
            let workspaceScopeConflict = try v2Envelope(method: "browser.tab.list", params: [
                "workspace_id": dockWorkspace.id.uuidString,
                "surface_id": otherDockSurfaceId.uuidString,
            ])
            #expect(workspaceScopeConflict["ok"] as? Bool == false)

            // Focusing a Dock surface by id targets its owning window even when
            // the caller's context resolved elsewhere; an explicit contradictory
            // window_id or Dock-owner workspace_id fails closed instead.
            let crossFocusEnvelope = try v2Envelope(method: "surface.focus", params: [
                "surface_id": dockSurfaceId.uuidString,
                "window_id": dockWindowId.uuidString,
            ])
            #expect(crossFocusEnvelope["ok"] as? Bool == false)
            let ownerConflictFocusEnvelope = try v2Envelope(method: "surface.focus", params: [
                "surface_id": dockSurfaceId.uuidString,
                "workspace_id": dockWindowId.uuidString,
            ])
            #expect(ownerConflictFocusEnvelope["ok"] as? Bool == false)
            let aliasConflictFocusEnvelope = try v2Envelope(method: "surface.focus", params: [
                "workspace_id": AppDelegate.windowDockAliasWorkspaceId.uuidString,
                "surface_id": otherDockSurfaceId.uuidString,
            ])
            #expect(aliasConflictFocusEnvelope["ok"] as? Bool == false)
            let focusResult = try v2Result(method: "surface.focus", params: [
                "surface_id": dockSurfaceId.uuidString,
            ])
            #expect(focusResult["window_id"] as? String == activeWindowId.uuidString)
            #expect(focusResult["workspace_id"] as? String == activeWindowId.uuidString)
            #expect(activeWindowDock.focusedPanelId == dockSurfaceId)

            // Dock creates mutate immediately, so contradictory owner selectors
            // must be rejected before adding panels to either Dock.
            let activeDockPanelCount = activeWindowDock.panels.count
            let otherDockPanelCount = otherWindowDock.panels.count
            let conflictingSurfaceCreate = try v2Envelope(method: "surface.create", params: [
                "placement": "dock",
                "type": "terminal",
                "window_id": activeWindowId.uuidString,
                "workspace_id": dockWindowId.uuidString,
            ])
            try expectInvalidParams(conflictingSurfaceCreate)
            #expect(activeWindowDock.panels.count == activeDockPanelCount)
            #expect(otherWindowDock.panels.count == otherDockPanelCount)

            let conflictingPaneCreate = try v2Envelope(method: "pane.create", params: [
                "placement": "dock",
                "type": "terminal",
                "direction": "right",
                "window_id": activeWindowId.uuidString,
                "workspace_id": dockWindowId.uuidString,
            ])
            try expectInvalidParams(conflictingPaneCreate)
            #expect(activeWindowDock.panels.count == activeDockPanelCount)
            #expect(otherWindowDock.panels.count == otherDockPanelCount)

            let closeAction = KeyboardShortcutSettings.Action.closeTab
            let hadCloseShortcut = UserDefaults.standard.object(forKey: closeAction.defaultsKey) != nil
            let originalCloseShortcut = KeyboardShortcutSettings.shortcut(for: closeAction)
            KeyboardShortcutSettings.setShortcut(closeAction.defaultShortcut, for: closeAction)
            defer {
                if hadCloseShortcut {
                    KeyboardShortcutSettings.setShortcut(originalCloseShortcut, for: closeAction)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: closeAction)
                }
            }

            let mainPanelCount = dockWorkspace.panels.count
            let focusedMainPanel = dockWorkspace.focusedPanelId
            fileExplorerState.setVisible(true)
            fileExplorerState.mode = .dock
            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: dockWindow)
            // Close shortcuts route to the focused window, and the earlier
            // surface.focus made the FIRST window key. A real Cmd+W in the
            // second window requires that window to be focused, so pin the
            // shortcut-routing focus there the way a user's click would.
            appDelegate.debugSetShortcutRoutingFocusedWindowForTesting(dockWindow)
            defer { appDelegate.debugResetShortcutRoutingStateForTesting() }
            let closeEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: dockWindow.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))

            #expect(appDelegate.debugHandleCustomShortcut(event: closeEvent))
            // The focused close acted on the second window's OWN Dock; the first
            // window's Dock panel is untouched.
            #expect(!otherWindowDock.containsPanel(otherDockSurfaceId))
            #expect(activeWindowDock.containsPanel(dockSurfaceId))
            #expect(dockWorkspace.panels.count == mainPanelCount)
            #expect(dockWorkspace.focusedPanelId == focusedMainPanel)
            }
        }
#else
        Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }
}
