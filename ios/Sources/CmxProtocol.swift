import Foundation

let cmxProtocolVersion: UInt32 = 3
private let cmxMaxMessagePackCollectionCount = 1_000_000

struct CmxWireViewport: Equatable, Sendable {
    var cols: UInt16
    var rows: UInt16
}

struct CmxWireTerminalViewport: Equatable, Sendable {
    var tabID: UInt64
    var cols: UInt16
    var rows: UInt16
}

struct CmxNativeWorkspaceInfo: Equatable, Sendable {
    var id: UInt64
    var title: String
    var spaceCount: Int
    var tabCount: Int
    var terminalCount: Int
    var pinned: Bool
    var color: String?
}

struct CmxNativeSpaceInfo: Equatable, Sendable {
    var id: UInt64
    var title: String
    var paneCount: Int
    var terminalCount: Int
}

struct CmxNativeTabInfo: Equatable, Sendable {
    var id: UInt64
    var title: String
    var hasActivity: Bool
    var bellCount: UInt64
}

struct CmxNativeTabSelection: Equatable, Sendable {
    var panelID: UInt64
    var index: Int
}

enum CmxNativeSplitDirection: String, Equatable, Sendable {
    case horizontal
    case vertical
}

indirect enum CmxNativePanelNode: Equatable, Sendable {
    case leaf(panelID: UInt64, tabs: [CmxNativeTabInfo], active: Int, activeTabID: UInt64)
    case split(
        direction: CmxNativeSplitDirection,
        ratioPermille: UInt16,
        first: CmxNativePanelNode,
        second: CmxNativePanelNode
    )

    var flattenedTabs: [CmxNativeTabInfo] {
        switch self {
        case .leaf(_, let tabs, _, _):
            tabs
        case .split(_, _, let first, let second):
            first.flattenedTabs + second.flattenedTabs
        }
    }

    func selection(for tabID: UInt64) -> CmxNativeTabSelection? {
        switch self {
        case .leaf(let panelID, let tabs, _, _):
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
            return CmxNativeTabSelection(panelID: panelID, index: index)
        case .split(_, _, let first, let second):
            return first.selection(for: tabID) ?? second.selection(for: tabID)
        }
    }
}

struct CmxNativeSnapshot: Equatable, Sendable {
    var workspaces: [CmxNativeWorkspaceInfo]
    var activeWorkspace: Int
    var activeWorkspaceID: UInt64
    var spaces: [CmxNativeSpaceInfo]
    var activeSpace: Int
    var activeSpaceID: UInt64
    var panels: CmxNativePanelNode
    var focusedPanelID: UInt64
    var focusedTabID: UInt64
    var terminalTheme: CmxNativeTerminalThemeSet? = nil
    var terminalFont: CmxNativeTerminalFont? = nil
    var terminalCursor: CmxNativeTerminalCursor? = nil
}

struct CmxTerminalRGB: Equatable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

enum CmxNativeTerminalCursorStyle: String, Equatable, Sendable {
    case block
    case hollowBlock = "hollow_block"
    case underline
    case bar
}

struct CmxNativeTerminalCursorPosition: Equatable, Sendable {
    var col: UInt16
    var row: UInt16
    var visible: Bool
    var style: CmxNativeTerminalCursorStyle
    var color: CmxTerminalRGB?
}

struct CmxNativeTerminalGridCell: Equatable, Sendable {
    var text: String
    var width: UInt8
    var fg: CmxTerminalRGB
    var bg: CmxTerminalRGB
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var faint: Bool
    var blink: Bool
    var strikethrough: Bool
}

struct CmxNativeTerminalGridSnapshot: Equatable, Sendable {
    var tabID: UInt64
    var cols: UInt16
    var rows: UInt16
    var cells: [CmxNativeTerminalGridCell]
    var cursor: CmxNativeTerminalCursorPosition?
}

enum CmxTerminalColorPreference: Equatable, Sendable {
    case light
    case dark
}

struct CmxNativeTerminalThemeSet: Equatable, Sendable {
    var defaultTheme: CmxNativeTerminalTheme?
    var light: CmxNativeTerminalTheme?
    var dark: CmxNativeTerminalTheme?

    func effectiveTheme(colorPreference: CmxTerminalColorPreference) -> CmxNativeTerminalTheme? {
        switch colorPreference {
        case .light:
            light ?? defaultTheme ?? dark
        case .dark:
            dark ?? defaultTheme ?? light
        }
    }
}

