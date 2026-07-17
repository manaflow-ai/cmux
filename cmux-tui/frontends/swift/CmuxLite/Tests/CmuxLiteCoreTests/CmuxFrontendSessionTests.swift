@testable import CmuxLiteCore
import Foundation
import Testing

@Suite(.serialized)
struct CmuxFrontendSessionTests {
    @Test
    func protocolSixIsRejectedBeforeRenderAttach() async {
        let control = ScriptedTransport(
            role: .control(tree: tree(activeTab: 0, tabSurfaces: [11])),
            protocolVersion: 6
        )
        let attachment = ScriptedTransport(role: .attachment(surface: 11))
        let session = makeSession(control: control, attachments: [attachment])

        do {
            _ = try await session.connect(hostname: "test")
            Issue.record("protocol 6 should not enter render mode")
        } catch let error as CmuxProtocolError {
            #expect(error.description.contains("protocol 7 or newer"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(!(await attachment.commandSummaries()).contains { $0.hasPrefix("attach-surface") })
        await session.close()
    }

    @Test
    func visibleSplitPanesAttachIndependentlyAndDetachOnScreenChange() async throws {
        let tree = Data(
            #"{"workspaces":[{"id":4,"name":"phone","active":true,"screens":[{"id":101,"name":null,"active":true,"active_pane":201,"zoomed_pane":null,"layout":{"type":"split","dir":"right","ratio":0.5,"a":{"type":"leaf","pane":201},"b":{"type":"leaf","pane":202}},"panes":[{"id":201,"active_tab":0,"tabs":[{"surface":11,"kind":"pty","name":null,"title":"left","size":{"cols":80,"rows":24},"dead":false}],"dead":false},{"id":202,"active_tab":0,"tabs":[{"surface":12,"kind":"pty","name":null,"title":"right","size":{"cols":80,"rows":24},"dead":false}],"dead":false}]},{"id":102,"name":null,"active":false,"active_pane":203,"zoomed_pane":null,"layout":{"type":"leaf","pane":203},"panes":[{"id":203,"active_tab":0,"tabs":[{"surface":13,"kind":"pty","name":null,"title":"other","size":{"cols":80,"rows":24},"dead":false}],"dead":false}]}]}]}"#.utf8
        )
        let control = ScriptedTransport(role: .control(tree: tree))
        let attachments = [11, 12, 13].map {
            ScriptedTransport(role: .attachment(surface: $0))
        }
        let session = makeSession(control: control, attachments: attachments)

        let initial = try await session.connect(hostname: "test")
        #expect(initial.surfaces == [11, 12])
        #expect(await attachments[0].commandSummaries().contains("attach-surface:11:render"))
        #expect(await attachments[1].commandSummaries().contains("attach-surface:12:render"))

        try await session.sendText("left", surface: 11)
        try await session.sendText("right", surface: 12)
        #expect(await attachments[0].commandSummaries().contains("send:left"))
        #expect(await attachments[1].commandSummaries().contains("send:right"))

        let selected = try await session.selectScreen(102)
        #expect(selected.surfaces == [13])
        #expect(await attachments[0].isClosed())
        #expect(await attachments[1].isClosed())
        #expect(await attachments[2].isClosed() == false)
        await session.close()
        #expect(await attachments[2].isClosed())
    }

    @Test
    func navigationIsLocalAndClosesThePreviousAttachment() async throws {
        let harness = makeHarness(attachmentSurfaces: [11, 12])
        let initial = try await harness.session.connect(hostname: "test")

        #expect(initial.selectedWorkspace == 4)
        #expect(initial.selectedScreen == 101)
        #expect(initial.surface == 11)
        #expect(initial.sessionName == "phone")

        let selected = try await harness.session.selectScreen(102)
        #expect(selected.selectedWorkspace == 4)
        #expect(selected.selectedScreen == 102)
        #expect(selected.surface == 12)
        #expect(await harness.attachments[0].isClosed())

        let controlCommands = await harness.control.commandSummaries()
        #expect(!controlCommands.contains("select-workspace"))
        #expect(!controlCommands.contains("select-screen"))
        #expect(await harness.attachments[0].commandSummaries().contains("attach-surface:11:render"))
        #expect(await harness.attachments[1].commandSummaries().contains("attach-surface:12:render"))

        await harness.session.close()
        #expect(await harness.attachments[1].isClosed())
    }

    @Test
    func inputDoesNotClaimTheLocalGridAfterASharedResize() async throws {
        let harness = makeHarness(attachmentSurfaces: [11])
        let events = await harness.session.events()
        _ = try await harness.session.connect(hostname: "test")
        await harness.session.recordTerminalMeasurement(CmuxTerminalMeasurement(
            widthPixels: 1_200,
            heightPixels: 800,
            cellWidthPixels: 10,
            cellHeightPixels: 20
        ))

        let observedResize = Task {
            for await event in events {
                if case .terminal(.renderDelta(let delta)) = event, delta.size != nil { return }
            }
        }
        await harness.attachments[0].emitResized(surface: 11, columns: 70, rows: 20)
        await observedResize.value
        try await harness.session.sendText("typed")

        let commands = await harness.attachments[0].commandSummaries()
        #expect(!commands.contains("resize-surface:120x40"))
        #expect(commands.contains("send:typed"))
        await harness.session.close()
    }

    @Test
    func workspaceAndScreenCreationSendTheActivePaneGrid() async throws {
        let workspaceHarness = makeHarness(attachmentSurfaces: [11, 13])
        _ = try await workspaceHarness.session.connect(hostname: "test")
        await workspaceHarness.session.recordTerminalMeasurement(CmuxTerminalMeasurement(
            widthPixels: 1_200,
            heightPixels: 800,
            cellWidthPixels: 10,
            cellHeightPixels: 20
        ))
        let workspace = try await workspaceHarness.session.newWorkspace(pane: 201)
        #expect(workspace.selectedWorkspace == 8)
        #expect(workspace.selectedScreen == 103)
        #expect(workspace.surface == 13)
        #expect(await workspaceHarness.attachments[0].isClosed())
        #expect(await workspaceHarness.control.commandSummaries().contains("new-workspace:120x40"))
        await workspaceHarness.session.close()

        let screenHarness = makeHarness(attachmentSurfaces: [11, 12])
        _ = try await screenHarness.session.connect(hostname: "test")
        await screenHarness.session.recordTerminalMeasurement(CmuxTerminalMeasurement(
            widthPixels: 1_110,
            heightPixels: 760,
            cellWidthPixels: 10,
            cellHeightPixels: 20
        ))
        let screen = try await screenHarness.session.newScreen(pane: 201)
        #expect(screen.selectedWorkspace == 4)
        #expect(screen.selectedScreen == 102)
        #expect(screen.surface == 12)
        #expect(await screenHarness.control.commandSummaries().contains("new-screen:4:111x38"))
        await screenHarness.session.close()
    }

    @Test
    func tabSelectionMapsThePaneAndIndexToSelectTab() async throws {
        let initialTree = tree(activeTab: 0, tabSurfaces: [11, 12])
        let selectedTree = tree(activeTab: 1, tabSurfaces: [11, 12])
        let control = ScriptedTransport(
            role: .control(tree: initialTree),
            treeAfterSelectTab: selectedTree
        )
        let attachments = [11, 12].map {
            ScriptedTransport(role: .attachment(surface: $0))
        }
        let session = makeSession(control: control, attachments: attachments)

        _ = try await session.connect(hostname: "test")
        let selected = try await session.selectTab(pane: 201, index: 1)

        #expect(selected.surface == 12)
        #expect(selected.workspaces[0].screens[0].activeTab == 1)
        #expect(selected.workspaces[0].screens[0].tabs.map(\.surface) == [11, 12])
        #expect(await attachments[0].isClosed())
        #expect(await control.commandSummaries().contains("select-tab:201:1"))
        await session.close()
    }

    @Test
    func newTabUsesTheMeasuredGridAndFollowsItsSurface() async throws {
        let initialTree = tree(activeTab: 0, tabSurfaces: [11])
        let createdTree = tree(activeTab: 1, tabSurfaces: [11, 14])
        let control = ScriptedTransport(
            role: .control(tree: initialTree),
            treeAfterNewTab: createdTree,
            newTabSurface: 14
        )
        let attachments = [11, 14].map {
            ScriptedTransport(role: .attachment(surface: $0))
        }
        let session = makeSession(control: control, attachments: attachments)

        _ = try await session.connect(hostname: "test")
        await session.recordTerminalMeasurement(CmuxTerminalMeasurement(
            widthPixels: 1_200,
            heightPixels: 800,
            cellWidthPixels: 10,
            cellHeightPixels: 20
        ))
        let created = try await session.newTab(pane: 201)

        #expect(created.surface == 14)
        #expect(created.workspaces[0].screens[0].activeTab == 1)
        #expect(await control.commandSummaries().contains("new-tab:201:120x40"))
        #expect(await attachments[0].isClosed())
        await session.close()
    }

    @Test
    func splitUsesTheMeasuredActivePaneGrid() async throws {
        let initialTree = tree(activeTab: 0, tabSurfaces: [11])
        let createdTree = tree(activeTab: 0, tabSurfaces: [11, 14])
        let control = ScriptedTransport(
            role: .control(tree: initialTree),
            treeAfterSplit: createdTree,
            splitSurface: 14
        )
        let attachments = [11, 14].map {
            ScriptedTransport(role: .attachment(surface: $0))
        }
        let session = makeSession(control: control, attachments: attachments)

        _ = try await session.connect(hostname: "test")
        await session.recordTerminalMeasurement(CmuxTerminalMeasurement(
            widthPixels: 1_000,
            heightPixels: 600,
            cellWidthPixels: 10,
            cellHeightPixels: 20
        ))
        _ = try await session.split(pane: 201, direction: .right)

        #expect(await control.commandSummaries().contains("split:201:right:100x30"))
        await session.close()
    }

    private func makeHarness(
        attachmentSurfaces: [UInt64]
    ) -> (
        session: CmuxFrontendSession,
        control: ScriptedTransport,
        attachments: [ScriptedTransport]
    ) {
        let tree = Data(
            #"{"workspaces":[{"id":4,"name":"phone-a","active":true,"screens":[{"id":101,"name":null,"active":true,"active_pane":201,"panes":[{"id":201,"active_tab":0,"tabs":[{"surface":11,"kind":"pty","name":null,"title":"shell one","size":{"cols":80,"rows":24},"dead":false}],"dead":false}]},{"id":102,"name":null,"active":false,"active_pane":202,"panes":[{"id":202,"active_tab":0,"tabs":[{"surface":12,"kind":"pty","name":null,"title":"shell two","size":{"cols":80,"rows":24},"dead":false}],"dead":false}]}]},{"id":8,"name":"phone-b","active":false,"screens":[{"id":103,"name":null,"active":true,"active_pane":203,"panes":[{"id":203,"active_tab":0,"tabs":[{"surface":13,"kind":"pty","name":null,"title":"shell three","size":{"cols":80,"rows":24},"dead":false}],"dead":false}]}]}]}"#.utf8
        )
        let control = ScriptedTransport(role: .control(tree: tree))
        let attachments = attachmentSurfaces.map {
            ScriptedTransport(role: .attachment(surface: $0))
        }
        let factory = ScriptedClientFactory(transports: attachments)
        let configuration = CmuxConnectionConfiguration(
            url: URL(string: "ws://127.0.0.1:7682")!,
            token: "test"
        )
        let session = CmuxFrontendSession(
            client: CmuxProtocolClient(transport: control),
            attachmentClientFactory: factory,
            configuration: configuration,
            resizeDebounce: .zero
        )
        return (session, control, attachments)
    }

    private func makeSession(
        control: ScriptedTransport,
        attachments: [ScriptedTransport]
    ) -> CmuxFrontendSession {
        let configuration = CmuxConnectionConfiguration(
            url: URL(string: "ws://127.0.0.1:7682")!,
            token: "test"
        )
        return CmuxFrontendSession(
            client: CmuxProtocolClient(transport: control),
            attachmentClientFactory: ScriptedClientFactory(transports: attachments),
            configuration: configuration,
            resizeDebounce: .zero
        )
    }

    private func tree(activeTab: Int, tabSurfaces: [UInt64]) -> Data {
        let tabs = tabSurfaces.enumerated().map { index, surface in
            "{\"surface\":\(surface),\"kind\":\"pty\",\"name\":null,\"title\":\"tab \(index + 1)\",\"size\":{\"cols\":80,\"rows\":24},\"dead\":false}"
        }.joined(separator: ",")
        return Data(
            "{\"workspaces\":[{\"id\":4,\"name\":\"phone-a\",\"active\":true,\"screens\":[{\"id\":101,\"name\":null,\"active\":true,\"active_pane\":201,\"panes\":[{\"id\":201,\"active_tab\":\(activeTab),\"tabs\":[\(tabs)],\"dead\":false}]}]}]}".utf8
        )
    }
}
