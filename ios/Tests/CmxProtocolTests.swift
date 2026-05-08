import Foundation
import XCTest
@testable import cmux_ios

final class CmxProtocolTests: XCTestCase {
    func testHelloEncodingMatchesCmxNamedMessagePackShape() throws {
        let payload = try CmxWireCodec.encode(
            .hello(viewport: CmxWireViewport(cols: 80, rows: 24), token: nil)
        )

        XCTAssertEqual(payload, Data([
            0x84,
            0xA4, 0x6B, 0x69, 0x6E, 0x64,
            0xA5, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
            0xA7, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E,
            0x03,
            0xA8, 0x76, 0x69, 0x65, 0x77, 0x70, 0x6F, 0x72, 0x74,
            0x82,
            0xA4, 0x63, 0x6F, 0x6C, 0x73,
            0x50,
            0xA4, 0x72, 0x6F, 0x77, 0x73,
            0x18,
            0xA5, 0x74, 0x6F, 0x6B, 0x65, 0x6E,
            0xC0,
        ]))
    }

    func testInputEncodingUsesMessagePackBinary() throws {
        let payload = try CmxWireCodec.encode(.input(Data("ok".utf8)))

        XCTAssertEqual(payload, Data([
            0x82,
            0xA4, 0x6B, 0x69, 0x6E, 0x64,
            0xA5, 0x69, 0x6E, 0x70, 0x75, 0x74,
            0xA4, 0x64, 0x61, 0x74, 0x61,
            0xC4, 0x02, 0x6F, 0x6B,
        ]))
    }

    func testHelloNativeRequestsClientSideLibghosttyRendering() throws {
        let payload = try CmxWireCodec.encode(
            .helloNative(viewport: CmxWireViewport(cols: 80, rows: 24), token: "sekrit")
        )

        XCTAssertNotNil(payload.range(of: Data("hello_native".utf8)))
        XCTAssertNotNil(payload.range(of: Data("terminal_renderer".utf8)))
        XCTAssertNotNil(payload.range(of: Data("libghostty".utf8)))
    }

    func testCommandEncodingSelectsNativeTabInPanel() throws {
        let payload = try CmxWireCodec.encode(
            .command(id: 7, .selectTabInPanel(panelID: 31, index: 2))
        )

        XCTAssertNotNil(payload.range(of: Data("command".utf8)))
        XCTAssertNotNil(payload.range(of: Data("select-tab-in-panel".utf8)))
        XCTAssertNotNil(payload.range(of: Data("panel_id".utf8)))
        XCTAssertNotNil(payload.range(of: Data("index".utf8)))
    }

    func testCommandEncodingMovesTabToPanelWithExplicitFocus() throws {
        let payload = try CmxWireCodec.encode(
            .command(
                id: 8,
                .moveTabToPanel(fromPanelID: 31, from: 2, toPanelID: 41, to: 0, focus: false)
            )
        )

        XCTAssertNotNil(payload.range(of: Data("move-tab-to-panel".utf8)))
        XCTAssertNotNil(payload.range(of: Data("from_panel_id".utf8)))
        XCTAssertNotNil(payload.range(of: Data("to_panel_id".utf8)))
        XCTAssertNotNil(payload.range(of: Data("focus".utf8)))
        XCTAssertNotNil(payload.range(of: Data([0xC2])))
    }

    func testCommandEncodingMovesTabToSplitWithExplicitFocus() throws {
        let payload = try CmxWireCodec.encode(
            .command(
                id: 9,
                .moveTabToSplit(fromPanelID: 31, from: 2, targetPanelID: 41, edge: .left, focus: false)
            )
        )

        XCTAssertNotNil(payload.range(of: Data("move-tab-to-split".utf8)))
        XCTAssertNotNil(payload.range(of: Data("from_panel_id".utf8)))
        XCTAssertNotNil(payload.range(of: Data("target_panel_id".utf8)))
        XCTAssertNotNil(payload.range(of: Data("edge".utf8)))
        XCTAssertNotNil(payload.range(of: Data("left".utf8)))
        XCTAssertNotNil(payload.range(of: Data("focus".utf8)))
        XCTAssertNotNil(payload.range(of: Data([0xC2])))
    }