struct CmxNativeTerminalTheme: Equatable, Sendable {
    var palette: [UInt8: String]
    var foreground: String?
    var background: String?
    var cursor: String?
    var cursorAccent: String?
    var selectionBackground: String?
    var selectionForeground: String?
    var black: String?
    var red: String?
    var green: String?
    var yellow: String?
    var blue: String?
    var magenta: String?
    var cyan: String?
    var white: String?
    var brightBlack: String?
    var brightRed: String?
    var brightGreen: String?
    var brightYellow: String?
    var brightBlue: String?
    var brightMagenta: String?
    var brightCyan: String?
    var brightWhite: String?
}

struct CmxNativeTerminalFont: Equatable, Sendable {
    var families: [String]
    var size: Double?
}

struct CmxNativeTerminalCursor: Equatable, Sendable {
    var style: String?
    var blink: Bool?
}

enum CmxClientMessage: Equatable, Sendable {
    case hello(viewport: CmxWireViewport, token: String?)
    case helloNative(viewport: CmxWireViewport, token: String?)
    case input(Data)
    case resize(CmxWireViewport)
    case nativeInput(tabID: UInt64, data: Data)
    case nativeLayout([CmxWireTerminalViewport])
    case command(id: UInt32, CmxClientCommand)
    case detach
    case ping
    case clientLatency(milliseconds: UInt32)
}

enum CmxClientCommand: Equatable, Sendable {
    case selectWorkspace(index: Int)
    case selectSpace(index: Int)
    case selectTabInPanel(panelID: UInt64, index: Int)
}

enum CmxServerMessage: Equatable, Sendable {
    case welcome(serverVersion: String, sessionID: String)
    case ptyBytes(tabID: UInt64, data: Data)
    case hostControl(Data)
    case commandReply(id: UInt32)
    case activeTabChanged(index: Int, tabID: UInt64)
    case activeWorkspaceChanged(index: Int, workspaceID: UInt64, title: String)
    case activeSpaceChanged(index: Int, spaceID: UInt64, title: String)
    case nativeSnapshot(CmxNativeSnapshot)
    case terminalGridSnapshot(CmxNativeTerminalGridSnapshot)
    case bye
    case pong
    case error(String)
    case unsupported(kind: String)
}

enum CmxWireError: Error, Equatable, LocalizedError {
    case invalidMessage(String)
    case unsupportedMessagePack(UInt8)
    case unexpectedEnd
    case invalidUTF8
    case expectedMap
    case expectedString
    case expectedData
    case expectedInteger

    var errorDescription: String? {
        switch self {
        case .invalidMessage(let message):
            message
        case .unsupportedMessagePack(let byte):
            String(format: "Unsupported MessagePack byte 0x%02X.", byte)
        case .unexpectedEnd:
            "Unexpected end of cmx protocol frame."
        case .invalidUTF8:
            "Invalid UTF-8 in cmx protocol frame."
        case .expectedMap:
            "Expected MessagePack map."
        case .expectedString:
            "Expected MessagePack string."
        case .expectedData:
            "Expected MessagePack binary data."
        case .expectedInteger:
            "Expected MessagePack integer."
        }
    }
}

enum CmxWireCodec {
    static func encode(_ message: CmxClientMessage) throws -> Data {
        var writer = MessagePackWriter()
        switch message {
        case .hello(let viewport, let token):
            writer.writeMapHeader(4)
            writer.writeString("kind")
            writer.writeString("hello")
            writer.writeString("version")
            writer.writeUInt(UInt64(cmxProtocolVersion))
            writer.writeString("viewport")
            writeViewport(viewport, to: &writer)
            writer.writeString("token")
            if let token {
                writer.writeString(token)
            } else {
                writer.writeNil()
            }
        case .helloNative(let viewport, let token):
            writer.writeMapHeader(5)
            writer.writeString("kind")
            writer.writeString("hello_native")
            writer.writeString("version")
            writer.writeUInt(UInt64(cmxProtocolVersion))
            writer.writeString("viewport")
            writeViewport(viewport, to: &writer)
            writer.writeString("token")
            if let token {
                writer.writeString(token)
            } else {
                writer.writeNil()
            }
            writer.writeString("terminal_renderer")
            writer.writeString("libghostty")
        case .input(let data):
            writer.writeMapHeader(2)
            writer.writeString("kind")
            writer.writeString("input")
            writer.writeString("data")
            writer.writeBinary(data)
        case .resize(let viewport):
            writer.writeMapHeader(2)
            writer.writeString("kind")
            writer.writeString("resize")
            writer.writeString("viewport")
            writeViewport(viewport, to: &writer)
        case .nativeInput(let tabID, let data):
            writer.writeMapHeader(3)
            writer.writeString("kind")
            writer.writeString("native_input")
            writer.writeString("tab_id")
            writer.writeUInt(tabID)
            writer.writeString("data")
            writer.writeBinary(data)
        case .nativeLayout(let terminals):
            writer.writeMapHeader(2)
            writer.writeString("kind")
            writer.writeString("native_layout")
            writer.writeString("terminals")
            writer.writeArrayHeader(terminals.count)
            for terminal in terminals {
                writer.writeMapHeader(3)
                writer.writeString("tab_id")
                writer.writeUInt(terminal.tabID)
                writer.writeString("cols")
                writer.writeUInt(UInt64(terminal.cols))
                writer.writeString("rows")
                writer.writeUInt(UInt64(terminal.rows))
            }
        case .command(let id, let command):
            writer.writeMapHeader(3)
            writer.writeString("kind")
            writer.writeString("command")
            writer.writeString("id")
            writer.writeUInt(UInt64(id))
            writer.writeString("command")
            writeCommand(command, to: &writer)
        case .detach:
            writer.writeMapHeader(1)
            writer.writeString("kind")
            writer.writeString("detach")
        case .ping:
            writer.writeMapHeader(1)
            writer.writeString("kind")
            writer.writeString("ping")
        case .clientLatency(let milliseconds):
            writer.writeMapHeader(2)
            writer.writeString("kind")
            writer.writeString("client_latency")
            writer.writeString("latency_ms")
            writer.writeUInt(UInt64(milliseconds))
        }
        return writer.data
    }

