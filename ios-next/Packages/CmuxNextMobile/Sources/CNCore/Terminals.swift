import Foundation

public struct Terminal: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var cwd: String
    public var cols: Int
    public var rows: Int
    public var running: Bool
    public var createdAt: EpochMillis

    public init(id: String, title: String, cwd: String, cols: Int, rows: Int, running: Bool, createdAt: EpochMillis) {
        self.id = id; self.title = title; self.cwd = cwd; self.cols = cols; self.rows = rows; self.running = running; self.createdAt = createdAt
    }
}

public struct TerminalList: Codable, Sendable, Hashable { public var terminals: [Terminal]; public init(terminals: [Terminal]) { self.terminals = terminals } }
public struct TerminalResult: Codable, Sendable, Hashable { public var terminal: Terminal; public init(terminal: Terminal) { self.terminal = terminal } }

public struct TerminalCreateParams: Codable, Sendable, Hashable {
    public var cols: Int; public var rows: Int; public var cwd: String?
    public init(cols: Int, rows: Int, cwd: String? = nil) { self.cols = cols; self.rows = rows; self.cwd = cwd }
}

public struct TerminalAttachParams: Codable, Sendable, Hashable {
    public var terminalId: String; public var cols: Int; public var rows: Int
    public init(terminalId: String, cols: Int, rows: Int) { self.terminalId = terminalId; self.cols = cols; self.rows = rows }
}

public struct TerminalAttachResult: Codable, Sendable, Hashable {
    public var streamId: UInt32; public var terminal: Terminal
    public init(streamId: UInt32, terminal: Terminal) { self.streamId = streamId; self.terminal = terminal }
}

public struct StreamRef: Codable, Sendable, Hashable { public var streamId: UInt32; public init(streamId: UInt32) { self.streamId = streamId } }
public struct TerminalRef: Codable, Sendable, Hashable { public var terminalId: String; public init(terminalId: String) { self.terminalId = terminalId } }

public struct TerminalResizeParams: Codable, Sendable, Hashable {
    public var terminalId: String; public var cols: Int; public var rows: Int
    public init(terminalId: String, cols: Int, rows: Int) { self.terminalId = terminalId; self.cols = cols; self.rows = rows }
}

/// `fs.upload` (PROTOCOL §4 files).
public struct FileUploadParams: Codable, Sendable, Hashable {
    public var name: String; public var mimeType: String?; public var dataBase64: String
    public init(name: String, mimeType: String? = nil, dataBase64: String) { self.name = name; self.mimeType = mimeType; self.dataBase64 = dataBase64 }
}

public struct FileUploadResult: Codable, Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct TerminalRenameParams: Codable, Sendable, Hashable {
    public var terminalId: String; public var title: String
    public init(terminalId: String, title: String) { self.terminalId = terminalId; self.title = title }
}

/// `term.exited` event.
public struct TerminalExitedEvent: Codable, Sendable, Hashable {
    public var terminalId: String; public var code: Int
    public init(terminalId: String, code: Int) { self.terminalId = terminalId; self.code = code }
}
