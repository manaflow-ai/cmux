// The onboarding suite's agent: an ACP agent with no model that uses two apps in the background.
//
// vm.sh compiles it on the Tart host (like an exec probe) and copies only the binary into the guest:
// the pinned images have no Command Line Tools, so no python3. The installed NIGHTLY's acpmux starts
// it as the `onbagent` harness. At `session/prompt` it starts the `cmux-cua` MCP server acpmux gave
// its session, exactly as a model's harness does, and through the cmux Computer Use helper:
//
//   click  Calculator: All Clear, 6, x, 7, =; its display must then read 42
//   type   TextEdit: a new document, then "cmux onboarding 42" typed into it
//   drag   TextEdit: a drag across that line selects it; Cmd-C copies it; the pasteboard must hold it
//
// None of these apps may come to the front: the frontmost app is read after each call
// (`lsappinfo front`) and any change is a focus steal, which fails the run. A model would choose its
// own steps; this agent's are fixed, so a run passes or fails on cmux and the helper, not a model.
// It writes $ONB_OUT/agent-result.json and ends the turn with a one-line summary.
import AppKit
import Foundation

// A write to an MCP server that exited must fail the call, not kill the agent before its result.
signal(SIGPIPE, SIG_IGN)
let out = ProcessInfo.processInfo.environment["ONB_OUT"] ?? FileManager.default.currentDirectoryPath
let typed = "cmux onboarding 42"
let stdoutLock = NSLock()

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    stdoutLock.lock()
    FileHandle.standardOutput.write(data + Data("\n".utf8))
    stdoutLock.unlock()
}

func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func frontApp() -> String {
    let asn = run("/usr/bin/lsappinfo", ["front"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let info = run("/usr/bin/lsappinfo", ["info", "-only", "name", asn])
    if let r = info.range(of: #""LSDisplayName"="([^"]*)""#, options: .regularExpression) {
        return String(info[r]).components(separatedBy: "\"")[3]
    }
    return asn
}

/// One MCP stdio server, started from an ACP mcpServers entry.
final class Mcp {
    let process = Process()
    private let input = Pipe(), output = Pipe()
    private var lines: [[String: Any]] = []
    private let condition = NSCondition()
    private var nextID = 1
    private var closed = false

    init(_ entry: [String: Any]) throws {
        var env = ProcessInfo.processInfo.environment
        for pair in entry["env"] as? [[String: Any]] ?? [] {
            if let name = pair["name"] as? String, let value = pair["value"] as? String { env[name] = value }
        }
        process.executableURL = URL(fileURLWithPath: entry["command"] as? String ?? "")
        process.arguments = entry["args"] as? [String] ?? []
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        let log = out + "/agent-mcp-stderr.log"
        _ = FileManager.default.createFile(atPath: log, contents: nil)
        process.standardError = FileHandle(forWritingAtPath: log) ?? FileHandle.nullDevice
        try process.run()
        Thread.detachNewThread { [self] in
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                condition.lock()
                if chunk.isEmpty { closed = true; condition.broadcast(); condition.unlock(); return }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { lines.append(obj) }
                }
                condition.broadcast()
                condition.unlock()
            }
        }
    }

    func send(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        }
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 60) -> [String: Any] {
        condition.lock()
        let id = nextID
        nextID += 1
        condition.unlock()
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let i = lines.firstIndex(where: { ($0["id"] as? Int) == id }) { return lines.remove(at: i) }
            if closed { return ["error": ["message": "the MCP server exited"]] }
            if !condition.wait(until: deadline) { return ["error": ["message": "no reply to \(method) in \(Int(timeout)) s"]] }
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        process.terminate()
    }
}

/// The tool's JSON payload: structuredContent, else the first text content parsed as JSON.
func payload(_ reply: [String: Any]) -> Any {
    let result = reply["result"] as? [String: Any] ?? [:]
    if let structured = result["structuredContent"], structured is [String: Any] || structured is [Any] { return structured }
    for item in result["content"] as? [[String: Any]] ?? [] where item["type"] as? String == "text" {
        let text = item["text"] as? String ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? ["text": text]
    }
    return [String: Any]()
}

func failed(_ reply: [String: Any]) -> Bool {
    reply["error"] != nil || ((reply["result"] as? [String: Any])?["isError"] as? Bool ?? false)
}

func find(_ node: Any, _ predicate: ([String: Any]) -> Bool) -> [String: Any]? {
    if let dict = node as? [String: Any] {
        if predicate(dict) { return dict }
        for value in dict.values { if let hit = find(value, predicate) { return hit } }
    } else if let list = node as? [Any] {
        for value in list { if let hit = find(value, predicate) { return hit } }
    }
    return nil
}