    static func decodeServerMessage(_ data: Data) throws -> CmxServerMessage {
        var reader = MessagePackReader(data: data)
        let value = try reader.readValue()
        guard reader.isAtEnd else {
            throw CmxWireError.invalidMessage("Trailing bytes after cmx protocol frame.")
        }
        let map = try value.mapValue()
        guard let kind = try map["kind"]?.stringValue() else {
            throw CmxWireError.invalidMessage("Missing server message kind.")
        }
        switch kind {
        case "welcome":
            return .welcome(
                serverVersion: try requiredString(map, "server_version"),
                sessionID: try requiredString(map, "session_id")
            )
        case "pty_bytes":
            return .ptyBytes(
                tabID: try requiredUInt(map, "tab_id"),
                data: try requiredData(map, "data")
            )
        case "host_control":
            return .hostControl(try requiredData(map, "data"))
        case "command_reply":
            return .commandReply(id: UInt32(clamping: try requiredUInt(map, "id")))
        case "active_tab_changed":
            return .activeTabChanged(
                index: try requiredInt(map, "index"),
                tabID: try requiredUInt(map, "tab_id")
            )
        case "active_workspace_changed":
            return .activeWorkspaceChanged(
                index: try requiredInt(map, "index"),
                workspaceID: try requiredUInt(map, "workspace_id"),
                title: try requiredString(map, "title")
            )
        case "active_space_changed":
            return .activeSpaceChanged(
                index: try requiredInt(map, "index"),
                spaceID: try requiredUInt(map, "space_id"),
                title: try requiredString(map, "title")
            )
        case "native_snapshot":
            return .nativeSnapshot(try decodeNativeSnapshot(try requiredMap(map, "snapshot")))
        case "terminal_grid_snapshot":
            return .terminalGridSnapshot(try decodeTerminalGridSnapshot(try requiredMap(map, "snapshot")))
        case "bye":
            return .bye
        case "pong":
            return .pong
        case "error":
            return .error(try requiredString(map, "message"))
        default:
            return .unsupported(kind: kind)
        }
    }

