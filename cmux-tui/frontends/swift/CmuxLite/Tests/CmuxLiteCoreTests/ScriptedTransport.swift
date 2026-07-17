@testable import CmuxLiteCore
import Foundation

actor ScriptedTransport: CmuxTransport {
    enum Role: Sendable {
        case control(tree: Data)
        case attachment(surface: UInt64)
    }

    private let role: Role
    private var controlTree: Data?
    private let treeAfterSelectTab: Data?
    private let treeAfterNewTab: Data?
    private let treeAfterSplit: Data?
    private let newTabSurface: UInt64
    private let splitSurface: UInt64
    private let protocolVersion: UInt32
    private var queued: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var summaries: [String] = []
    private var closed = false

    init(
        role: Role,
        treeAfterSelectTab: Data? = nil,
        treeAfterNewTab: Data? = nil,
        newTabSurface: UInt64 = 14,
        treeAfterSplit: Data? = nil,
        splitSurface: UInt64 = 14,
        protocolVersion: UInt32 = 7
    ) {
        self.role = role
        if case let .control(tree) = role {
            controlTree = tree
        }
        self.treeAfterSelectTab = treeAfterSelectTab
        self.treeAfterNewTab = treeAfterNewTab
        self.treeAfterSplit = treeAfterSplit
        self.newTabSurface = newTabSurface
        self.splitSurface = splitSurface
        self.protocolVersion = protocolVersion
    }

    func connect() async throws {
        closed = false
    }

    func send(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let request = object as? [String: Any] else {
            throw CmuxProtocolError.malformedPayload("invalid scripted request")
        }
        if request["auth"] != nil {
            summaries.append("auth")
            return
        }
        guard
              let id = (request["id"] as? NSNumber)?.uint64Value,
              let command = request["cmd"] as? String
        else {
            throw CmuxProtocolError.malformedPayload("invalid scripted request")
        }

        summaries.append(Self.summary(command: command, request: request))
        switch (role, command) {
        case (.control, "identify"):
            enqueue(Self.response(
                id: id,
                data: [
                    "app": "cmux-tui",
                    "version": "test",
                    "protocol": protocolVersion,
                    "session": "phone",
                    "pid": 1,
                ]
            ))
        case (.control, "list-workspaces"):
            guard let controlTree else { return }
            enqueue(Self.response(
                id: id,
                data: try JSONSerialization.jsonObject(with: controlTree)
            ))
        case (.control, "new-workspace"):
            enqueue(Self.response(id: id, data: ["surface": 13]))
        case (.control, "new-screen"):
            enqueue(Self.response(id: id, data: ["surface": 12]))
        case (.control, "select-tab"):
            if let treeAfterSelectTab {
                controlTree = treeAfterSelectTab
            }
            enqueue(Self.response(id: id, data: [:]))
        case (.control, "new-tab"):
            if let treeAfterNewTab {
                controlTree = treeAfterNewTab
            }
            enqueue(Self.response(id: id, data: ["surface": newTabSurface]))
        case (.control, "split"):
            if let treeAfterSplit {
                controlTree = treeAfterSplit
            }
            enqueue(Self.response(id: id, data: ["surface": splitSurface]))
        case (.attachment(let surface), "attach-surface"):
            enqueue(Self.response(id: id, data: [:]))
            enqueue(Self.event([
                "event": "render-state",
                "surface": surface,
                "size": ["cols": 80, "rows": 24],
                "cursor": Self.cursor(),
                "default_fg": "#eeeeee",
                "default_bg": "#111111",
                "scrollback_rows": 0,
                "rows": Self.rows(count: 24),
            ]))
        default:
            enqueue(Self.response(id: id, data: [:]))
        }
    }

    func receive() async throws -> Data {
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() async {
        closed = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }

    func emitResized(surface: UInt64, columns: UInt16, rows: UInt16) {
        enqueue(Self.event([
            "event": "render-delta",
            "surface": surface,
            "cursor": Self.cursor(),
            "full": true,
            "size": ["cols": columns, "rows": rows],
            "rows": Self.rows(count: Int(rows)),
        ]))
    }

    func commandSummaries() -> [String] {
        summaries
    }

    func isClosed() -> Bool {
        closed
    }

    private func enqueue(_ data: Data) {
        if waiters.isEmpty {
            queued.append(data)
        } else {
            waiters.removeFirst().resume(returning: data)
        }
    }

    private static func response(id: UInt64, data: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "data": data])
    }

    private static func event(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    private static func summary(command: String, request: [String: Any]) -> String {
        switch command {
        case "attach-surface":
            return "attach-surface:\((request["surface"] as? NSNumber)?.uint64Value ?? 0):\(request["mode"] as? String ?? "default")"
        case "resize-surface":
            let columns = (request["cols"] as? NSNumber)?.uint16Value ?? 0
            let rows = (request["rows"] as? NSNumber)?.uint16Value ?? 0
            return "resize-surface:\(columns)x\(rows)"
        case "send":
            return "send:\(request["text"] as? String ?? "bytes")"
        case "new-screen":
            let workspace = (request["workspace"] as? NSNumber)?.uint64Value ?? 0
            let columns = (request["cols"] as? NSNumber)?.uint16Value ?? 0
            let rows = (request["rows"] as? NSNumber)?.uint16Value ?? 0
            return "new-screen:\(workspace):\(columns)x\(rows)"
        case "new-workspace":
            let columns = (request["cols"] as? NSNumber)?.uint16Value ?? 0
            let rows = (request["rows"] as? NSNumber)?.uint16Value ?? 0
            return "new-workspace:\(columns)x\(rows)"
        case "select-tab":
            let pane = (request["pane"] as? NSNumber)?.uint64Value ?? 0
            let index = (request["index"] as? NSNumber)?.intValue ?? -1
            return "select-tab:\(pane):\(index)"
        case "new-tab":
            let pane = (request["pane"] as? NSNumber)?.uint64Value ?? 0
            let columns = (request["cols"] as? NSNumber)?.uint16Value ?? 0
            let rows = (request["rows"] as? NSNumber)?.uint16Value ?? 0
            return "new-tab:\(pane):\(columns)x\(rows)"
        case "split":
            let pane = (request["pane"] as? NSNumber)?.uint64Value ?? 0
            let direction = request["dir"] as? String ?? ""
            let columns = (request["cols"] as? NSNumber)?.uint16Value ?? 0
            let rows = (request["rows"] as? NSNumber)?.uint16Value ?? 0
            return "split:\(pane):\(direction):\(columns)x\(rows)"
        default:
            return command
        }
    }

    private static func cursor() -> [String: Any] {
        [
            "x": 0,
            "y": 0,
            "style": "block",
            "blink": false,
            "visible": true,
            "color": NSNull(),
        ]
    }

    private static func rows(count: Int) -> [[String: Any]] {
        (0..<count).map { ["row": $0, "runs": []] }
    }
}