func text(_ node: [String: Any], _ keys: [String]) -> [String] { keys.map { "\(node[$0] ?? "")" } }
func addressable(_ n: [String: Any]) -> Bool { n["element_token"] != nil || n["element_index"] != nil }
func matches(_ s: String, _ pattern: String) -> Bool {
    s.trimmingCharacters(in: .whitespaces).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

final class Agent {
    let mcp: Mcp
    var tools: [[String: Any]] = []
    var steps: [[String: Any]] = []
    var checks: [String: Any] = [:]
    var steals: [[String: String]] = []
    let front0 = frontApp()

    init(_ mcp: Mcp) { self.mcp = mcp }

    @discardableResult
    func call(_ name: String, _ args: [String: Any], timeout: TimeInterval = 60) -> [String: Any] {
        // Background delivery for every action (ON1 asks for a background app; foreground would be
        // a focus steal). The helper refuses a background drag until its driver supports one (Cua
        // Driver v0.38 adds it): textedit() then fails the drag check and records why.
        var args = args
        if args["delivery_mode"] == nil, props(name).contains("delivery_mode") { args["delivery_mode"] = "background" }
        let started = Date()
        let reply = mcp.request("tools/call", ["name": name, "arguments": args], timeout: timeout)
        // Keep the step, without image data.
        var kept = reply
        if var result = kept["result"] as? [String: Any], let content = result["content"] as? [[String: Any]] {
            result["content"] = content.map { $0["type"] as? String == "image" ? ["type": "image", "data": "<saved>"] : $0 }
            kept["result"] = result
        }
        steps.append(["tool": name, "arguments": args, "seconds": Date().timeIntervalSince(started), "reply": kept])
        let now = frontApp()
        if now != front0 { steals.append(["after": name, "front": now]) }
        return reply
    }

    func props(_ tool: String) -> Set<String> {
        let schema = tools.first { $0["name"] as? String == tool }?["inputSchema"] as? [String: Any]
        return Set((schema?["properties"] as? [String: Any] ?? [:]).keys)
    }

    func element(_ pid: Int, _ win: Int, _ node: [String: Any]) -> [String: Any] {
        if let token = node["element_token"] { return ["pid": pid, "element_token": token] }
        return ["pid": pid, "window_id": win, "element_index": node["element_index"] ?? 0]
    }

    func launch(_ app: String, bundle: String) throws -> (Int, Int) {
        // The argument the helper's schema names: an app name, or a bundle id.
        let have = props("launch_app")
        let key = ["name", "app", "app_name"].first(where: have.contains) ?? (have.contains("bundle_id") ? "bundle_id" : "name")
        let body = payload(call("launch_app", [key: key == "bundle_id" ? bundle : app]))
        let pid = (find(body) { $0["pid"] != nil }?["pid"] as? Int) ?? 0
        var win = find(body) { $0["window_id"] != nil }?["window_id"] as? Int
        if pid != 0, win == nil { win = find(payload(call("list_windows", ["pid": pid]))) { $0["window_id"] != nil }?["window_id"] as? Int }
        guard pid != 0, let window = win else { throw Failure("launch_app \(app): no pid or window") }
        return (pid, window)
    }

    func state(_ pid: Int, _ win: Int) -> Any {
        payload(call("get_window_state", ["pid": pid, "window_id": win, "max_elements": 400]))
    }

    func key(_ pid: Int, _ combo: String) throws {
        // The native profile takes "cmd+c"; the Codex profile's xdotool form is "super+c".
        if failed(call("press_key", ["pid": pid, "key": combo])),
           failed(call("press_key", ["pid": pid, "key": combo.replacingOccurrences(of: "cmd+", with: "super+")])) {
            throw Failure("press_key \(combo) failed")
        }
    }

    func calculator() throws {
        let (pid, win) = try launch("Calculator", bundle: "com.apple.calculator")
        for want in ["^all clear$|^clear$|^ac$", "^6$", "multiply|^×$|^\\*$", "^7$", "equals|^=$"] {
            guard let node = find(state(pid, win), { addressable($0) && text($0, ["label", "title", "description", "identifier"]).contains { matches($0, want) } })
            else { throw Failure("Calculator has no button matching \(want)") }
            if failed(call("click", element(pid, win, node))) { throw Failure("click \(want) failed") }
        }
        checks["click"] = find(state(pid, win)) { matches("\($0["value"] ?? "")", "^42$") } != nil
    }

    func textedit() throws {
        var (pid, win) = try launch("TextEdit", bundle: "com.apple.TextEdit")
        // A new TextEdit can open on its Open panel: Cmd-N gives a document either way.
        try key(pid, "cmd+n")
        Thread.sleep(forTimeInterval: 1)  // the new document's window appears asynchronously
        if let doc = find(payload(call("list_windows", ["pid": pid])), { $0["window_id"] != nil })?["window_id"] as? Int { win = doc }
        let area = find(state(pid, win)) { addressable($0) && matches("\($0["role"] ?? "")", "text ?(area|view)") }
        var args: [String: Any] = ["pid": pid, "text": typed]
        if let area { element(pid, win, area).forEach { if $0.key != "pid" { args[$0.key] = $0.value } } }
        if failed(call("type_text", args)) { throw Failure("type_text failed") }
        let after = state(pid, win)
        checks["type"] = find(after) { "\($0["value"] ?? "")".contains(typed) } != nil
        // Drag across the typed line: the text starts near the document's top-left, below the title
        // bar and ruler (window points). The drag takes screenshot pixels: scale by the helper's
        // screenshot_scale (2 on a Retina guest), else the screenshot's width over the window's.
        let shot = after as? [String: Any]
        let width = shot?["screenshot_width"] as? Double ?? 800
        let points = (shot?["window_bounds"] as? [String: Any])?["width"] as? Double ?? width
        let scale = shot?["screenshot_scale"] as? Double ?? (points > 0 ? width / points : 1)
        let (x0, y0, x1) = (Int(24 * scale), Int(96 * scale), Int(min(points - 24, 420) * scale))
        let have = props("drag")
        var drag: [String: Any] = ["pid": pid, "window_id": win]
        if have.isSuperset(of: ["from_x", "from_y", "to_x", "to_y"]) {
            drag.merge(["from_x": x0, "from_y": y0, "to_x": x1, "to_y": y0]) { $1 }
        } else if have.isSuperset(of: ["start_x", "start_y", "end_x", "end_y"]) {
            drag.merge(["start_x": x0, "start_y": y0, "end_x": x1, "end_y": y0]) { $1 }
        } else {
            drag["path"] = [["x": x0, "y": y0], ["x": x1, "y": y0]]
        }
        let dragged = call("drag", drag)
        if failed(dragged) {
            checks["drag"] = false
            let result = dragged["result"] as? [String: Any]
            let message = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String)
                ?? ((dragged["error"] as? [String: Any])?["message"] as? String) ?? "drag failed"
            checks["drag_error"] = String(message.prefix(300))
            return
        }
        try key(pid, "cmd+c")
        Thread.sleep(forTimeInterval: 0.5)  // the pasteboard write lands after the key event
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        checks["drag"] = pasted.contains(typed)
        checks["pasteboard"] = String(pasted.prefix(200))
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

var serversBySession: [String: [[String: Any]]] = [:]

func act(_ servers: [[String: Any]]) -> [String: Any] {
    guard let entry = servers.first(where: { $0["name"] as? String == "cmux-cua" }) else {
        return ["ok": false, "error": "acpmux gave this session no cmux-cua MCP server"]
    }
    let mcp: Mcp
    do { mcp = try Mcp(entry) } catch { return ["ok": false, "error": "cannot start cmux-cua: \(error)"] }
    defer { mcp.close() }
    let agent = Agent(mcp)
    var report: [String: Any] = [:]
    _ = mcp.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                   "clientInfo": ["name": "onboarding-agent", "version": "1"]])
    mcp.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    agent.tools = (mcp.request("tools/list", [:])["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    report["tools"] = agent.tools.compactMap { $0["name"] }
    report["permissions"] = payload(agent.call("check_permissions", ["prompt": false]))
    var errors: [String: String] = [:]
    for (name, step) in [("calculator", agent.calculator), ("textedit", agent.textedit)] {
        do { try step() } catch { errors[name] = "\(error)" }
    }
    report["errors"] = errors
    report["steps"] = agent.steps
    report["checks"] = agent.checks
    report["front"] = agent.front0
    report["focus_steals"] = agent.steals
    report["ok"] = ["click", "type", "drag"].allSatisfy { agent.checks[$0] as? Bool == true } && agent.steals.isEmpty
    return report
}

func handlePrompt(_ id: Any, _ sid: String) {
    let report = act(serversBySession[sid] ?? [])
    let path = out + "/agent-result.json"
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
        // rename(2): atomic, and works whether or not the file exists yet.
        if (try? data.write(to: URL(fileURLWithPath: path + ".tmp"))) != nil { rename(path + ".tmp", path) }
    }
    let summary = ["ok", "checks", "focus_steals", "errors", "error"].reduce(into: [String: Any]()) { $0[$1] = report[$1] }
    let line = (try? JSONSerialization.data(withJSONObject: summary)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    emit(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": sid, "update": [
        "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "onboarding-agent " + String(line.prefix(2000))]]]])
    emit(["jsonrpc": "2.0", "id": id, "result": ["stopReason": "end_turn"]])
}

var sessions = 0
while let line = readLine() {
    guard let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let method = msg["method"] as? String else { continue }
    let id = msg["id"]
    let params = msg["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        emit(["jsonrpc": "2.0", "id": id ?? 0, "result": ["protocolVersion": 1, "agentInfo": ["name": "onboarding-agent", "version": "1"],
                                                       "agentCapabilities": ["loadSession": false], "authMethods": [Any]()]])
    case "session/new":
        sessions += 1
        let sid = "onboarding-agent-\(getpid())-\(sessions)"
        serversBySession[sid] = params["mcpServers"] as? [[String: Any]] ?? []
        emit(["jsonrpc": "2.0", "id": id ?? 0, "result": ["sessionId": sid]])
    case "session/prompt":
        let sid = params["sessionId"] as? String ?? ""
        Thread.detachNewThread { handlePrompt(id ?? 0, sid) }
    case "session/cancel":
        break
    default:
        if let id { emit(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "no such method \(method)"]]) }
    }
}