    static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= Int(UInt32.max) else {
            throw CmxWireError.invalidMessage("cmx frame is too large.")
        }
        var framed = Data()
        let len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: len) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    private static func writeViewport(_ viewport: CmxWireViewport, to writer: inout MessagePackWriter) {
        writer.writeMapHeader(2)
        writer.writeString("cols")
        writer.writeUInt(UInt64(viewport.cols))
        writer.writeString("rows")
        writer.writeUInt(UInt64(viewport.rows))
    }

    private static func writeCommand(_ command: CmxClientCommand, to writer: inout MessagePackWriter) {
        switch command {
        case .selectWorkspace(let index):
            writer.writeMapHeader(2)
            writer.writeString("name")
            writer.writeString("select-workspace")
            writer.writeString("index")
            writer.writeUInt(UInt64(index))
        case .selectSpace(let index):
            writer.writeMapHeader(2)
            writer.writeString("name")
            writer.writeString("select-space")
            writer.writeString("index")
            writer.writeUInt(UInt64(index))
        case .selectTabInPanel(let panelID, let index):
            writer.writeMapHeader(3)
            writer.writeString("name")
            writer.writeString("select-tab-in-panel")
            writer.writeString("panel_id")
            writer.writeUInt(panelID)
            writer.writeString("index")
            writer.writeUInt(UInt64(index))
        }
    }

    private static func requiredString(_ map: [String: MessagePackValue], _ key: String) throws -> String {
        guard let value = map[key] else {
            throw CmxWireError.invalidMessage("Missing \(key).")
        }
        return try value.stringValue()
    }

    private static func requiredData(_ map: [String: MessagePackValue], _ key: String) throws -> Data {
        guard let value = map[key] else {
            throw CmxWireError.invalidMessage("Missing \(key).")
        }
        return try value.dataValue()
    }

    private static func requiredUInt(_ map: [String: MessagePackValue], _ key: String) throws -> UInt64 {
        guard let value = map[key] else {
            throw CmxWireError.invalidMessage("Missing \(key).")
        }
        return try value.uintValue()
    }

    private static func requiredInt(_ map: [String: MessagePackValue], _ key: String) throws -> Int {
        try checkedInt(try requiredUInt(map, key), key: key)
    }

    private static func requiredBool(_ map: [String: MessagePackValue], _ key: String) throws -> Bool {
        guard let value = map[key] else {
            throw CmxWireError.invalidMessage("Missing \(key).")
        }
        return try value.boolValue()
    }

    private static func requiredMap(_ map: [String: MessagePackValue], _ key: String) throws -> [String: MessagePackValue] {
        guard let value = map[key] else {
            throw CmxWireError.invalidMessage("Missing \(key).")
        }
        return try value.mapValue()
    }

    private static func requiredArray(_ map: [String: MessagePackValue], _ key: String) throws -> [MessagePackValue] {
        guard let value = map[key] else {
            throw CmxWireError.invalidMessage("Missing \(key).")
        }
        return try value.arrayValue()
    }

    private static func optionalString(_ map: [String: MessagePackValue], _ key: String) throws -> String? {
        guard let value = map[key], value != .nilValue else { return nil }
        return try value.stringValue()
    }

    private static func optionalBool(_ map: [String: MessagePackValue], _ key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = map[key], value != .nilValue else { return defaultValue }
        return try value.boolValue()
    }

    private static func optionalUInt(_ map: [String: MessagePackValue], _ key: String, default defaultValue: UInt64) throws -> UInt64 {
        guard let value = map[key], value != .nilValue else { return defaultValue }
        return try value.uintValue()
    }

    private static func optionalInt(_ map: [String: MessagePackValue], _ key: String, default defaultValue: Int) throws -> Int {
        guard let value = map[key], value != .nilValue else { return defaultValue }
        return try checkedInt(try value.uintValue(), key: key)
    }

    private static func checkedInt(_ value: UInt64, key: String) throws -> Int {
        guard value <= UInt64(Int.max) else {
            throw CmxWireError.invalidMessage("\(key) is out of range.")
        }
        return Int(value)
    }

    private static func optionalMap(_ map: [String: MessagePackValue], _ key: String) throws -> [String: MessagePackValue]? {
        guard let value = map[key], value != .nilValue else { return nil }
        return try value.mapValue()
    }

    private static func decodeNativeSnapshot(_ map: [String: MessagePackValue]) throws -> CmxNativeSnapshot {
        CmxNativeSnapshot(
            workspaces: try requiredArray(map, "workspaces").map { try decodeWorkspaceInfo($0.mapValue()) },
            activeWorkspace: try requiredInt(map, "active_workspace"),
            activeWorkspaceID: try requiredUInt(map, "active_workspace_id"),
            spaces: try requiredArray(map, "spaces").map { try decodeSpaceInfo($0.mapValue()) },
            activeSpace: try requiredInt(map, "active_space"),
            activeSpaceID: try requiredUInt(map, "active_space_id"),
            panels: try decodePanelNode(try requiredMap(map, "panels")),
            focusedPanelID: try requiredUInt(map, "focused_panel_id"),
            focusedTabID: try requiredUInt(map, "focused_tab_id"),
            terminalTheme: try optionalMap(map, "terminal_theme").map(decodeTerminalThemeSet),
            terminalFont: try optionalMap(map, "terminal_font").map(decodeTerminalFont),
            terminalCursor: try optionalMap(map, "terminal_cursor").map(decodeTerminalCursorConfig)
        )
    }

    private static func decodeWorkspaceInfo(_ map: [String: MessagePackValue]) throws -> CmxNativeWorkspaceInfo {
        CmxNativeWorkspaceInfo(
            id: try requiredUInt(map, "id"),
            title: try requiredString(map, "title"),
            spaceCount: try optionalInt(map, "space_count", default: 0),
            tabCount: try optionalInt(map, "tab_count", default: 0),
            terminalCount: try optionalInt(map, "terminal_count", default: 0),
            pinned: try optionalBool(map, "pinned", default: false),
            color: try optionalString(map, "color")
        )
    }

    private static func decodeSpaceInfo(_ map: [String: MessagePackValue]) throws -> CmxNativeSpaceInfo {
        CmxNativeSpaceInfo(
            id: try requiredUInt(map, "id"),
            title: try requiredString(map, "title"),
            paneCount: try optionalInt(map, "pane_count", default: 0),
            terminalCount: try optionalInt(map, "terminal_count", default: 0)
        )
    }

    private static func decodeTabInfo(_ map: [String: MessagePackValue]) throws -> CmxNativeTabInfo {
        CmxNativeTabInfo(
            id: try requiredUInt(map, "id"),
            title: try requiredString(map, "title"),
            hasActivity: try optionalBool(map, "has_activity", default: false),
            bellCount: try optionalUInt(map, "bell_count", default: 0)
        )
    }

    private static func decodePanelNode(_ map: [String: MessagePackValue]) throws -> CmxNativePanelNode {
        let kind = try requiredString(map, "kind")
        switch kind {
        case "leaf":
            return .leaf(
                panelID: try requiredUInt(map, "panel_id"),
                tabs: try requiredArray(map, "tabs").map { try decodeTabInfo($0.mapValue()) },
                active: try requiredInt(map, "active"),
                activeTabID: try requiredUInt(map, "active_tab_id")
            )
        case "split":
            let directionString = try requiredString(map, "direction")
            guard let direction = CmxNativeSplitDirection(rawValue: directionString) else {
                throw CmxWireError.invalidMessage("Unsupported native split direction \(directionString).")
            }
            return .split(
                direction: direction,
                ratioPermille: UInt16(clamping: try requiredUInt(map, "ratio_permille")),
                first: try decodePanelNode(try requiredMap(map, "first")),
                second: try decodePanelNode(try requiredMap(map, "second"))
            )
        default:
            throw CmxWireError.invalidMessage("Unsupported native panel node kind \(kind).")
        }
    }

    private static func decodeTerminalGridSnapshot(_ map: [String: MessagePackValue]) throws -> CmxNativeTerminalGridSnapshot {
        CmxNativeTerminalGridSnapshot(
            tabID: try requiredUInt(map, "tab_id"),
            cols: UInt16(clamping: try requiredUInt(map, "cols")),
            rows: UInt16(clamping: try requiredUInt(map, "rows")),
            cells: try requiredArray(map, "cells").map { try decodeTerminalGridCell($0.mapValue()) },
            cursor: try optionalMap(map, "cursor").map(decodeTerminalCursor)
        )
    }

    private static func decodeTerminalGridCell(_ map: [String: MessagePackValue]) throws -> CmxNativeTerminalGridCell {
        CmxNativeTerminalGridCell(
            text: try requiredString(map, "text"),
            width: UInt8(clamping: try requiredUInt(map, "width")),
            fg: try decodeRGB(try requiredMap(map, "fg")),
            bg: try decodeRGB(try requiredMap(map, "bg")),
            bold: try requiredBool(map, "bold"),
            italic: try requiredBool(map, "italic"),
            underline: try requiredBool(map, "underline"),
            faint: try requiredBool(map, "faint"),
            blink: try requiredBool(map, "blink"),
            strikethrough: try requiredBool(map, "strikethrough")
        )
    }

    private static func decodeTerminalCursor(_ map: [String: MessagePackValue]) throws -> CmxNativeTerminalCursorPosition {
        let styleString = try requiredString(map, "style")
        guard let style = CmxNativeTerminalCursorStyle(rawValue: styleString) else {
            throw CmxWireError.invalidMessage("Unsupported native cursor style \(styleString).")
        }
        return CmxNativeTerminalCursorPosition(
            col: UInt16(clamping: try requiredUInt(map, "col")),
            row: UInt16(clamping: try requiredUInt(map, "row")),
            visible: try requiredBool(map, "visible"),
            style: style,
            color: try optionalMap(map, "color").map(decodeRGB)
        )
    }

    private static func decodeRGB(_ map: [String: MessagePackValue]) throws -> CmxTerminalRGB {
        CmxTerminalRGB(
            r: UInt8(clamping: try requiredUInt(map, "r")),
            g: UInt8(clamping: try requiredUInt(map, "g")),
            b: UInt8(clamping: try requiredUInt(map, "b"))
        )
    }

    private static func decodeTerminalThemeSet(_ map: [String: MessagePackValue]) throws -> CmxNativeTerminalThemeSet {
        CmxNativeTerminalThemeSet(
            defaultTheme: try optionalMap(map, "default").map(decodeTerminalTheme),
            light: try optionalMap(map, "light").map(decodeTerminalTheme),
            dark: try optionalMap(map, "dark").map(decodeTerminalTheme)
        )
    }

    private static func decodeTerminalTheme(_ map: [String: MessagePackValue]) throws -> CmxNativeTerminalTheme {
        CmxNativeTerminalTheme(
            palette: try decodeTerminalPalette(try optionalMap(map, "palette") ?? [:]),
            foreground: try optionalString(map, "foreground"),
            background: try optionalString(map, "background"),
            cursor: try optionalString(map, "cursor"),
            cursorAccent: try optionalString(map, "cursor_accent"),
            selectionBackground: try optionalString(map, "selection_background"),
            selectionForeground: try optionalString(map, "selection_foreground"),
            black: try optionalString(map, "black"),
            red: try optionalString(map, "red"),
            green: try optionalString(map, "green"),
            yellow: try optionalString(map, "yellow"),
            blue: try optionalString(map, "blue"),
            magenta: try optionalString(map, "magenta"),
            cyan: try optionalString(map, "cyan"),
            white: try optionalString(map, "white"),
            brightBlack: try optionalString(map, "bright_black"),
            brightRed: try optionalString(map, "bright_red"),
            brightGreen: try optionalString(map, "bright_green"),
            brightYellow: try optionalString(map, "bright_yellow"),
            brightBlue: try optionalString(map, "bright_blue"),
            brightMagenta: try optionalString(map, "bright_magenta"),
            brightCyan: try optionalString(map, "bright_cyan"),
            brightWhite: try optionalString(map, "bright_white")
        )
    }

    private static func decodeTerminalPalette(_ map: [String: MessagePackValue]) throws -> [UInt8: String] {
        var palette: [UInt8: String] = [:]
        for (key, value) in map {
            guard let index = UInt8(key) else { continue }
            palette[index] = try value.stringValue()
        }
        return palette
    }

    private static func decodeTerminalFont(_ map: [String: MessagePackValue]) throws -> CmxNativeTerminalFont {
        let families = try (map["families"]?.arrayValue() ?? []).map { try $0.stringValue() }
        return CmxNativeTerminalFont(
            families: families,
            size: try optionalDouble(map, "size")
        )
    }

    private static func decodeTerminalCursorConfig(_ map: [String: MessagePackValue]) throws -> CmxNativeTerminalCursor {
        CmxNativeTerminalCursor(
            style: try optionalString(map, "style"),
            blink: try optionalBool(map, "blink")
        )
    }

    private static func optionalDouble(_ map: [String: MessagePackValue], _ key: String) throws -> Double? {
        guard let value = map[key], value != .nilValue else { return nil }
        return try value.doubleValue()
    }

    private static func optionalBool(_ map: [String: MessagePackValue], _ key: String) throws -> Bool? {
        guard let value = map[key], value != .nilValue else { return nil }
        return try value.boolValue()
    }
}