    func testCommandEncodingSetsTabTitleByStableID() throws {
        let rename = try CmxWireCodec.encode(
            .command(id: 10, .setTabTitleByID(tabID: 51, title: "Build Logs", explicit: true))
        )
        let clear = try CmxWireCodec.encode(
            .command(id: 11, .setTabTitleByID(tabID: 51, title: nil, explicit: false))
        )

        XCTAssertNotNil(rename.range(of: Data("set-tab-title-by-id".utf8)))
        XCTAssertNotNil(rename.range(of: Data("tab_id".utf8)))
        XCTAssertNotNil(rename.range(of: Data("Build Logs".utf8)))
        XCTAssertNotNil(rename.range(of: Data("explicit".utf8)))
        XCTAssertNotNil(rename.range(of: Data([0xC3])))
        XCTAssertNotNil(clear.range(of: Data("set-tab-title-by-id".utf8)))
        XCTAssertNotNil(clear.range(of: Data("title".utf8)))
        XCTAssertNotNil(clear.range(of: Data([0xC0])))
        XCTAssertNotNil(clear.range(of: Data([0xC2])))
    }

    func testCommandEncodingSetsWorkspacePinnedUnreadDescriptionAndColorState() throws {
        let pinned = try CmxWireCodec.encode(
            .command(id: 8, .setWorkspacePinned(workspaceID: 42, pinned: true))
        )
        let unread = try CmxWireCodec.encode(
            .command(id: 9, .setWorkspaceUnread(workspaceID: 42, unread: false))
        )
        let description = try CmxWireCodec.encode(
            .command(id: 10, .setWorkspaceDescriptionByID(workspaceID: 42, description: "Build queue"))
        )
        let color = try CmxWireCodec.encode(
            .command(id: 11, .setWorkspaceColorByID(workspaceID: 42, color: "#112233"))
        )

        XCTAssertNotNil(pinned.range(of: Data("set-workspace-pinned".utf8)))
        XCTAssertNotNil(pinned.range(of: Data("workspace_id".utf8)))
        XCTAssertNotNil(pinned.range(of: Data("pinned".utf8)))
        XCTAssertNotNil(unread.range(of: Data("set-workspace-unread".utf8)))
        XCTAssertNotNil(unread.range(of: Data("workspace_id".utf8)))
        XCTAssertNotNil(unread.range(of: Data("unread".utf8)))
        XCTAssertNotNil(description.range(of: Data("set-workspace-description-by-id".utf8)))
        XCTAssertNotNil(description.range(of: Data("workspace_id".utf8)))
        XCTAssertNotNil(description.range(of: Data("Build queue".utf8)))
        XCTAssertNotNil(color.range(of: Data("set-workspace-color-by-id".utf8)))
        XCTAssertNotNil(color.range(of: Data("workspace_id".utf8)))
        XCTAssertNotNil(color.range(of: Data("#112233".utf8)))
    }

    func testCommandEncodingTargetsWorkspaceByIDForCloseAndRename() throws {
        let close = try CmxWireCodec.encode(
            .command(id: 10, .closeWorkspaceByID(workspaceID: 42))
        )
        let rename = try CmxWireCodec.encode(
            .command(id: 11, .renameWorkspaceByID(workspaceID: 42, title: "Renamed"))
        )

        XCTAssertNotNil(close.range(of: Data("close-workspace-by-id".utf8)))
        XCTAssertNotNil(close.range(of: Data("workspace_id".utf8)))
        XCTAssertNotNil(rename.range(of: Data("rename-workspace-by-id".utf8)))
        XCTAssertNotNil(rename.range(of: Data("workspace_id".utf8)))
        XCTAssertNotNil(rename.range(of: Data("Renamed".utf8)))
    }

