import AppKit
import CmuxControlSocket
import CmuxTerminal
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension RemoteTmuxMirrorCLIObservabilityTests {
    @Test func mirrorRoutedCreationRejectsInitialInput() {
        let unsupported = TerminalController.shared.mirrorRoutedUnsupportedOptions(
            workingDirectory: nil,
            initialCommand: nil,
            initialInput: "echo ready\r",
            tmuxStartCommand: nil,
            startupEnvironment: [:]
        )

        #expect(unsupported == ["initial_input"])
    }

    @Test func unresolvedMirrorMutationsFailClosed() throws {
        do {
            let harness = try Harness(addPeerSurface: true, activeTmuxPaneID: nil)
            defer { harness.tearDown() }

            let result = TerminalController.shared.controlSurfaceRespawn(
                routing: harness.routing(),
                inputs: respawnInputs(surfaceID: nil)
            )

            #expect(result == .noFocusedSurface)
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }

        do {
            let harness = try Harness(addPeerSurface: true, activeTmuxPaneID: nil)
            defer { harness.tearDown() }

            let result = TerminalController.shared.controlSurfaceClose(
                routing: harness.routing(),
                surfaceID: nil,
                hasSurfaceIDParam: false
            )

            #expect(result == .noFocusedSurface)
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }
    }

    @Test func hiddenMirrorContainerHandlesFailClosedWhileDefaultsProject() throws {
        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let activeSurfaceID = try activeSurfaceID(in: harness)

            let implicitSend = TerminalController.shared.controlSurfaceSendText(
                routing: harness.routing(),
                surfaceID: nil,
                hasSurfaceIDParam: false,
                text: "route through active pane"
            )
            #expect(implicitSend == .surfaceUnavailable(activeSurfaceID))

            let explicitSend = TerminalController.shared.controlSurfaceSendText(
                routing: harness.routing(),
                surfaceID: harness.outerPanelID,
                hasSurfaceIDParam: true,
                text: "do not alias a cached wrapper"
            )
            #expect(explicitSend == .surfaceNotTerminal(harness.outerPanelID))
            #expect(TerminalController.shared.controlSurfaceFocus(
                routing: harness.routing(),
                surfaceID: harness.outerPanelID
            ) == .surfaceNotFound(harness.outerPanelID))
        }

        do {
            let harness = try Harness()
            defer { harness.tearDown() }

            let result = TerminalController.shared.controlSurfaceSplit(
                routing: harness.routing(),
                inputs: splitInputs(surfaceID: harness.outerPanelID)
            )

            #expect(result == .requestedSurfaceNotFound(harness.outerPanelID))
        }

        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let result = TerminalController.shared.controlSurfaceRespawn(
                routing: harness.routing(),
                inputs: respawnInputs(surfaceID: harness.outerPanelID)
            )

            #expect(result == .surfaceNotFoundForID(harness.outerPanelID))
        }

        do {
            let harness = try Harness(addPeerSurface: true)
            defer { harness.tearDown() }
            let result = TerminalController.shared.controlSurfaceClose(
                routing: harness.routing(),
                surfaceID: harness.outerPanelID,
                hasSurfaceIDParam: true
            )

            #expect(result == .surfaceNotFound(harness.outerPanelID))
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }

        do {
            let harness = try Harness(addPeerSurface: true)
            defer { harness.tearDown() }
            let notFound = ControlCallResult.err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(harness.outerPanelID.uuidString)])
            )

            #expect(TerminalController.shared.controlSurfaceMove(params: [
                "surface_id": .string(harness.outerPanelID.uuidString),
            ]) == notFound)
            #expect(TerminalController.shared.controlSurfaceReorder(
                surfaceID: harness.outerPanelID,
                inputs: ControlSurfaceReorderInputs(
                    index: 0,
                    beforeSurfaceID: nil,
                    afterSurfaceID: nil
                ),
                requestedFocus: false
            ) == .surfaceNotFound(harness.outerPanelID))
            #expect(TerminalController.shared.controlPaneJoin(
                targetPaneID: try #require(harness.workspace.bonsplitController.focusedPaneId?.id),
                surfaceID: harness.outerPanelID,
                sourcePaneID: nil,
                hasFocusParam: false,
                focus: false
            ) == .moved(notFound))
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }
    }

    /// `system.tree` advertises the inner pane surface, while tab order lives on
    /// the pane's outer tmux-window container. Reorder must accept that advertised
    /// identity and mutate the container without exposing the hidden wrapper
    /// handle (#7734).
    @Test func advertisedMirrorSurfaceReordersItsOwningWindowTab() throws {
        let harness = try Harness(addPeerSurface: true)
        defer {
            harness.workspace.remoteTmuxWindowOrderSync = nil
            harness.tearDown()
        }
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let advertisedSurfaceID = try #require(harness.mirror.panel(forPane: tmuxPaneID)?.id)
        let peerSurfaceID = try #require(harness.peerSurfaceID)
        let sourcePane = try #require(harness.workspace.paneId(forPanelId: harness.outerPanelID))
        var synchronizedPanelOrder: [UUID] = []
        harness.workspace.remoteTmuxWindowOrderSync = { panelOrder, verification in
            synchronizedPanelOrder = panelOrder
            verification?(true)
            return true
        }

        let result = TerminalController.shared.controlSurfaceReorder(
            surfaceID: advertisedSurfaceID,
            inputs: ControlSurfaceReorderInputs(
                index: 1,
                beforeSurfaceID: nil,
                afterSurfaceID: nil
            ),
            requestedFocus: false
        )

        #expect(result == .reordered(
            windowID: harness.windowID,
            workspaceID: harness.workspace.id,
            paneID: sourcePane.id,
            surfaceID: advertisedSurfaceID
        ))
        let reorderedPanelIDs = harness.workspace.bonsplitController.tabs(inPane: sourcePane)
            .compactMap { harness.workspace.panelIdFromSurfaceId($0.id) }
        #expect(reorderedPanelIDs == [peerSurfaceID, harness.outerPanelID])
        #expect(synchronizedPanelOrder == reorderedPanelIDs)
    }

    @Test func unsupportedBonsplitOnlyPaneMutationsRejectProjectedPaneIDs() throws {
        let harness = try Harness(focusAwayFromMirror: true)
        defer { harness.tearDown() }
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let paneID = try #require(harness.mirror.syntheticPaneID(forPane: tmuxPaneID)?.id)
        let surfaceID = try #require(harness.mirror.panel(forPane: tmuxPaneID)?.id)
        let focusedBefore = harness.workspace.bonsplitController.focusedPaneId?.id
        let treeBefore = harness.workspace.bonsplitController.treeSnapshot()

        let resize = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(1),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(paneID.uuidString),
                    "direction": .string("right"),
                    "amount": .int(10),
                ]
            )
        )
        guard case .err(let code, _, let data)? = resize else {
            Issue.record("Disconnected mirror pane resize did not fail: \(String(describing: resize))")
            return
        }
        #expect(code == "unavailable")
        #expect(data == .object(["pane_id": .string(paneID.uuidString)]))
        #expect(harness.workspace.bonsplitController.treeSnapshot() == treeBefore)

        let breakResult = TerminalController.shared.controlPaneBreak(
            routing: harness.routing(paneID: paneID),
            paneID: paneID,
            surfaceID: nil,
            requestedFocus: false
        )
        #expect(breakResult == .surfaceNotFound(surfaceID))

        let join = TerminalController.shared.controlPaneJoin(
            targetPaneID: paneID,
            surfaceID: nil,
            sourcePaneID: paneID,
            hasFocusParam: false,
            focus: false
        )
        #expect(join == .sourceSurfaceUnresolved(sourcePaneID: paneID))

        let last = TerminalController.shared.controlPaneLast(
            routing: harness.routing(paneID: paneID)
        )
        #expect(last == .noAlternatePane)
        #expect(harness.workspace.bonsplitController.focusedPaneId?.id == focusedBefore)
    }

    @Test func paneScopedMutationsTargetTheRequestedProjectedPane() throws {
        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let firstTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
            let firstPaneID = try #require(harness.mirror.syntheticPaneID(forPane: firstTmuxPaneID)?.id)
            let firstSurfaceID = try #require(harness.mirror.panel(forPane: firstTmuxPaneID)?.id)

            let result = TerminalController.shared.controlSurfaceRespawn(
                routing: harness.routing(paneID: firstPaneID),
                inputs: respawnInputs(surfaceID: nil)
            )

            #expect(result == .respawnFailed(firstSurfaceID))
        }

        do {
            let harness = try Harness(addPeerSurface: true)
            defer { harness.tearDown() }
            let firstTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
            let firstPaneID = try #require(harness.mirror.syntheticPaneID(forPane: firstTmuxPaneID)?.id)
            let firstSurfaceID = try #require(harness.mirror.panel(forPane: firstTmuxPaneID)?.id)

            let result = TerminalController.shared.controlSurfaceClose(
                routing: harness.routing(paneID: firstPaneID),
                surfaceID: nil,
                hasSurfaceIDParam: false
            )

            #expect(result == .closeFailed(firstSurfaceID))
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }
    }

    @Test func advertisedProjectedTerminalsSupportTerminalCommands() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let firstTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let firstSurfaceID = try #require(harness.mirror.panel(forPane: firstTmuxPaneID)?.id)

        let refresh = TerminalController.shared.controlSurfaceRefresh(routing: harness.routing())
        guard case .refreshed(_, let workspaceID, let refreshedCount) = refresh else {
            Issue.record("Expected projected terminals to refresh")
            return
        }
        #expect(workspaceID == harness.workspace.id)
        #expect(refreshedCount == harness.mirror.paneIDsInOrder.count)

        let clear = TerminalController.shared.controlSurfaceClearHistory(
            routing: harness.routing(),
            surfaceID: firstSurfaceID,
            hasSurfaceIDParam: true
        )
        switch clear {
        case .cleared(_, let workspaceID, let surfaceID):
            #expect(workspaceID == harness.workspace.id)
            #expect(surfaceID == firstSurfaceID)
        case .bindingActionUnavailable:
            break
        default:
            Issue.record("Projected terminal was not resolved for clear_history")
        }

        let flash = TerminalController.shared.controlSurfaceTriggerFlash(
            routing: harness.routing(),
            surfaceID: firstSurfaceID
        )
        #expect(flash == .flashed(
            windowID: harness.windowID,
            workspaceID: harness.workspace.id,
            surfaceID: firstSurfaceID
        ))
    }

    @Test func treeAndIdentifyUseProjectedMirrorIdentities() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let expectedPaneIDs = harness.mirror.paneIDsInOrder.compactMap {
            harness.mirror.syntheticPaneID(forPane: $0)?.id
        }
        let expectedSurfaceIDs = harness.mirror.paneIDsInOrder.compactMap {
            harness.mirror.panel(forPane: $0)?.id
        }

        let tree = TerminalController.shared.controlSystemTreeWindows(
            requestedWindowID: harness.windowID,
            includeAllWindows: false,
            focusedWindowID: harness.windowID,
            workspaceFilter: harness.workspace.id
        )
        let workspaceNode = try #require(tree.windows.first?.workspaces.first)
        #expect(workspaceNode.panes.map(\.paneID) == expectedPaneIDs)
        #expect(workspaceNode.panes.flatMap(\.surfaceIDs) == expectedSurfaceIDs)

        let identify = TerminalController.shared.controlSystemIdentify(params: [:]).foundationObject
        let root = try #require(identify as? [String: Any])
        let focused = try #require(root["focused"] as? [String: Any])
        #expect(focused["pane_id"] as? String == expectedPaneIDs.last?.uuidString)
        #expect(focused["surface_id"] as? String == expectedSurfaceIDs.last?.uuidString)
    }

    @Test func createPathsHonorProjectedPaneIdentities() throws {
        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let firstTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
            let firstPaneID = try #require(harness.mirror.syntheticPaneID(forPane: firstTmuxPaneID)?.id)

            let result = TerminalController.shared.controlSurfaceCreate(
                routing: harness.routing(),
                inputs: ControlSurfaceCreateInputs(
                    typeRaw: nil,
                    providerRaw: nil,
                    rendererRaw: nil,
                    urlRaw: nil,
                    workingDirectory: nil,
                    initialCommand: nil,
                    tmuxStartCommand: nil,
                    remotePTYSessionID: nil,
                    remoteContextRaw: nil,
                    startupEnvironment: [:],
                    requestedPaneID: firstPaneID,
                    requestedFocus: false
                )
            )

            // A projected pane is a valid target. `new-surface` maps to a tmux
            // window in a mirror, so the disconnected transport fails only
            // after the handle has resolved and routing has been attempted.
            #expect(result == .createFailed)
        }

        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let firstTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
            let firstSurfaceID = try #require(harness.mirror.panel(forPane: firstTmuxPaneID)?.id)

            let result = TerminalController.shared.controlPaneCreate(
                routing: harness.routing(),
                inputs: ControlPaneCreateInputs(
                    directionRaw: "right",
                    typeRaw: nil,
                    urlRaw: nil,
                    workingDirectory: nil,
                    initialCommand: nil,
                    tmuxStartCommand: nil,
                    startupEnvironment: [:],
                    requestedSourceSurfaceID: firstSurfaceID,
                    requestedFocus: false,
                    hasInitialDividerPosition: false,
                    initialDividerPositionRaw: nil
                )
            )

            // The projected source surface resolves to its tmux pane and the
            // split routes to tmux; the never-connected transport then fails
            // closed instead of splitting the local Bonsplit wrapper.
            #expect(result == .createFailed)
        }
    }

    private func activeSurfaceID(in harness: Harness) throws -> UUID {
        let paneID = try #require(harness.mirror.activePaneId)
        return try #require(harness.mirror.panel(forPane: paneID)?.id)
    }

    private func respawnInputs(surfaceID: UUID?) -> ControlSurfaceRespawnInputs {
        ControlSurfaceRespawnInputs(
            command: "exec ${SHELL:-/bin/zsh} -l",
            tmuxStartCommand: "exec ${SHELL:-/bin/zsh} -l",
            workingDirectory: nil,
            hasSurfaceIDParam: surfaceID != nil,
            requestedSurfaceID: surfaceID,
            hasFocusParam: false,
            requestedFocus: false
        )
    }

    private func splitInputs(surfaceID: UUID) -> ControlSurfaceSplitInputs {
        ControlSurfaceSplitInputs(
            directionRaw: "right",
            typeRaw: nil,
            urlRaw: nil,
            requestedSourceSurfaceID: surfaceID,
            workingDirectory: nil,
            initialCommand: nil,
            tmuxStartCommand: nil,
            remotePTYSessionID: nil,
            remoteContextRaw: nil,
            startupEnvironment: [:],
            clientUnsupportedRemoteTmuxOptions: [],
            requestedFocus: false,
            initialDividerPosition: nil
        )
    }
}