private enum MessagePackValue: Equatable {
    case nilValue
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([String: MessagePackValue])

    func mapValue() throws -> [String: MessagePackValue] {
        guard case .map(let map) = self else { throw CmxWireError.expectedMap }
        return map
    }

    func arrayValue() throws -> [MessagePackValue] {
        guard case .array(let array) = self else {
            throw CmxWireError.invalidMessage("Expected MessagePack array.")
        }
        return array
    }

    func stringValue() throws -> String {
        guard case .string(let string) = self else { throw CmxWireError.expectedString }
        return string
    }

    func boolValue() throws -> Bool {
        guard case .bool(let bool) = self else {
            throw CmxWireError.invalidMessage("Expected MessagePack bool.")
        }
        return bool
    }

    func dataValue() throws -> Data {
        guard case .binary(let data) = self else { throw CmxWireError.expectedData }
        return data
    }

    func uintValue() throws -> UInt64 {
        switch self {
        case .uint(let value):
            return value
        case .int(let value) where value >= 0:
            return UInt64(value)
        default:
            throw CmxWireError.expectedInteger
        }
    }

    func doubleValue() throws -> Double {
        switch self {
        case .float(let value):
            return value
        case .uint(let value):
            return Double(value)
        case .int(let value):
            return Double(value)
        default:
            throw CmxWireError.invalidMessage("Expected MessagePack number.")
        }
    }