    func testPingEncodingKeepsNativeWebSocketClientAlive() throws {
        let payload = try CmxWireCodec.encode(.ping)

        XCTAssertEqual(payload, Data([
            0x81,
            0xA4, 0x6B, 0x69, 0x6E, 0x64,
            0xA4, 0x70, 0x69, 0x6E, 0x67,
        ]))
    }

    func testClientLatencyEncodingReportsMeasuredRoundTrip() throws {
        let payload = try CmxWireCodec.encode(.clientLatency(milliseconds: 42))

        XCTAssertNotNil(payload.range(of: Data("client_latency".utf8)))
        XCTAssertNotNil(payload.range(of: Data("latency_ms".utf8)))
        XCTAssertNotNil(payload.range(of: Data([42])))
    }

    func testDecodeWelcome() throws {
        let payload = Data([
            0x83,
            0xA4, 0x6B, 0x69, 0x6E, 0x64,
            0xA7, 0x77, 0x65, 0x6C, 0x63, 0x6F, 0x6D, 0x65,
            0xAE, 0x73, 0x65, 0x72, 0x76, 0x65, 0x72, 0x5F,
            0x76, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E,
            0xA5, 0x30, 0x2E, 0x31, 0x2E, 0x30,
            0xAA, 0x73, 0x65, 0x73, 0x73, 0x69, 0x6F, 0x6E,
            0x5F, 0x69, 0x64,
            0xA3, 0x61, 0x62, 0x63,
        ])

        XCTAssertEqual(
            try CmxWireCodec.decodeServerMessage(payload),
            .welcome(serverVersion: "0.1.0", sessionID: "abc")
        )
    }

    func testDecodeCommandReplyIgnoresResultShape() throws {
        var writer = MessagePackWriter()
        writer.writeMapHeader(3)
        writer.writeString("kind")
        writer.writeString("command_reply")
        writer.writeString("id")
        writer.writeUInt(7)
        writer.writeString("result")
        writer.writeMapHeader(1)
        writer.writeString("ok")
        writer.writeBool(true)

        XCTAssertEqual(try CmxWireCodec.decodeServerMessage(writer.data), .commandReply(id: 7))
    }

    func testDecodePtyBytes() throws {
        let payload = Data([
            0x83,
            0xA4, 0x6B, 0x69, 0x6E, 0x64,
            0xA9, 0x70, 0x74, 0x79, 0x5F, 0x62, 0x79, 0x74, 0x65, 0x73,
            0xA6, 0x74, 0x61, 0x62, 0x5F, 0x69, 0x64,
            0x07,
            0xA4, 0x64, 0x61, 0x74, 0x61,
            0xC4, 0x02, 0x1B, 0x5B,
        ])

        XCTAssertEqual(
            try CmxWireCodec.decodeServerMessage(payload),
            .ptyBytes(tabID: 7, data: Data([0x1B, 0x5B]))
        )
    }

    func testDecodeRejectsOutOfRangeIntFields() {
        var writer = MessagePackWriter()
        writer.writeMapHeader(3)
        writer.writeString("kind")
        writer.writeString("active_tab_changed")
        writer.writeString("index")
        writer.writeUInt(UInt64.max)
        writer.writeString("tab_id")
        writer.writeUInt(1)

        XCTAssertThrowsError(try CmxWireCodec.decodeServerMessage(writer.data)) { error in
            XCTAssertEqual(error as? CmxWireError, .invalidMessage("index is out of range."))
        }
    }

    func testDecodeRejectsOversizedMessagePackCollectionsBeforeAllocating() {
        XCTAssertThrowsError(try CmxWireCodec.decodeServerMessage(Data([0xDD, 0xFF, 0xFF, 0xFF, 0xFF]))) { error in
            XCTAssertEqual(error as? CmxWireError, .invalidMessage("MessagePack array is too large."))
        }
    }