@MainActor
@Suite(.serialized, .exclusiveAppContext, .timeLimit(.minutes(1)))
struct OwnedProcessTests {
    @Test func ownedClosePreservesInputAndBrowser() async throws {
        let harness = try GhosttyWorkspaceActionTestHarness(initialTerminalCommand: "/bin/sleep 60")
        defer { harness.close() }
        let workspace = try #require(harness.manager.selectedWorkspace)
        let surface = try await harness.startTerminal()
        let terminalID = surface.id
        let terminal = try #require(workspace.terminalPanel(for: terminalID))
        let pid = try await workerPID(on: surface)
        var params = try ownedIdentity(workspaceID: workspace.id, surfaceID: terminalID, pid: pid)
        let identity = params
        let audit = try #require(identity["audit_token"])
        let pane = try #require(workspace.paneId(forPanelId: terminalID))
        let browser = try #require(workspace.newBrowserSurface(inPane: pane, focus: false))
        params["audit_token"] = .string("incorrect")
        guard case .err = TerminalController.shared.controlOwnedProcess(params: params, close: true) else {
            Issue.record("wrong audit token was accepted"); return
        }
        #expect(kill(Int32(pid), 0) == 0)
        params["audit_token"] = audit
        params["runtime_generation"] = .string("stale")
        guard case .err = TerminalController.shared.controlOwnedProcess(params: params, close: true) else {
            Issue.record("replaced runtime was accepted"); return
        }
        params["runtime_generation"] = identity["runtime_generation"]
        terminal.textBoxContent = "Keep this draft"
        guard case .err = TerminalController.shared.controlOwnedProcess(params: params, close: true) else {
            Issue.record("text box draft was discarded"); return
        }
        #expect(terminal.textBoxContent == "Keep this draft")
        terminal.textBoxContent = ""
        let inputView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        terminal.textBoxInputView = inputView
        inputView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(terminal.textBoxContent.isEmpty)
        guard case .err = TerminalController.shared.controlOwnedProcess(params: params, close: true) else {
            Issue.record("unpublished TextBox composition was discarded"); return
        }
        #expect(inputView.hasMarkedText())
        inputView.unmarkText()
        inputView.string = ""
        let uploadID = UUID()
        inputView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        guard case .err = TerminalController.shared.controlOwnedProcess(params: params, close: true) else {
            Issue.record("pending attachment upload was discarded"); return
        }
        #expect(inputView.hasPendingAttachmentUploadPlaceholder())
        inputView.removePendingAttachmentUploadPlaceholder(id: uploadID)
        terminal.textBoxInputView = nil
        terminal.surface.didReceiveExplicitInput()
        guard case .err = TerminalController.shared.controlOwnedProcess(params: params, close: true) else {
            Issue.record("new terminal input was discarded"); return
        }
        #expect(workspace.panels[terminalID] != nil)
        #expect(kill(Int32(pid), 0) == 0)
        guard case .ok(.object(let afterInput)) = TerminalController.shared.controlOwnedProcess(params: params, close: false) else {
            Issue.record("terminal input identity refresh failed"); return
        }
        params["input_generation"] = afterInput["input_generation"]
        terminal.surface.noteClipboardReadCompleted()
        guard case .err = TerminalController.shared.controlOwnedProcess(params: params, close: true) else {
            Issue.record("completed clipboard input was discarded"); return
        }
        guard case .ok(.object(let refreshed)) = TerminalController.shared.controlOwnedProcess(params: params, close: false) else {
            Issue.record("terminal identity refresh failed"); return
        }
        params["input_generation"] = refreshed["input_generation"]
        guard case .ok = TerminalController.shared.controlOwnedProcess(params: params, close: true) else {
            Issue.record("owned surface close failed"); return
        }
        let closed = await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            workspace.panels[terminalID] == nil && Darwin.kill(Int32(pid), 0) == -1 && errno == ESRCH
        }
        #expect(closed)
        #expect(workspace.panels[browser.id] === browser)
        #expect(harness.manager.tabs.contains { $0.id == workspace.id })
    }

    @Test(arguments: [false, true])
    func pendingImageSubmissionPreventsOwnedClose(queued: Bool) async throws {
        let harness = try GhosttyWorkspaceActionTestHarness(initialTerminalCommand: "/bin/sleep 60")
        defer { harness.close() }
        let workspace = try #require(harness.manager.selectedWorkspace)
        let surface = try await harness.startTerminal()
        let pid = try await workerPID(on: surface)
        let beforeSubmit = try ownedIdentity(workspaceID: workspace.id, surfaceID: surface.id, pid: pid)
        defer { TextBoxSubmit.debugResetForTesting() }
        // Hold the pasteboard run before it mutates the clipboard.
        let events: [TextBoxSubmit.DispatchEvent] = [
            .waitForVisibleText(UUID().uuidString),
            .pasteFilePath("/unused/test-image.png"),
        ]
        if queued {
            let other = harness.manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
            let otherID = try #require(other.focusedPanelId)
            let otherTerminal = try #require(other.terminalPanel(for: otherID))
            TextBoxSubmit.sendEvents(events, via: otherTerminal.surface)
            try #require(TextBoxSubmit.hasPendingSubmission(via: otherTerminal.surface))
        }
        var completed = false
        TextBoxSubmit.sendEvents(events, via: surface) { _ in completed = true }
        try #require(!completed)
        var pending = try ownedIdentity(workspaceID: workspace.id, surfaceID: surface.id, pid: pid)
        pending["workspace_close_title"] = .string(workspace.title)
        #expect(pending["input_generation"] != beforeSubmit["input_generation"])
        guard case .err(code: "invalid_state", message: _, data: _) =
            TerminalController.shared.controlOwnedProcess(params: pending, close: true) else {
            Issue.record("an identity captured during image submission was accepted"); return
        }
        #expect(workspace.terminalPanel(for: surface.id)?.surface === surface)
        #expect(Darwin.kill(Int32(pid), 0) == 0)
    }

    @Test func pendingMultiImageDropPreventsOwnedClose() async throws {
        let harness = try GhosttyWorkspaceActionTestHarness(initialTerminalCommand: "/bin/sleep 60")
        defer { harness.close() }
        let workspace = try #require(harness.manager.selectedWorkspace)
        let surface = try await harness.startTerminal()
        let terminal = try #require(workspace.terminalPanel(for: surface.id))
        let pid = try await workerPID(on: surface)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = [directory.appendingPathComponent("first.png"), directory.appendingPathComponent("second.png")]
        let pixel = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIW2Nk+M/wHwAF/gL+Xw8eAAAAAElFTkSuQmCC"))
        for url in urls { try pixel.write(to: url) }

        try #require(terminal.hostedView.surfaceView.executePreparedImageTransfer(.fileURLs(urls), onCancel: {}))
        try #require(surface.hasPendingImageTransferInput)
        var pending = try ownedIdentity(workspaceID: workspace.id, surfaceID: surface.id, pid: pid)
        pending["workspace_close_title"] = .string(workspace.title)
        guard case .err(code: "invalid_state", message: _, data: _) =
            TerminalController.shared.controlOwnedProcess(params: pending, close: true) else {
            Issue.record("an identity captured during a multi-image drop was accepted"); return
        }
        #expect(workspace.terminalPanel(for: surface.id)?.surface === surface)
        let completed = await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            !surface.hasPendingImageTransferInput
        }
        #expect(completed)
        #expect(Darwin.kill(Int32(pid), 0) == 0)
    }

    @Test func childExitPreservesWorkspaceDock() throws {
        let app = try #require(AppDelegate.shared)
        let windowID = app.createMainWindow()
        defer {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "cmux.main.\(windowID.uuidString)" }) {
                window.performClose(nil)
            }
        }
        let manager = try #require(app.tabManagerFor(windowId: windowID))
        let workspace = try #require(manager.selectedWorkspace)
        let terminalID = try #require(workspace.focusedPanelId)
        let dock = try #require(workspace.dockSplit)
        let pane = try #require(dock.bonsplitController.allPaneIds.first)
        let browserID = try #require(dock.newSurface(kind: .browser, inPane: pane, focus: false))
        _ = manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: terminalID)
        #expect(workspace.panels[terminalID] == nil)
        #expect(manager.tabs.contains { $0.id == workspace.id })
        #expect(dock.panels[browserID] != nil)
    }

    @Test func childExitPreservesLastWindowDock() throws {
        let harness = try GhosttyWorkspaceActionTestHarness()
        defer { harness.close() }
        let manager = harness.manager
        let workspace = try #require(manager.selectedWorkspace)
        try #require(manager.tabs.map(\.id) == [workspace.id])
        let terminalID = try #require(workspace.focusedPanelId)
        let dock = harness.app.windowDock(forWindowId: harness.windowID)
        let pane = try #require(dock.bonsplitController.allPaneIds.first)
        let browserID = try #require(dock.newSurface(kind: .browser, inPane: pane, focus: false))
        let browser = try #require(dock.panels[browserID])
        try #require(harness.app.existingWindowDock(for: manager) === dock)
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: terminalID)
        #expect(harness.app.tabManagerFor(windowId: harness.windowID) === manager)
        #expect(manager.tabs.map(\.id) == [workspace.id])
        #expect(workspace.panels[terminalID] == nil)
        let replacement = try #require(workspace.focusedPanelId)
        #expect(workspace.terminalPanel(for: replacement) != nil)
        #expect(dock.panels[browserID] === browser)
    }

    @Test func ownedCloseReplacesEmptyWorkspaceAndPreservesLastWindowDock() async throws {
        let harness = try GhosttyWorkspaceActionTestHarness(initialTerminalCommand: "/bin/sleep 60")
        defer { harness.close() }
        let manager = harness.manager
        let workspace = try #require(manager.selectedWorkspace)
        try #require(manager.tabs.map(\.id) == [workspace.id])
        let surface = try await harness.startTerminal()
        let pid = try await workerPID(on: surface)
        let identity = try ownedIdentity(workspaceID: workspace.id, surfaceID: surface.id, pid: pid)
        let dock = harness.app.windowDock(forWindowId: harness.windowID)
        let pane = try #require(dock.bonsplitController.allPaneIds.first)
        let browserID = try #require(dock.newSurface(kind: .browser, inPane: pane, focus: false))
        let browser = try #require(dock.panels[browserID])
        try #require(harness.app.existingWindowDock(for: manager) === dock)
        guard case .err(code: "invalid_state", message: _, data: _) =
            TerminalController.shared.controlOwnedProcess(params: identity, close: true) else {
            Issue.record("workspace removal without the observed title was accepted"); return
        }
        var close = identity
        close["workspace_close_title"] = .string(workspace.title)
        let managedTitle = workspace.title
        workspace.title = "Renamed by the user"
        guard case .err(code: "invalid_state", message: _, data: _) =
            TerminalController.shared.controlOwnedProcess(params: close, close: true) else {
            Issue.record("workspace removal after a user rename was accepted"); return
        }
        #expect(manager.selectedWorkspace?.id == workspace.id)
        #expect(workspace.terminalPanel(for: surface.id)?.surface === surface)
        #expect(Darwin.kill(Int32(pid), 0) == 0)
        workspace.title = managedTitle
        guard case .ok = TerminalController.shared.controlOwnedProcess(params: close, close: true) else {
            Issue.record("owned workspace close failed"); return
        }
        let closed = await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            !manager.tabs.contains { $0.id == workspace.id } && Darwin.kill(Int32(pid), 0) == -1 && errno == ESRCH
        }
        #expect(closed)
        #expect(workspace.panels[surface.id] == nil)
        #expect(harness.app.tabManagerFor(windowId: harness.windowID) === manager)
        #expect(harness.app.existingWindowDock(for: manager) === dock)
        #expect(dock.panels[browserID] === browser)
        #expect(manager.tabs.count == 1)
        #expect(manager.selectedWorkspace?.id != workspace.id)
    }

    @Test func wrongProcessCannotCloseSurface() throws {
        let app = try #require(AppDelegate.shared)
        let windowID = app.createMainWindow()
        defer {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "cmux.main.\(windowID.uuidString)" }) {
                window.performClose(nil)
            }
        }
        let manager = try #require(app.tabManagerFor(windowId: windowID))
        let workspace = try #require(manager.selectedWorkspace)
        let surface = try #require(workspace.focusedPanelId)
        let params: [String: JSONValue] = ["workspace_id": .string(workspace.id.uuidString),
            "surface_id": .string(surface.uuidString), "pid": .int(Int64(getpid())), "audit_token": .string("invalid")]
        guard case .err = TerminalController.shared.controlOwnedProcess(params: params, close: true) else {
            Issue.record("process outside the surface was accepted"); return
        }
        #expect(workspace.panels[surface] != nil)
    }

    @Test func ownedClosePreservesGeneratedGroupAnchorDraft() async throws {
        let harness = try GhosttyWorkspaceActionTestHarness(initialTerminalCommand: "/bin/sleep 60")
        defer { harness.close() }
        let manager = harness.manager
        let workspace = try #require(manager.selectedWorkspace)
        let surface = try await harness.startTerminal()
        let pid = try await workerPID(on: surface)
        let groupID = try #require(manager.createWorkspaceGroup(name: "Group", selectAnchor: false))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupID })
        let anchor = try #require(manager.tabs.first { $0.id == group.anchorWorkspaceId })
        let anchorPanelID = try #require(anchor.focusedPanelId)
        let anchorTerminal = try #require(anchor.terminalPanel(for: anchorPanelID))
        manager.addWorkspaceToGroup(workspaceId: workspace.id, groupId: groupID)
        try #require(workspace.groupId == groupID)
        try #require(manager.tabs.count == 2)
        anchorTerminal.textBoxContent = "Keep this draft in the group anchor"
        #expect(!anchorTerminal.hasReceivedExplicitInput)

        var identity = try ownedIdentity(workspaceID: workspace.id, surfaceID: surface.id, pid: pid)
        identity["workspace_close_title"] = .string(workspace.title)
        guard case .ok = TerminalController.shared.controlOwnedProcess(params: identity, close: true) else {
            Issue.record("owned workspace close failed"); return
        }
        let closed = await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            !manager.tabs.contains { $0.id == workspace.id } && Darwin.kill(Int32(pid), 0) == -1 && errno == ESRCH
        }
        #expect(closed)
        #expect(manager.tabs.map(\.id) == [anchor.id])
        #expect(manager.workspaceGroups.first { $0.id == groupID }?.anchorWorkspaceId == anchor.id)
        #expect(anchor.terminalPanel(for: anchorPanelID) === anchorTerminal)
        #expect(anchorTerminal.textBoxContent == "Keep this draft in the group anchor")
    }

    private func workerPID(on surface: TerminalSurface) async throws -> Int {
        let pump = AppKitTestEventPump()
        var pid: Int?
        var foregroundProcesses: [TerminalSSHSessionDetector.ProcessSnapshot] = []
        let workerReady = await pump.waitUntil(timeout: .seconds(10)) {
            guard surface.controllingTTYDeviceIdentifier != nil,
                  let tty = surface.controllingTTYName(),
                  let group = surface.foregroundProcessID(),
                  let foreground = Int32(exactly: group) else { return false }
            // Ghostty reports a process group ID. On macOS the login process
            // can lead that group while the worker runs as a separate PID.
            foregroundProcesses = TerminalSSHSessionDetector.processSnapshots(
                inProcessGroup: foreground, ttyName: tty
            )
            pid = foregroundProcesses.first { process in
                process.pgid == foreground && process.tpgid == foreground && process.executableName == "sleep"
            }.map { Int($0.pid) }
            return pid != nil
        }
        try #require(workerReady, "foreground sleep worker missing; observed \(foregroundProcesses)")
        return try #require(pid)
    }

    private func ownedIdentity(workspaceID: UUID, surfaceID: UUID, pid: Int) throws -> [String: JSONValue] {
        let params: [String: JSONValue] = [
            "workspace_id": .string(workspaceID.uuidString),
            "surface_id": .string(surfaceID.uuidString),
            "pid": .int(Int64(pid)),
        ]
        let result = TerminalController.shared.controlOwnedProcess(params: params, close: false)
        guard case .ok(.object(let identity)) = result else {
            throw OwnedIdentityUnavailable(result: result)
        }
        return identity
    }

    private struct OwnedIdentityUnavailable: Error {
        let result: ControlCallResult
    }
}