    var stringMapKey: String? {
        switch self {
        case .string(let value):
            return value
        case .uint(let value):
            return String(value)
        case .int(let value) where value >= 0:
            return String(value)
        default:
            return nil
        }
    }
}

struct MessagePackWriter {
    private(set) var data = Data()

    mutating func writeNil() {
        data.append(0xC0)
    }

    mutating func writeBool(_ value: Bool) {
        data.append(value ? 0xC3 : 0xC2)
    }

    mutating func writeUInt(_ value: UInt64) {
        switch value {
        case 0...0x7F:
            data.append(UInt8(value))
        case 0x80...0xFF:
            data.append(0xCC)
            data.append(UInt8(value))
        case 0x100...0xFFFF:
            data.append(0xCD)
            appendBigEndian(UInt16(value))
        case 0x1_0000...0xFFFF_FFFF:
            data.append(0xCE)
            appendBigEndian(UInt32(value))
        default:
            data.append(0xCF)
            appendBigEndian(value)
        }
    }

    mutating func writeFloat64(_ value: Double) {
        data.append(0xCB)
        appendBigEndian(value.bitPattern)
    }

    mutating func writeString(_ string: String) {
        let bytes = Array(string.utf8)
        let count = bytes.count
        switch count {
        case 0...31:
            data.append(0xA0 | UInt8(count))
        case 32...0xFF:
            data.append(0xD9)
            data.append(UInt8(count))
        case 0x100...0xFFFF:
            data.append(0xDA)
            appendBigEndian(UInt16(count))
        default:
            data.append(0xDB)
            appendBigEndian(UInt32(count))
        }
        data.append(contentsOf: bytes)
    }