    func testFramePrefixesBigEndianLength() throws {
        XCTAssertEqual(
            try CmxWireCodec.frame(Data([0x01, 0x02])),
            Data([0x00, 0x00, 0x00, 0x02, 0x01, 0x02])
        )
    }

    func testDecodeNativeSnapshot() throws {
        var writer = MessagePackWriter()
        writer.writeMapHeader(2)
        writer.writeString("kind")
        writer.writeString("native_snapshot")
        writer.writeString("snapshot")
        writeNativeSnapshot(to: &writer)

        let message = try CmxWireCodec.decodeServerMessage(writer.data)

        guard case .nativeSnapshot(let snapshot) = message else {
            return XCTFail("expected native snapshot, got \(message)")
        }
        XCTAssertEqual(snapshot.activeWorkspaceID, 11)
        XCTAssertEqual(snapshot.activeSpaceID, 21)
        XCTAssertEqual(snapshot.focusedPanelID, 31)
        XCTAssertEqual(snapshot.focusedTabID, 41)
        XCTAssertEqual(snapshot.workspaces.map(\.title), ["main", "agents"])
        XCTAssertEqual(snapshot.workspaces.first?.externalID, UUID(uuidString: "c0de0001-c0de-4000-8000-00000000000b"))
        XCTAssertEqual(snapshot.workspaces.first?.description, "Main workspace")
        XCTAssertEqual(snapshot.workspaces.first?.latestSubmittedMessage, "Build the prompt submit path")
        XCTAssertEqual(snapshot.spaces.map(\.title), ["space-a"])
        XCTAssertEqual(snapshot.panels.flattenedTabs.map(\.id), [41, 42])
        XCTAssertEqual(
            snapshot.panels.flattenedTabs.map(\.externalID),
            [
                UUID(uuidString: "c0de0002-c0de-4000-8000-000000000029"),
                UUID(uuidString: "c0de0002-c0de-4000-8000-00000000002a"),
            ]
        )
        XCTAssertEqual(snapshot.panels.selection(for: 42), CmxNativeTabSelection(panelID: 31, index: 1))
        XCTAssertEqual(snapshot.terminalTheme?.defaultTheme?.palette[1], "#f92672")
        XCTAssertEqual(snapshot.terminalTheme?.defaultTheme?.background, "#272822")
        XCTAssertEqual(snapshot.terminalFont?.families, ["JetBrains Mono"])
        XCTAssertEqual(snapshot.terminalFont?.size, 13.0)
        XCTAssertEqual(snapshot.terminalCursor?.style, "block")
        XCTAssertEqual(snapshot.terminalCursor?.blink, true)
        XCTAssertEqual(snapshot.attachedClients.first?.kind, .native)
        XCTAssertEqual(snapshot.attachedClients.first?.terminals.first, CmxWireTerminalViewport(tabID: 41, cols: 30, rows: 30))
        XCTAssertTrue(snapshot.ghosttyConfigFragment(colorPreference: .dark)?.contains("palette = 1=#f92672") == true)
        XCTAssertTrue(snapshot.ghosttyConfigFragment(colorPreference: .dark)?.contains("background = #272822") == true)
        XCTAssertTrue(snapshot.ghosttyConfigFragment(colorPreference: .dark)?.contains("cursor-style = block") == true)
        XCTAssertTrue(snapshot.ghosttyConfigFragment(colorPreference: .dark)?.contains("cursor-style-blink = true") == true)
    }

