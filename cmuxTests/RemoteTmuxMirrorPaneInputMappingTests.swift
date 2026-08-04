import AppKit
import Carbon.HIToolbox
import CmuxControlSocket
import CmuxRemoteSession
import Foundation
import Testing
import CmuxTerminal
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for per-pane input routing in a mirrored multi-pane tmux
/// window: the pane that a click SELECTS must be the same pane that typed input
/// REACHES. See ``RemoteTmuxWindowMirror`` + ``RemoteTmuxSessionMirror``.
///
/// These assertions run against the REAL closures the mirror installs. A mirror
/// pane's typed input is delivered by `TerminalSurface.manualInputHandler`, which
/// the mirror wires per pane in `makeRemoteTmuxPanePanel(onInput:)` — the handler
/// for pane %N calls `connection.sendKeys(paneId: N, ...)`. The click/select path
/// resolves a clicked bonsplit pane to a tmux id through
/// `paneIdByBonsplitPane`, while the rendered surface (whose handler fires on a
/// keystroke) is chosen by `tmuxPaneId(forTab:)`. If those two maps disagree for
/// the same visual pane, you select one pane and type into another.
///
/// Most tests assert the structural invariant on the mirror's maps:
/// select-target == render/input-target, per pane. The named-key cases additionally
/// mount the real manual-I/O surface and inspect the exact tmux control commands
/// produced by physical key events, including live/restored terminal-mode changes.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorPaneInputMappingTests {

    // MARK: - Harness (mirrors MirrorTitleHarness in RemoteTmuxMirrorTargetingTests)

    @MainActor
    final class Harness {
        let windowId: UUID
        let controller: RemoteTmuxController
        let host: RemoteTmuxHost
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
        let workspace: Workspace

        init() throws {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let controller = RemoteTmuxController()
            let host = RemoteTmuxHost(destination: "user@paneinput")
            let connection = RemoteTmuxControlConnection(host: host, sessionName: "input-map")
            let pipe = Pipe()
            let writer = RemoteTmuxControlPipeWriter(
                handle: pipe.fileHandleForWriting,
                label: "remote-tmux-pane-input-map-test",
                maxPendingBytes: 1 << 16,
                onFailure: {}
            )
            connection.installStdinWriterForTesting(writer)
            connection.handleMessageForTesting(.enter)
            connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
            controller.cacheConnection(connection)
            try controller.mirrorSession(host: host, sessionName: "input-map", into: manager)
            self.workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
            self.windowId = windowId
            self.controller = controller
            self.host = host
            self.connection = connection
            self.writer = writer
            self.pipe = pipe
        }

        func publishListWindows(_ lines: [String]) {
            connection.handleMessageForTesting(.commandResult(commandNumber: 1, lines: lines, isError: false))
        }

        func drainThroughPaneRects(_ linesByWindow: [Int: [String]]) throws {
            while let kind = connection.pendingCommandKindsForTesting.first {
                let lines: [String]
                if case let .paneRects(windowId, _) = kind {
                    lines = try #require(linesByWindow[windowId])
                } else {
                    lines = []
                }
                connection.handleMessageForTesting(.commandResult(commandNumber: 2, lines: lines, isError: false))
            }
        }

        func mirror() throws -> RemoteTmuxWindowMirror {
            let panelId = try #require(
                workspace.remoteTmuxSessionMirror?.panelIdByWindow.values.first,
                "Expected a mirrored window tab"
            )
            return try #require(
                workspace.remoteTmuxWindowMirror(forPanelId: panelId),
                "Expected a window mirror"
            )
        }

        func tearDown() {
            controller.detach(host: host, sessionName: "input-map")
            writer.close()
            try? pipe.fileHandleForReading.close()
            let identifier = "cmux.main.\(windowId.uuidString)"
            NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    /// For every bonsplit pane in the mirror, the tmux id that the SELECT path
    /// resolves (`paneIdByBonsplitPane`, used by `didFocusPane` → `select-pane`)
    /// must equal the tmux id whose surface is RENDERED there and whose input
    /// handler therefore fires (`tmuxPaneId(forTab:)` of the pane's selected tab).
    private func expectSelectTargetMatchesInputTarget(
        _ mirror: RemoteTmuxWindowMirror
    ) throws {
        let paneIds = mirror.bonsplitController.allPaneIds
        #expect(paneIds.count >= 2, "Expected a multi-pane bonsplit tree")
        for bonsplitPane in paneIds {
            let selectTarget = try #require(
                mirror.paneIdByBonsplitPane[bonsplitPane],
                "Every rendered bonsplit pane must resolve a tmux select target"
            )
            let selectedTab = try #require(
                mirror.bonsplitController.selectedTab(inPane: bonsplitPane),
                "Every bonsplit pane renders a selected tab"
            )
            let inputTarget = try #require(
                mirror.tmuxPaneId(forTab: selectedTab.id),
                "The rendered tab must resolve to the tmux pane whose input handler fires"
            )
            #expect(
                selectTarget == inputTarget,
                "Pane selection routes to %\(selectTarget) but typed input reaches %\(inputTarget)"
            )
        }
    }

    /// Distinct panes render distinct surfaces, so a keystroke into one pane can
    /// never be swallowed by another pane's handler.
    private func expectDistinctSurfacesPerPane(_ mirror: RemoteTmuxWindowMirror) throws {
        let paneIds = mirror.paneIDsInOrder
        var surfaceIds: Set<UUID> = []
        for tmuxPaneId in paneIds {
            let panel = try #require(mirror.panel(forPane: tmuxPaneId), "Every live pane owns a panel")
            #expect(surfaceIds.insert(panel.surface.id).inserted, "Each pane must own a distinct surface")
        }
        #expect(surfaceIds.count == paneIds.count)
    }

    private func prepareSinglePaneInputSurface(
        in harness: Harness
    ) async throws -> TerminalSurface {
        harness.publishListWindows([
            "@2 f92f,80x24,0,0,4 f92f,80x24,0,0,4 [] vim",
        ])
        try harness.drainThroughPaneRects([
            2: ["%4 0 0 80 24 1 off :0 \"host\""],
        ])

        let manager = try #require(
            AppDelegate.shared?.tabManagerFor(windowId: harness.windowId)
        )
        manager.selectWorkspace(harness.workspace)
        let panel = try #require(try harness.mirror().panel(forPane: 4))
        panel.hostedView.setVisibleInUI(true)
        panel.hostedView.setActive(true)
        panel.hostedView.layoutSubtreeIfNeeded()
        await waitForLiveSurface(panel.surface)
        #expect(
            panel.surface.hasLiveSurface,
            "Remote manual-I/O key coverage requires a live Ghostty surface"
        )
        return panel.surface
    }

    private func waitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        for await _ in readiness { break }
    }

    private func captureInputCommands(
        in harness: Harness,
        expectedCount: Int,
        _ sendInput: () throws -> Void
    ) async throws -> [String] {
        let inputPipe = Pipe()
        let inputWriter = RemoteTmuxControlPipeWriter(
            handle: inputPipe.fileHandleForWriting,
            label: "remote-tmux-named-input-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        harness.connection.installStdinWriterForTesting(inputWriter)
        defer {
            harness.connection.installStdinWriterForTesting(harness.writer)
            inputWriter.close()
            try? inputPipe.fileHandleForReading.close()
        }

        try sendInput()
        var lineData = Data()
        var commands: [String] = []
        for try await byte in inputPipe.fileHandleForReading.bytes {
            guard byte == UInt8(ascii: "\n") else {
                lineData.append(byte)
                continue
            }
            let line = String(decoding: lineData, as: UTF8.self)
            lineData.removeAll(keepingCapacity: true)
            guard line.hasPrefix("send-keys -t %4 ") else { continue }
            commands.append(line)
            if commands.count == expectedCount { break }
        }
        inputWriter.close()
        harness.connection.installStdinWriterForTesting(harness.writer)
        return commands
    }

    private func sendPhysicalKey(
        _ keyCode: Int,
        functionScalar: UInt32,
        modifiers: NSEvent.ModifierFlags = [],
        to surface: TerminalSurface
    ) throws {
        let characters = String(try #require(UnicodeScalar(functionScalar)))
        #expect(surface.hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: characters,
            charactersIgnoringModifiers: characters,
            keyCode: UInt16(keyCode),
            modifierFlags: modifiers.union([.function, .numericPad])
        ))
    }

    @Test
    func remoteManualInputForwarderBoundsQueuedBytesAndSignalsOverflow() async throws {
        let (overflows, overflowContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let (deliveries, deliveryContinuation) =
            AsyncStream<(TerminalManualInput, Int)>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        var overflowIterator = overflows.makeAsyncIterator()
        var deliveryIterator = deliveries.makeAsyncIterator()
        var deliveredNames: [String] = []
        var overflowCount = 0

        let forwarder = RemoteTmuxPaneInputForwarder(
            maximumPendingBytes: 4,
            onInput: { input, paneID in
                if case .namedKey(let name) = input {
                    deliveredNames.append(name)
                }
                deliveryContinuation.yield((input, paneID))
            },
            onOverflow: {
                overflowCount += 1
                overflowContinuation.yield()
            }
        )

        #expect(
            forwarder.send(.bytes(Data([0x61, 0x62])), toPane: 4) == .enqueued
        )
        #expect(
            forwarder.send(.namedKey("End"), toPane: 4) == .overflow
        )
        #expect(
            forwarder.send(.bytes(Data([0x63])), toPane: 4) == .inactive
        )
        _ = try #require(await overflowIterator.next())
        #expect(overflowCount == 1)
        #expect(deliveredNames.isEmpty, "Overflow must invalidate buffered input")

        forwarder.setConnectionActive(true)
        #expect(
            forwarder.send(.namedKey("End"), toPane: 9) == .enqueued
        )
        let resumedDelivery = try #require(await deliveryIterator.next())
        guard case .namedKey(let name) = resumedDelivery.0 else {
            Issue.record("Expected a named-key delivery after reconnect")
            return
        }
        #expect(name == "End")
        #expect(resumedDelivery.1 == 9)
        #expect(deliveredNames == ["End"])
    }

    @Test
    func remoteManualInputDelegatesNavigationAndFunctionKeysToTmux() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let surface = try await prepareSinglePaneInputSurface(in: harness)

        let keys: [(name: String, code: Int, scalar: UInt32)] = [
            ("Home", kVK_Home, 0xF729),
            ("End", kVK_End, 0xF72B),
            ("IC", kVK_Help, 0xF727),
            ("DC", kVK_ForwardDelete, 0xF728),
            ("PPage", kVK_PageUp, 0xF72C),
            ("NPage", kVK_PageDown, 0xF72D),
            ("Up", kVK_UpArrow, 0xF700),
            ("Down", kVK_DownArrow, 0xF701),
            ("Left", kVK_LeftArrow, 0xF702),
            ("Right", kVK_RightArrow, 0xF703),
            ("F1", kVK_F1, 0xF704),
            ("F2", kVK_F2, 0xF705),
            ("F3", kVK_F3, 0xF706),
            ("F4", kVK_F4, 0xF707),
            ("F5", kVK_F5, 0xF708),
            ("F6", kVK_F6, 0xF709),
            ("F7", kVK_F7, 0xF70A),
            ("F8", kVK_F8, 0xF70B),
            ("F9", kVK_F9, 0xF70C),
            ("F10", kVK_F10, 0xF70D),
            ("F11", kVK_F11, 0xF70E),
            ("F12", kVK_F12, 0xF70F),
        ]
        let modifiedKeys: [
            (name: String, code: Int, scalar: UInt32, modifiers: NSEvent.ModifierFlags)
        ] = [
            ("C-Home", kVK_Home, 0xF729, [.control]),
            ("M-End", kVK_End, 0xF72B, [.option]),
            ("S-IC", kVK_Help, 0xF727, [.shift]),
            ("C-DC", kVK_ForwardDelete, 0xF728, [.control]),
            ("M-PPage", kVK_PageUp, 0xF72C, [.option]),
            ("C-NPage", kVK_PageDown, 0xF72D, [.control]),
            ("C-S-Right", kVK_RightArrow, 0xF703, [.control, .shift]),
            ("M-F2", kVK_F2, 0xF705, [.option]),
        ]

        let commands = try await captureInputCommands(
            in: harness,
            expectedCount: keys.count + modifiedKeys.count
        ) {
            for key in keys {
                try sendPhysicalKey(key.code, functionScalar: key.scalar, to: surface)
            }
            for key in modifiedKeys {
                try sendPhysicalKey(
                    key.code,
                    functionScalar: key.scalar,
                    modifiers: key.modifiers,
                    to: surface
                )
            }
        }

        let expected = (keys.map(\.name) + modifiedKeys.map(\.name)).map {
            "send-keys -t %4 \($0)"
        }
        #expect(commands == expected)
        #expect(
            commands.allSatisfy { !$0.contains(" -H ") },
            "Named keys must not carry the local Ghostty/xterm encoding into a tmux-256color pane"
        )
    }

    @Test
    func remoteManualInputKeepsLiteralTextOnHexPath() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let surface = try await prepareSinglePaneInputSurface(in: harness)

        let commands = try await captureInputCommands(in: harness, expectedCount: 1) {
            #expect(surface.hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
                characters: "x",
                charactersIgnoringModifiers: "x",
                keyCode: UInt16(kVK_ANSI_X)
            ))
        }

        #expect(commands == ["send-keys -t %4 -H 78"])
    }

    @Test
    func remoteManualInputPreservesLiteralAndNamedKeyOrder() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let surface = try await prepareSinglePaneInputSurface(in: harness)

        let commands = try await captureInputCommands(in: harness, expectedCount: 3) {
            #expect(surface.hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
                characters: "x",
                charactersIgnoringModifiers: "x",
                keyCode: UInt16(kVK_ANSI_X)
            ))
            try sendPhysicalKey(kVK_End, functionScalar: 0xF72B, to: surface)
            #expect(surface.hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
                characters: "y",
                charactersIgnoringModifiers: "y",
                keyCode: UInt16(kVK_ANSI_Y)
            ))
        }

        #expect(commands == [
            "send-keys -t %4 -H 78",
            "send-keys -t %4 End",
            "send-keys -t %4 -H 79",
        ])
    }

    @Test
    func remoteManualEndUsesTmuxForNormalLiveAndRestoredDECCKMState() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let surface = try await prepareSinglePaneInputSurface(in: harness)

        let commands = try await captureInputCommands(in: harness, expectedCount: 3) {
            surface.processRemoteOutput(Data("\u{1b}[?1l".utf8))
            try sendPhysicalKey(kVK_End, functionScalar: 0xF72B, to: surface)

            surface.processRemoteOutput(Data("\u{1b}[?1h".utf8))
            try sendPhysicalKey(kVK_End, functionScalar: 0xF72B, to: surface)

            let restoredApplicationMode = RemoteTmuxControlMessageDecoding()
                .paneStateSeedSequence(
                    from: "keypad_cursor_flag=1,keypad_flag=1"
                )
            surface.processRemoteOutput(restoredApplicationMode)
            try sendPhysicalKey(kVK_End, functionScalar: 0xF72B, to: surface)
        }

        #expect(commands == Array(repeating: "send-keys -t %4 End", count: 3))
        #expect(
            !commands.contains { $0.contains("1b 4f 46") || $0.contains("1b 5b 46") },
            "Neither xterm End encoding is correct for tmux-256color; tmux must translate the named key"
        )
    }

    @Test
    func sessionMirrorCanonicalizesModifiedNavigationAliases() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.publishListWindows([
            "@2 f92f,80x24,0,0,4 f92f,80x24,0,0,4 [] vim",
        ])
        try harness.drainThroughPaneRects([
            2: ["%4 0 0 80 24 1 off :0 \"host\""],
        ])
        let sessionMirror = try #require(harness.workspace.remoteTmuxSessionMirror)

        let commands = try await captureInputCommands(in: harness, expectedCount: 2) {
            let deleteResult = sessionMirror.sendKey(toPane: 4, name: "ctrl-del")
            let deleteWasSent: Bool
            if case .sent = deleteResult {
                deleteWasSent = true
            } else {
                deleteWasSent = false
            }
            try #require(
                deleteWasSent,
                "Modified Delete aliases must resolve before waiting for pipe output"
            )
            let upResult = sessionMirror.sendKey(toPane: 4, name: "shift-ctrl-arrow_up")
            let upWasSent: Bool
            if case .sent = upResult {
                upWasSent = true
            } else {
                upWasSent = false
            }
            try #require(
                upWasSent,
                "Modified arrow aliases must resolve before waiting for pipe output"
            )
        }

        #expect(commands == [
            "send-keys -t %4 C-DC",
            "send-keys -t %4 C-S-Up",
        ])
    }

    @Test
    func multiPaneWindowSelectTargetEqualsInputTargetForEveryPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.publishListWindows([
            "@2 abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} [] work",
        ])
        try harness.drainThroughPaneRects([2: [
            "%4 0 0 60 40 1 off :0 \"host\"",
            "%5 61 0 59 40 0 off :1 \"host\"",
        ]])

        let mirror = try harness.mirror()
        try expectSelectTargetMatchesInputTarget(mirror)
        try expectDistinctSurfacesPerPane(mirror)
    }

    /// tmux owns the pane's PTY and terminal protocol. The local Ghostty
    /// surface is only a rendering mirror, so it must encode user input without
    /// generating a second set of DA/OSC/DCS/size replies into tmux's input.
    @Test
    func remoteTmuxPaneUsesTransportOwnedTerminalProtocol() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.publishListWindows([
            "@2 f92f,80x24,0,0,4 f92f,80x24,0,0,4 [] yazi",
        ])
        try harness.drainThroughPaneRects([2: [
            "%4 0 0 80 24 1 off :0 \"host\"",
        ]])

        let mirror = try harness.mirror()
        let panel = try #require(mirror.panel(forPane: 4))
        #expect(panel.surface.ioMode == .manualMirror)
    }

    @Test
    func staleCachedActivePaneFallsBackToFirstLivePane() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@paneinput"),
            sessionName: "input-map"
        )
        connection.activePaneByWindow[2] = 99
        let layout = RemoteTmuxLayoutNode(
            width: 80,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 0, y: 0, content: .pane(4)),
                RemoteTmuxLayoutNode(width: 40, height: 24, x: 40, y: 0, content: .pane(5)),
            ])
        )

        let mirror = RemoteTmuxWindowMirror(
            windowId: 2,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            appearance: .default,
            makePanel: { _ in nil }
        )

        #expect(mirror.activePaneId == 4)
    }

    @Test
    func unresolvedSessionMirrorActivePaneFailsClosed() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.publishListWindows([
            "@2 abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} [] work",
        ])
        try harness.drainThroughPaneRects([2: [
            "%4 0 0 60 40 0 off :0 \"host\"",
            "%5 61 0 59 40 1 off :1 \"host\"",
        ]])

        let mirror = try harness.mirror()
        let sessionMirror = try #require(harness.workspace.remoteTmuxSessionMirror)
        let containerPanelId = try #require(sessionMirror.panelIdByWindow[2])
        let previousRemoteActivePane = harness.connection.activePaneByWindow[2]
        harness.connection.activePaneByWindow[2] = nil
        let previousOwnerWindow = sessionMirror.windowIdByPane.removeValue(forKey: 5)
        defer {
            harness.connection.activePaneByWindow[2] = previousRemoteActivePane
            sessionMirror.windowIdByPane[5] = previousOwnerWindow
        }

        #expect(mirror.activePaneId == 5)
        #expect(
            sessionMirror.activeControlPaneLocation(containerPanelID: containerPanelId) == nil
        )
        #expect(harness.workspace.focusedTerminalInputTarget() == nil)
    }

    /// The reported repro: a window cmux first saw as a single pane, then split.
    /// After the split + the `%window-pane-changed` event tmux emits (the new pane
    /// becomes active), the outer workspace tab must remain a container rather
    /// than also becoming an inner pane, and workspace focus navigation must enter
    /// the mirror and select the adjacent tmux pane.
    @Test
    func singlePaneToSplitKeepsSelectAndInputTargetsAlignedForNewPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tabManager = try #require(AppDelegate.shared?.tabManagerFor(windowId: harness.windowId))
        tabManager.selectWorkspace(harness.workspace)

        harness.publishListWindows([
            "@2 f92f,80x24,0,0,4 f92f,80x24,0,0,4 [] zsh",
        ])
        try harness.drainThroughPaneRects([2: ["%4 0 0 80 24 1 off :0 \"host\""]])

        let initialMirror = try harness.mirror()
        let originalPanePanel = try #require(initialMirror.panel(forPane: 4))
        let originalPaneSurface = originalPanePanel.surface
        let containerPanelId = try #require(
            harness.workspace.remoteTmuxSessionMirror?.panelIdByWindow[2]
        )
        let containerPanel = try #require(
            harness.workspace.panels[containerPanelId] as? TerminalPanel
        )

        #expect(
            TerminalController.shared.mobileTerminalPanels(in: harness.workspace).map(\.id)
                == [originalPanePanel.id],
            "Mobile must enumerate the live pane rather than the closed workspace container"
        )
        let initialMobileTarget = try #require(
            TerminalController.shared.mobileResolveWorkspaceAndSurface(
                params: [
                    "workspace_id": harness.workspace.id.uuidString,
                    "surface_id": originalPanePanel.id.uuidString,
                ],
                requireTerminal: true
            )
        )
        #expect(initialMobileTarget.surfaceId == originalPanePanel.id)
        let scriptTab = ScriptTab(windowId: harness.windowId, tabId: harness.workspace.id)
        #expect(scriptTab.terminals.map(\.stableID) == [originalPanePanel.id.uuidString])

        // tmux splits window @2: pane %5 is created and becomes the active pane.
        harness.connection.handleMessageForTesting(.layoutChange(
            windowId: 2,
            layout: "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5}",
            visibleLayout: nil,
            zoomed: false
        ))
        try harness.drainThroughPaneRects([2: [
            "%4 0 0 60 40 0 off :0 \"host\"",
            "%5 61 0 59 40 1 off :1 \"host\"",
        ]])
        // The active-pane notification the app receives for the newly split pane.
        harness.connection.handleMessageForTesting(.windowPaneChanged(windowId: 2, paneId: 5))

        let mirror = try harness.mirror()
        #expect(
            mirror === initialMirror,
            "A later split must reconcile the mirror created for the initial one-pane layout"
        )
        #expect(
            mirror.panel(forPane: 4) === originalPanePanel,
            "The original pane panel and its local scrollback must survive the split"
        )
        #expect(mirror.panel(forPane: 4)?.surface === originalPaneSurface)
        try expectSelectTargetMatchesInputTarget(mirror)
        try expectDistinctSurfacesPerPane(mirror)

        #expect(containerPanel.surface.portalBindingStateLabel() == "closed")
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: containerPanelId) == nil)
        for paneId in mirror.paneIDsInOrder {
            let panePanel = try #require(mirror.panel(forPane: paneId))
            #expect(
                containerPanel !== panePanel,
                "The outer workspace container must never also own inner tmux pane \(paneId)"
            )
        }

        // The freshly split pane is the one the user is looking at; it must be the
        // mirror's active/input target immediately, not the original pane.
        #expect(
            mirror.activePaneId == 5,
            "The newly split pane must be the active input target without a click; got \(String(describing: mirror.activePaneId))"
        )
        let expectedInputPanel = try #require(mirror.panel(forPane: 5))
        let expectedExternalPanelIDs = mirror.paneIDsInOrder.compactMap {
            mirror.panel(forPane: $0)?.id
        }
        #expect(
            TerminalController.shared.mobileTerminalPanels(in: harness.workspace).map(\.id)
                == expectedExternalPanelIDs
        )
        #expect(scriptTab.terminals.map(\.stableID) == expectedExternalPanelIDs.map(\.uuidString))
        #expect(scriptTab.focusedTerminal?.stableID == expectedInputPanel.id.uuidString)
        mirror.updatePaneCwd(paneId: 5, path: "/srv/project")
        #expect(harness.workspace.panelTitle(panelId: expectedInputPanel.id) == mirror.title(forPane: 5))
        #expect(harness.workspace.effectivePanelDirectory(panelId: expectedInputPanel.id) == "/srv/project")
        let notificationRouting = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: harness.workspace.id,
            surfaceID: expectedInputPanel.id,
            paneID: nil
        )
        let notificationResult = TerminalController.shared.controlNotificationCreateForTarget(
            routing: notificationRouting,
            workspaceID: harness.workspace.id,
            surfaceID: expectedInputPanel.id,
            title: "Projected tmux pane",
            subtitle: "",
            body: "Body"
        )
        #expect(notificationResult == .delivered(
            workspaceID: harness.workspace.id,
            surfaceID: expectedInputPanel.id,
            windowID: harness.windowId
        ))
        TerminalNotificationStore.shared.clearNotifications(forTabId: harness.workspace.id, surfaceId: expectedInputPanel.id)
        #expect(TerminalController.shared.resolveTerminalPanel(
            from: containerPanelId.uuidString,
            tabManager: tabManager
        ) === expectedInputPanel)
        #expect(TerminalController.shared.resolveTerminalPanel(
            from: expectedInputPanel.id.uuidString,
            tabManager: tabManager
        ) === expectedInputPanel)
        #expect(harness.workspace.focusedTerminalPanel === containerPanel)
        #expect(harness.workspace.focusedTerminalInputTarget()?.panel === expectedInputPanel)
        #expect(
            AppDelegate.resolveTerminalPanelForTextSend(
                in: harness.workspace,
                preferredPanelId: containerPanelId
            ) === expectedInputPanel
        )

        harness.workspace.moveFocus(direction: .left)

        #expect(
            mirror.activePaneId == 4,
            "Workspace directional focus must enter the nested mirror and select the adjacent tmux pane"
        )

        // Selecting the outer tab is part of every nested pane focus callback.
        // The outer tab's TerminalPanel is only a container: allowing
        // it to become active again makes its old surface steal first responder,
        // so the focus ring moves while keystrokes still reach the original pane.
        let containerPaneId = try #require(harness.workspace.paneId(forPanelId: containerPanelId))
        let containerTabId = try #require(harness.workspace.surfaceIdFromPanelId(containerPanelId))
        let activePanePanel = try #require(mirror.panel(forPane: 4))
        containerPanel.hostedView.setActive(true)
        activePanePanel.hostedView.setActive(false)

        harness.workspace.applyTabSelection(tabId: containerTabId, inPane: containerPaneId)

        #expect(
            !containerPanel.hostedView.debugPortalActive,
            "A window container must never compete with its inner panes for input focus"
        )
        #expect(
            activePanePanel.hostedView.debugPortalActive,
            "Selecting the window container must activate the tmux-active inner pane"
        )

        harness.workspace.focusRemoteTmuxContainerPaneIfNeeded(containerPaneId)

        #expect(!containerPanel.hostedView.debugPortalActive)
        #expect(activePanePanel.hostedView.debugPortalActive)

        // A real nested edge may continue into the outer workspace tree, but a
        // stale nested identity must fail closed instead of looking like that
        // edge. Otherwise a transient pane-map mismatch can move focus into an
        // unrelated outer split.
        harness.workspace.isRemoteTmuxMirror = false
        let outerNeighborCandidate = harness.workspace.splitPaneWithNewTerminal(
            targetPane: containerPaneId,
            orientation: .horizontal,
            insertFirst: false,
            workingDirectory: nil,
            initialInput: nil
        )
        harness.workspace.isRemoteTmuxMirror = true
        let outerNeighbor = try #require(outerNeighborCandidate)
        let outerNeighborPaneId = try #require(
            harness.workspace.paneId(forPanelId: outerNeighbor.id)
        )

        mirror.setActivePane(5, fromTmux: true)
        harness.workspace.focusPanel(containerPanelId)
        harness.workspace.moveFocus(direction: .right)

        #expect(
            harness.workspace.bonsplitController.focusedPaneId == outerNeighborPaneId,
            "A valid edge in the nested tree must continue into the outer workspace tree"
        )

        mirror.setActivePane(5, fromTmux: true)
        harness.workspace.focusPanel(containerPanelId)
        let staleFocusedPane = try #require(mirror.bonsplitController.focusedPaneId)
        mirror.paneIdByBonsplitPane[staleFocusedPane] = nil

        harness.workspace.moveFocus(direction: .right)

        #expect(
            harness.workspace.bonsplitController.focusedPaneId == containerPaneId,
            "An invalid nested focus identity must not escape into an outer workspace pane"
        )
    }
}