    mutating func writeBinary(_ binary: Data) {
        let count = binary.count
        switch count {
        case 0...0xFF:
            data.append(0xC4)
            data.append(UInt8(count))
        case 0x100...0xFFFF:
            data.append(0xC5)
            appendBigEndian(UInt16(count))
        default:
            data.append(0xC6)
            appendBigEndian(UInt32(count))
        }
        data.append(binary)
    }

    mutating func writeArrayHeader(_ count: Int) {
        switch count {
        case 0...15:
            data.append(0x90 | UInt8(count))
        case 16...0xFFFF:
            data.append(0xDC)
            appendBigEndian(UInt16(count))
        default:
            data.append(0xDD)
            appendBigEndian(UInt32(count))
        }
    }

    mutating func writeMapHeader(_ count: Int) {
        switch count {
        case 0...15:
            data.append(0x80 | UInt8(count))
        case 16...0xFFFF:
            data.append(0xDE)
            appendBigEndian(UInt16(count))
        default:
            data.append(0xDF)
            appendBigEndian(UInt32(count))
        }
    }

    private mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}

private struct MessagePackReader {
    let data: Data
    private var offset = 0

    var isAtEnd: Bool {
        offset == data.count
    }

    init(data: Data) {
        self.data = data
    }

    mutating func readValue() throws -> MessagePackValue {
        let byte = try readByte()
        switch byte {
        case 0x00...0x7F:
            return .uint(UInt64(byte))
        case 0x80...0x8F:
            return try readMap(count: Int(byte & 0x0F))
        case 0x90...0x9F:
            return try readArray(count: Int(byte & 0x0F))
        case 0xA0...0xBF:
            return try readString(count: Int(byte & 0x1F))
        case 0xC0:
            return .nilValue
        case 0xC2:
            return .bool(false)
        case 0xC3:
            return .bool(true)
        case 0xC4:
            return try readBinary(count: Int(readByte()))
        case 0xC5:
            return try readBinary(count: Int(readUInt16()))
        case 0xC6:
            return try readBinary(count: Int(readUInt32()))
        case 0xCA:
            return .float(Double(Float32(bitPattern: try readUInt32())))
        case 0xCB:
            return .float(Double(bitPattern: try readUInt64()))
        case 0xCC:
            return .uint(UInt64(try readByte()))
        case 0xCD:
            return .uint(UInt64(try readUInt16()))
        case 0xCE:
            return .uint(UInt64(try readUInt32()))
        case 0xCF:
            return .uint(try readUInt64())
        case 0xD0:
            return .int(Int64(Int8(bitPattern: try readByte())))
        case 0xD1:
            return .int(Int64(Int16(bitPattern: try readUInt16())))
        case 0xD2:
            return .int(Int64(Int32(bitPattern: try readUInt32())))
        case 0xD3:
            return .int(Int64(bitPattern: try readUInt64()))
        case 0xD9:
            return try readString(count: Int(readByte()))
        case 0xDA:
            return try readString(count: Int(readUInt16()))
        case 0xDB:
            return try readString(count: Int(readUInt32()))
        case 0xDC:
            return try readArray(count: Int(readUInt16()))
        case 0xDD:
            return try readArray(count: Int(readUInt32()))
        case 0xDE:
            return try readMap(count: Int(readUInt16()))
        case 0xDF:
            return try readMap(count: Int(readUInt32()))
        case 0xE0...0xFF:
            return .int(Int64(Int8(bitPattern: byte)))
        default:
            throw CmxWireError.unsupportedMessagePack(byte)
        }
    }

    private mutating func readMap(count: Int) throws -> MessagePackValue {
        guard count <= cmxMaxMessagePackCollectionCount else {
            throw CmxWireError.invalidMessage("MessagePack map is too large.")
        }
        var map: [String: MessagePackValue] = [:]
        map.reserveCapacity(count)
        for _ in 0..<count {
            let key = try readValue()
            let value = try readValue()
            if let stringKey = key.stringMapKey {
                map[stringKey] = value
            }
        }
        return .map(map)
    }