    func testDecodeTerminalGridSnapshot() throws {
        var writer = MessagePackWriter()
        writer.writeMapHeader(2)
        writer.writeString("kind")
        writer.writeString("terminal_grid_snapshot")
        writer.writeString("snapshot")
        writer.writeMapHeader(5)
        writer.writeString("tab_id")
        writer.writeUInt(41)
        writer.writeString("cols")
        writer.writeUInt(80)
        writer.writeString("rows")
        writer.writeUInt(24)
        writer.writeString("cells")
        writer.writeArrayHeader(1)
        writeCell(text: "A", to: &writer)
        writer.writeString("cursor")
        writer.writeMapHeader(6)
        writer.writeString("col")
        writer.writeUInt(1)
        writer.writeString("row")
        writer.writeUInt(2)
        writer.writeString("visible")
        writer.writeBool(true)
        writer.writeString("style")
        writer.writeString("bar")
        writer.writeString("blink")
        writer.writeBool(false)
        writer.writeString("color")
        writeRGB(255, 0, 0, to: &writer)

        let message = try CmxWireCodec.decodeServerMessage(writer.data)

        guard case .terminalGridSnapshot(let snapshot) = message else {
            return XCTFail("expected terminal grid snapshot, got \(message)")
        }
        XCTAssertEqual(snapshot.tabID, 41)
        XCTAssertEqual(snapshot.cells.first?.fg, CmxTerminalRGB(r: 1, g: 2, b: 3))
        XCTAssertEqual(snapshot.cursor?.style, .bar)
        XCTAssertEqual(snapshot.cursor?.blink, false)
        XCTAssertEqual(snapshot.cursor?.color, CmxTerminalRGB(r: 255, g: 0, b: 0))
    }

    private func writeNativeSnapshot(to writer: inout MessagePackWriter) {
        writer.writeMapHeader(13)
        writer.writeString("workspaces")
        writer.writeArrayHeader(2)
        writeWorkspace(id: 11, title: "main", spaces: 1, terminals: 2, pinned: true, to: &writer)
        writeWorkspace(id: 12, title: "agents", spaces: 0, terminals: 0, pinned: false, to: &writer)
        writer.writeString("active_workspace")
        writer.writeUInt(0)
        writer.writeString("active_workspace_id")
        writer.writeUInt(11)
        writer.writeString("spaces")
        writer.writeArrayHeader(1)
        writeSpace(id: 21, title: "space-a", to: &writer)
        writer.writeString("active_space")
        writer.writeUInt(0)
        writer.writeString("active_space_id")
        writer.writeUInt(21)
        writer.writeString("panels")
        writer.writeMapHeader(5)
        writer.writeString("kind")
        writer.writeString("leaf")
        writer.writeString("panel_id")
        writer.writeUInt(31)
        writer.writeString("tabs")
        writer.writeArrayHeader(2)
        writeTab(id: 41, title: "shell", active: false, to: &writer)
        writeTab(id: 42, title: "logs", active: true, to: &writer)
        writer.writeString("active")
        writer.writeUInt(0)
        writer.writeString("active_tab_id")
        writer.writeUInt(41)
        writer.writeString("focused_panel_id")
        writer.writeUInt(31)
        writer.writeString("focused_tab_id")
        writer.writeUInt(41)
        writer.writeString("terminal_theme")
        writer.writeMapHeader(1)
        writer.writeString("default")
        writer.writeMapHeader(2)
        writer.writeString("palette")
        writer.writeMapHeader(1)
        writer.writeUInt(1)
        writer.writeString("#f92672")
        writer.writeString("background")
        writer.writeString("#272822")
        writer.writeString("terminal_font")
        writer.writeMapHeader(2)
        writer.writeString("families")
        writer.writeArrayHeader(1)
        writer.writeString("JetBrains Mono")
        writer.writeString("size")
        writer.writeFloat64(13.0)
        writer.writeString("terminal_cursor")
        writer.writeMapHeader(2)
        writer.writeString("style")
        writer.writeString("block")
        writer.writeString("blink")
        writer.writeBool(true)
        writer.writeString("attached_clients")
        writer.writeArrayHeader(1)
        writer.writeMapHeader(6)
        writer.writeString("client_id")
        writer.writeString("ios")
        writer.writeString("kind")
        writer.writeString("native")
        writer.writeString("visible_terminal_count")
        writer.writeUInt(1)
        writer.writeString("updated_at_ms")
        writer.writeUInt(123)
        writer.writeString("terminals")
        writer.writeArrayHeader(1)
        writer.writeMapHeader(3)
        writer.writeString("tab_id")
        writer.writeUInt(41)
        writer.writeString("cols")
        writer.writeUInt(30)
        writer.writeString("rows")
        writer.writeUInt(30)
        writer.writeString("latency_ms")
        writer.writeUInt(2)
    }

