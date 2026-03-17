import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - MCPFraming Tests

final class MCPFramingTests: XCTestCase {

    func testParseCompleteMessage() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let framed = "Content-Length: \(body.count)\r\n\r\n\(body)"
        let data = framed.data(using: .utf8)!

        let result = MCPFraming.parse(data)
        if case .message(let messageData, let consumed) = result {
            XCTAssertEqual(consumed, framed.count)
            let parsed = String(data: messageData, encoding: .utf8)
            XCTAssertEqual(parsed, body)
        } else {
            XCTFail("Expected .message, got \(result)")
        }
    }

    func testParsePartialHeader() {
        let data = "Content-Len".data(using: .utf8)!
        let result = MCPFraming.parse(data)
        if case .needMore = result {} else {
            XCTFail("Expected .needMore for partial header, got \(result)")
        }
    }

    func testParsePartialBody() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        let framed = "Content-Length: \(body.count)\r\n\r\n\(body.prefix(10))"
        let data = framed.data(using: .utf8)!

        let result = MCPFraming.parse(data)
        if case .needMore = result {} else {
            XCTFail("Expected .needMore for partial body, got \(result)")
        }
    }

    func testParseNotMCP() {
        let data = #"{"id":"test","method":"system.ping"}"#.data(using: .utf8)!
        let result = MCPFraming.parse(data)
        if case .notMCP = result {} else {
            XCTFail("Expected .notMCP for JSON line, got \(result)")
        }
    }

    func testParseEmptyBuffer() {
        let result = MCPFraming.parse(Data())
        if case .needMore = result {} else {
            XCTFail("Expected .needMore for empty buffer, got \(result)")
        }
    }

    func testParseMultipleMessages() {
        let body1 = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let body2 = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        let framed1 = "Content-Length: \(body1.count)\r\n\r\n\(body1)"
        let framed2 = "Content-Length: \(body2.count)\r\n\r\n\(body2)"
        var data = (framed1 + framed2).data(using: .utf8)!

        // Parse first message
        let result1 = MCPFraming.parse(data)
        if case .message(let msg1, let consumed1) = result1 {
            XCTAssertEqual(String(data: msg1, encoding: .utf8)!, body1)
            data = data.subdata(in: consumed1..<data.count)
        } else {
            XCTFail("Expected first message")
            return
        }

        // Parse second message
        let result2 = MCPFraming.parse(data)
        if case .message(let msg2, let consumed2) = result2 {
            XCTAssertEqual(String(data: msg2, encoding: .utf8)!, body2)
            XCTAssertEqual(consumed2, data.count)
        } else {
            XCTFail("Expected second message")
        }
    }

    func testParseZeroLengthBody() {
        let framed = "Content-Length: 0\r\n\r\n"
        let data = framed.data(using: .utf8)!
        let result = MCPFraming.parse(data)
        if case .message(let body, let consumed) = result {
            XCTAssertEqual(body.count, 0)
            XCTAssertEqual(consumed, framed.count)
        } else {
            XCTFail("Expected .message with empty body, got \(result)")
        }
    }

    func testEncodeResponse() {
        let dict: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": ["ok": true]]
        let encoded = MCPFraming.encodeResponse(dict)
        let str = String(data: encoded, encoding: .utf8)!

        XCTAssertTrue(str.hasPrefix("Content-Length: "))
        XCTAssertTrue(str.contains("\r\n\r\n"))

        // Parse it back
        let result = MCPFraming.parse(encoded)
        if case .message(let body, _) = result {
            let parsed = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(parsed["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(parsed["id"] as? Int, 1)
        } else {
            XCTFail("Should be able to parse encoded response")
        }
    }
}

// MARK: - MCPHandler Tests

final class MCPHandlerTests: XCTestCase {
    private var executedMethod: String?
    private var executedParams: [String: Any]?
    private var executorResult: MCPHandler.V2ExecutorResult = .ok(["test": true])

    private lazy var handler: MCPHandler = {
        MCPHandler { [weak self] method, params in
            self?.executedMethod = method
            self?.executedParams = params
            return self?.executorResult ?? .ok([:])
        }
    }()

    override func setUp() {
        super.setUp()
        executedMethod = nil
        executedParams = nil
        executorResult = .ok(["test": true])
        // Initialize the handler so tools/list and tools/call work
        let initReq = mcpRequest(id: 0, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "test", "version": "1.0"]
        ])
        _ = handler.handleRequest(initReq)
    }

    func testInitializeReturnsProtocolVersion() {
        let request = mcpRequest(id: 1, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "test", "version": "1.0"]
        ])
        let response = handler.handleRequest(request)!
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 1)

        let result = response["result"] as! [String: Any]
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")

        let serverInfo = result["serverInfo"] as! [String: Any]
        XCTAssertEqual(serverInfo["name"] as? String, "cmux")

        let capabilities = result["capabilities"] as! [String: Any]
        XCTAssertNotNil(capabilities["tools"])
    }

    func testToolsListReturns20Tools() {
        let request = mcpRequest(id: 2, method: "tools/list", params: [:])
        let response = handler.handleRequest(request)!
        let result = response["result"] as! [String: Any]
        let tools = result["tools"] as! [[String: Any]]

        XCTAssertEqual(tools.count, 20)

        // Verify each tool has required fields
        for tool in tools {
            XCTAssertNotNil(tool["name"] as? String, "Tool missing name")
            XCTAssertNotNil(tool["description"] as? String, "Tool missing description")
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any], "Tool missing inputSchema")
        }

        // Verify specific tools exist
        let toolNames = Set(tools.map { $0["name"] as! String })
        XCTAssertTrue(toolNames.contains("list_surfaces"))
        XCTAssertTrue(toolNames.contains("read_screen"))
        XCTAssertTrue(toolNames.contains("send_input"))
        XCTAssertTrue(toolNames.contains("send_key"))
        XCTAssertTrue(toolNames.contains("new_split"))
        XCTAssertTrue(toolNames.contains("close_surface"))
        XCTAssertTrue(toolNames.contains("set_status"))
        XCTAssertTrue(toolNames.contains("set_progress"))
        XCTAssertTrue(toolNames.contains("rename_tab"))
        XCTAssertTrue(toolNames.contains("list_workspaces"))
        XCTAssertTrue(toolNames.contains("system_identify"))
        XCTAssertTrue(toolNames.contains("browser_snapshot"))
    }

    func testToolsCallRoutesToV2() {
        let request = mcpRequest(id: 3, method: "tools/call", params: [
            "name": "read_screen",
            "arguments": ["surface": "surface:1", "lines": 10]
        ])
        let response = handler.handleRequest(request)!

        // Should have routed to surface.read_text
        XCTAssertEqual(executedMethod, "surface.read_text")
        XCTAssertEqual(executedParams?["surface"] as? String, "surface:1")
        XCTAssertEqual(executedParams?["lines"] as? Int, 10)

        // Response should be valid tools/call response
        let result = response["result"] as! [String: Any]
        let content = result["content"] as! [[String: Any]]
        XCTAssertEqual(content.first?["type"] as? String, "text")
    }

    func testToolsCallUnknownTool() {
        let request = mcpRequest(id: 4, method: "tools/call", params: [
            "name": "nonexistent_tool",
            "arguments": [:]
        ])
        let response = handler.handleRequest(request)!

        XCTAssertNotNil(response["error"])
        let error = response["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testUnknownMethodReturnsError() {
        let request = mcpRequest(id: 5, method: "resources/list", params: [:])
        let response = handler.handleRequest(request)!

        XCTAssertNotNil(response["error"])
        let error = response["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testNotificationReturnsNil() {
        // Notifications have no "id" field
        let json: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let response = handler.handleRequest(data)
        XCTAssertNil(response, "Notifications should return nil (no response)")
    }

    func testToolsCallV2Error() {
        executorResult = .error(code: "not_found", message: "Surface not found")
        let request = mcpRequest(id: 6, method: "tools/call", params: [
            "name": "read_screen",
            "arguments": ["surface": "invalid"]
        ])
        let response = handler.handleRequest(request)!

        let result = response["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = result["content"] as! [[String: Any]]
        let text = content.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Surface not found"))
    }

    func testPingReturnsEmptyResult() {
        let request = mcpRequest(id: 7, method: "ping", params: [:])
        let response = handler.handleRequest(request)!
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 7)
        XCTAssertNotNil(response["result"])
    }

    func testInvalidJSONReturnsParseError() {
        let data = "not json at all".data(using: .utf8)!
        let response = handler.handleRequest(data)!
        let error = response["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? Int, -32700)
    }

    func testToolsListBeforeInitializeReturnsError() {
        // Fresh handler without initialize
        let freshHandler = MCPHandler { _, _ in .ok([:]) }
        let request = mcpRequest(id: 1, method: "tools/list", params: [:])
        let response = freshHandler.handleRequest(request)!
        XCTAssertNotNil(response["error"])
        let error = response["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? Int, -32002)
    }

    // MARK: - Routing Tests for All 20 Tools

    func testListSurfacesRouting() {
        callTool("list_surfaces", arguments: ["workspace": "ws:1"])
        XCTAssertEqual(executedMethod, "surface.list")
        XCTAssertEqual(executedParams?["workspace"] as? String, "ws:1")
    }

    func testSendInputRouting() {
        callTool("send_input", arguments: ["surface": "s:1", "text": "hello", "workspace": "ws:1"])
        XCTAssertEqual(executedMethod, "surface.send_text")
        XCTAssertEqual(executedParams?["surface"] as? String, "s:1")
        XCTAssertEqual(executedParams?["text"] as? String, "hello")
    }

    func testSendKeyRouting() {
        callTool("send_key", arguments: ["surface": "s:1", "key": "return"])
        XCTAssertEqual(executedMethod, "surface.send_key")
        XCTAssertEqual(executedParams?["key"] as? String, "return")
    }

    func testNewSplitRouting() {
        callTool("new_split", arguments: ["direction": "right", "type": "terminal"])
        XCTAssertEqual(executedMethod, "surface.split")
        XCTAssertEqual(executedParams?["direction"] as? String, "right")
        XCTAssertEqual(executedParams?["type"] as? String, "terminal")
    }

    func testCloseSurfaceRouting() {
        callTool("close_surface", arguments: ["surface": "s:1"])
        XCTAssertEqual(executedMethod, "surface.close")
    }

    func testListWorkspacesRouting() {
        callTool("list_workspaces", arguments: [:])
        XCTAssertEqual(executedMethod, "workspace.list")
    }

    func testCreateWorkspaceRouting() {
        callTool("create_workspace", arguments: ["title": "new-ws"])
        XCTAssertEqual(executedMethod, "workspace.create")
        XCTAssertEqual(executedParams?["title"] as? String, "new-ws")
    }

    func testSelectWorkspaceRouting() {
        callTool("select_workspace", arguments: ["workspace": "ws:2"])
        XCTAssertEqual(executedMethod, "workspace.select")
    }

    func testSystemIdentifyRouting() {
        callTool("system_identify", arguments: [:])
        XCTAssertEqual(executedMethod, "system.identify")
    }

    func testSystemTreeRouting() {
        callTool("system_tree", arguments: [:])
        XCTAssertEqual(executedMethod, "system.tree")
    }

    func testBrowserOpenRouting() {
        callTool("browser_open", arguments: ["url": "https://example.com", "direction": "right"])
        XCTAssertEqual(executedMethod, "browser.open_split")
        XCTAssertEqual(executedParams?["url"] as? String, "https://example.com")
    }

    func testBrowserNavigateRouting() {
        callTool("browser_navigate", arguments: ["surface": "s:1", "url": "https://example.com"])
        XCTAssertEqual(executedMethod, "browser.navigate")
    }

    func testBrowserSnapshotRouting() {
        callTool("browser_snapshot", arguments: ["surface": "s:1"])
        XCTAssertEqual(executedMethod, "browser.snapshot")
    }

    // MARK: - Helpers

    private func mcpRequest(id: Int, method: String, params: [String: Any]) -> Data {
        let dict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private func callTool(_ name: String, arguments: [String: Any]) {
        let request = mcpRequest(id: 99, method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])
        _ = handler.handleRequest(request)
    }
}