    private mutating func readArray(count: Int) throws -> MessagePackValue {
        guard count <= cmxMaxMessagePackCollectionCount else {
            throw CmxWireError.invalidMessage("MessagePack array is too large.")
        }
        var values: [MessagePackValue] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try readValue())
        }
        return .array(values)
    }

    private mutating func readString(count: Int) throws -> MessagePackValue {
        let bytes = try readBytes(count)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw CmxWireError.invalidUTF8
        }
        return .string(string)
    }

    private mutating func readBinary(count: Int) throws -> MessagePackValue {
        .binary(try readBytes(count))
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw CmxWireError.unexpectedEnd }
        defer { offset += 1 }
        return data[offset]
    }

    private mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw CmxWireError.unexpectedEnd
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    private mutating func readUInt16() throws -> UInt16 {
        try readFixedWidthInteger()
    }

    private mutating func readUInt32() throws -> UInt32 {
        try readFixedWidthInteger()
    }

    private mutating func readUInt64() throws -> UInt64 {
        try readFixedWidthInteger()
    }

    private mutating func readFixedWidthInteger<T: FixedWidthInteger>() throws -> T {
        let bytes = try readBytes(MemoryLayout<T>.size)
        return bytes.reduce(T.zero) { partial, byte in
            (partial << 8) | T(byte)
        }
    }
}

extension CmxNativeSnapshot {
    func ghosttyConfigFragment(colorPreference: CmxTerminalColorPreference) -> String? {
        var lines: [String] = []
        if let theme = terminalTheme?.effectiveTheme(colorPreference: colorPreference) {
            lines.append(contentsOf: theme.ghosttyConfigLines())
        }
        if let terminalFont {
            lines.append(contentsOf: terminalFont.ghosttyConfigLines())
        }
        if let terminalCursor {
            lines.append(contentsOf: terminalCursor.ghosttyConfigLines())
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension CmxNativeTerminalTheme {
    func ghosttyConfigLines() -> [String] {
        var lines: [String] = []
        appendColor("foreground", foreground, to: &lines)
        appendColor("background", background, to: &lines)
        appendColor("cursor-color", cursor, to: &lines)
        appendColor("cursor-text", cursorAccent, to: &lines)
        appendColor("selection-background", selectionBackground, to: &lines)
        appendColor("selection-foreground", selectionForeground, to: &lines)

        var resolvedPalette = palette
        for (index, value) in namedPaletteEntries {
            if let value {
                resolvedPalette[index] = value
            }
        }
        for index in resolvedPalette.keys.sorted() {
            guard let color = Self.sanitizedColor(resolvedPalette[index]) else { continue }
            lines.append("palette = \(index)=\(color)")
        }
        return lines
    }

    private var namedPaletteEntries: [(UInt8, String?)] {
        [
            (0, black),
            (1, red),
            (2, green),
            (3, yellow),
            (4, blue),
            (5, magenta),
            (6, cyan),
            (7, white),
            (8, brightBlack),
            (9, brightRed),
            (10, brightGreen),
            (11, brightYellow),
            (12, brightBlue),
            (13, brightMagenta),
            (14, brightCyan),
            (15, brightWhite),
        ]
    }

    private func appendColor(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let color = Self.sanitizedColor(value) else { return }
        lines.append("\(key) = \(color)")
    }

    private static func sanitizedColor(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 3 || hex.count == 6 else { return nil }
        let hexScalars = Set("0123456789abcdefABCDEF".unicodeScalars)
        guard hex.unicodeScalars.allSatisfy({ hexScalars.contains($0) }) else { return nil }
        return "#\(hex)"
    }
}

extension CmxNativeTerminalFont {
    func ghosttyConfigLines() -> [String] {
        var lines: [String] = []
        for family in families {
            let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains(where: { $0.isNewline }) else { continue }
            lines.append("font-family = \"\(trimmed.ghosttyEscapedString)\"")
        }
        if let size,
           size.isFinite,
           size > 0 {
            lines.append(String(format: "font-size = %.3f", size))
        }
        return lines
    }
}

extension CmxNativeTerminalCursor {
    func ghosttyConfigLines() -> [String] {
        var lines: [String] = []
        if let style,
           ["block", "bar", "underline", "block_hollow"].contains(style) {
            lines.append("cursor-style = \(style)")
        }
        if let blink {
            lines.append("cursor-style-blink = \(blink ? "true" : "false")")
        }
        return lines
    }
}

private extension String {
    var ghosttyEscapedString: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