    private func writeWorkspace(
        id: UInt64,
        title: String,
        spaces: UInt64,
        terminals: UInt64,
        pinned: Bool,
        to writer: inout MessagePackWriter
    ) {
        writer.writeMapHeader(10)
        writer.writeString("id")
        writer.writeUInt(id)
        writer.writeString("external_id")
        writer.writeString(String(format: "c0de0001-c0de-4000-8000-%012llx", CUnsignedLongLong(id)))
        writer.writeString("title")
        writer.writeString(title)
        writer.writeString("description")
        if id == 11 {
            writer.writeString("Main workspace")
        } else {
            writer.writeNil()
        }
        writer.writeString("latest_submitted_message")
        if id == 11 {
            writer.writeString("Build the prompt submit path")
        } else {
            writer.writeNil()
        }
        writer.writeString("space_count")
        writer.writeUInt(spaces)
        writer.writeString("tab_count")
        writer.writeUInt(terminals)
        writer.writeString("terminal_count")
        writer.writeUInt(terminals)
        writer.writeString("pinned")
        writer.writeBool(pinned)
        writer.writeString("color")
        writer.writeNil()
    }

    private func writeSpace(id: UInt64, title: String, to writer: inout MessagePackWriter) {
        writer.writeMapHeader(5)
        writer.writeString("id")
        writer.writeUInt(id)
        writer.writeString("external_id")
        writer.writeString(String(format: "c0de0002-c0de-4000-8000-%012llx", CUnsignedLongLong(id)))
        writer.writeString("title")
        writer.writeString(title)
        writer.writeString("pane_count")
        writer.writeUInt(1)
        writer.writeString("terminal_count")
        writer.writeUInt(2)
    }

    private func writeTab(id: UInt64, title: String, active: Bool, to writer: inout MessagePackWriter) {
        writer.writeMapHeader(4)
        writer.writeString("id")
        writer.writeUInt(id)
        writer.writeString("title")
        writer.writeString(title)
        writer.writeString("has_activity")
        writer.writeBool(active)
        writer.writeString("bell_count")
        writer.writeUInt(active ? 1 : 0)
    }

    private func writeCell(text: String, to writer: inout MessagePackWriter) {
        writer.writeMapHeader(10)
        writer.writeString("text")
        writer.writeString(text)
        writer.writeString("width")
        writer.writeUInt(1)
        writer.writeString("fg")
        writeRGB(1, 2, 3, to: &writer)
        writer.writeString("bg")
        writeRGB(4, 5, 6, to: &writer)
        writer.writeString("bold")
        writer.writeBool(true)
        writer.writeString("italic")
        writer.writeBool(false)
        writer.writeString("underline")
        writer.writeBool(false)
        writer.writeString("faint")
        writer.writeBool(false)
        writer.writeString("blink")
        writer.writeBool(false)
        writer.writeString("strikethrough")
        writer.writeBool(false)
    }

    private func writeRGB(_ r: UInt8, _ g: UInt8, _ b: UInt8, to writer: inout MessagePackWriter) {
        writer.writeMapHeader(3)
        writer.writeString("r")
        writer.writeUInt(UInt64(r))
        writer.writeString("g")
        writer.writeUInt(UInt64(g))
        writer.writeString("b")
        writer.writeUInt(UInt64(b))
    }
}
