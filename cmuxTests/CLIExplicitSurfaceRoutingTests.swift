import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLIExplicitSurfaceRoutingTests {
    @Test func explicitSurfaceCommandsDoNotInheritCallerWorkspace() throws {
        try assertExplicitSurfaceCommand(
            arguments: ["read-screen", "--surface", Self.targetSurfaceRef, "--lines", "5"],
            expectedMethod: "surface.read_text"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["read-selection", "--surface", Self.targetSurfaceRef],
            expectedMethod: "surface.read_selection"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["send", "--surface", Self.targetSurfaceRef, "hello"],
            expectedMethod: "surface.send_text",
            expectedText: "hello"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["send-key", "--surface", Self.targetSurfaceRef, "enter"],
            expectedMethod: "surface.send_key",
            expectedKey: "enter"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["send-panel", "--panel", Self.targetSurfaceRef, "hello"],
            expectedMethod: "surface.send_text",
            expectedText: "hello"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["send-key-panel", "--panel", Self.targetSurfaceRef, "enter"],
            expectedMethod: "surface.send_key",
            expectedKey: "enter"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["capture-pane", "--surface", Self.targetSurfaceRef, "--lines", "5"],
            expectedMethod: "surface.read_text"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["pipe-pane", "--surface", Self.targetSurfaceRef, "--command", "cat"],
            expectedMethod: "surface.read_text"
        )
    }

    @Test func numericSurfaceHandleStillInheritsCallerWorkspaceForIndexResolution() throws {
        let socketPath = Self.makeSocketPath("numeric")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "surface.list":
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: ["surfaces": [["id": Self.numericSurfaceId, "ref": "surface:5", "index": 5]]]
                )
            case "surface.read_text":
                return Self.v2Response(id: id, ok: true, result: ["text": "numeric screen\n"])
            default:
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: ["read-screen", "--surface", "5", "--lines", "1"],
            environment: cliEnvironment(socketPath: socketPath),
            timeout: Self.processTimeout
        )

        #expect(handled.wait(timeout: .now() + Self.serverTimeout) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        #expect(result.stdout.contains("numeric screen"), Comment(rawValue: result.stdout))

        let requests = try state.requestObjects()
        #expect(requests.compactMap { $0["method"] as? String } == ["surface.list", "surface.read_text"])

        let listParams = try #require(requests.first?["params"] as? [String: Any])
        #expect(listParams["workspace_id"] as? String == Self.callerWorkspaceId)

        let readParams = try #require(requests.last?["params"] as? [String: Any])
        #expect(readParams["workspace_id"] as? String == Self.callerWorkspaceId)
        #expect(readParams["surface_id"] as? String == Self.numericSurfaceId)
    }

    @Test func readSelectionPlainOutputIncludesSourceContext() throws {
        let (result, requests) = try runSelectionCommand(
            name: "plain",
            arguments: ["read-selection", "--surface", Self.targetSurfaceRef],
            payload: Self.selectedSourcePayload
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        #expect(result.stdout.contains("filepreview"))
        #expect(result.stdout.contains("/tmp/example.swift"))
        #expect(result.stdout.contains("2-3"))
        #expect(result.stdout.contains("selected source"))
        #expect(requests.compactMap { $0["method"] as? String } == ["surface.read_selection"])
    }

    @Test func readSelectionJSONPreservesTheCompleteNoSelectionShape() throws {
        let payload: [String: Any] = [
            "has_selection": false,
            "kind": "browser",
            "text": "",
            "base64": "",
            "url": "https://example.test/document",
            "workspace_id": Self.callerWorkspaceId,
            "workspace_ref": "workspace:1",
            "surface_id": Self.callerSurfaceId,
            "surface_ref": "surface:1",
        ]
        let (result, requests) = try runSelectionCommand(
            name: "json",
            arguments: ["read-selection", "--surface", Self.targetSurfaceRef, "--json"],
            payload: payload
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        let output = try #require(Self.jsonObject(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        #expect(output["has_selection"] as? Bool == false)
        #expect(output["kind"] as? String == "browser")
        #expect(output["text"] as? String == "")
        #expect(output["base64"] as? String == "")
        #expect(output["url"] as? String == "https://example.test/document")
        #expect(output["workspace_id"] as? String == Self.callerWorkspaceId)
        #expect(output["workspace_ref"] as? String == "workspace:1")
        #expect(output["surface_id"] as? String == Self.callerSurfaceId)
        #expect(output["surface_ref"] as? String == "surface:1")
        #expect(requests.compactMap { $0["method"] as? String } == ["surface.read_selection"])
    }

    @Test func plainSelectionReadsSucceedWithAnExplicitNoSelectionMarker() throws {
        let payload: [String: Any] = [
            "has_selection": false,
            "kind": "browser",
            "text": "",
            "base64": "",
            "url": "https://example.test/document",
        ]
        let (result, requests) = try runSelectionCommand(
            name: "plain-empty",
            arguments: ["read-selection", "--surface", Self.targetSurfaceRef],
            payload: payload
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        #expect(result.stdout.contains("Kind: browser"))
        #expect(result.stdout.contains("URL: https://example.test/document"))
        #expect(result.stdout.hasSuffix("Has selection: false\n"))
        #expect(requests.compactMap { $0["method"] as? String } == ["surface.read_selection"])
    }

    @Test func readScreenSelectionAliasIsTextOnlyAndSucceedsWithoutASelection() throws {
        let (selectedResult, selectedRequests) = try runSelectionCommand(
            name: "alias",
            arguments: ["read-screen", "--surface", Self.targetSurfaceRef, "--selection"],
            payload: Self.selectedSourcePayload
        )
        #expect(selectedResult.status == 0, Comment(rawValue: selectedResult.stderr + selectedResult.stdout))
        #expect(selectedResult.stdout == "selected source\n")
        #expect(selectedRequests.compactMap { $0["method"] as? String } == ["surface.read_selection"])

        let (emptyResult, emptyRequests) = try runSelectionCommand(
            name: "empty",
            arguments: ["read-screen", "--surface", Self.targetSurfaceRef, "--selection"],
            payload: [
                "has_selection": false,
                "kind": "terminal",
                "text": "",
                "base64": "",
            ]
        )
        #expect(emptyResult.status == 0, Comment(rawValue: emptyResult.stderr + emptyResult.stdout))
        #expect(emptyResult.stdout == "Has selection: false\n")
        #expect(emptyRequests.compactMap { $0["method"] as? String } == ["surface.read_selection"])
    }

    @Test func globalWindowSelectionReadDoesNotPrefocusTheAppWindow() throws {
        let (result, requests) = try runSelectionCommand(
            name: "window",
            arguments: ["--window", Self.reproWindowId, "read-selection"],
            payload: Self.selectedSourcePayload
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        #expect(requests.compactMap { $0["method"] as? String } == ["surface.read_selection"])
        let params = try #require(requests.first?["params"] as? [String: Any])
        #expect(params["window_id"] as? String == Self.reproWindowId)
        #expect(params["workspace_id"] == nil)
        #expect(params["surface_id"] == nil)
    }

    @Test func refusedTerminalReadsAndWritesExitNonzero() throws {
        let cases: [([String], String)] = [
            (["read-screen", "--surface", Self.targetSurfaceRef], "surface.read_text"),
            (["capture-pane", "--surface", Self.targetSurfaceRef], "surface.read_text"),
            (["send", "--surface", Self.targetSurfaceRef, "hello"], "surface.send_text"),
            (["send-key", "--surface", Self.targetSurfaceRef, "enter"], "surface.send_key"),
        ]

        for (arguments, expectedMethod) in cases {
            try assertRefusedTerminalCommand(arguments: arguments, expectedMethod: expectedMethod)
        }
    }

    private func assertRefusedTerminalCommand(
        arguments: [String],
        expectedMethod: String
    ) throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-refused-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let execution = try runMockCommand(
            arguments: arguments,
            socketName: "refused",
            environmentOverrides: [
                "CFFIXED_USER_HOME": temporaryHome.path,
                "HOME": temporaryHome.path,
            ]
        ) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            return Self.v2Response(
                id: id,
                ok: false,
                error: ["code": "invalid_params", "message": "Surface is not a terminal"]
            )
        }

        let methods = try execution.state.requestObjects().compactMap { $0["method"] as? String }
        #expect(methods == [expectedMethod])
        #expect(!execution.result.timedOut, Comment(rawValue: execution.result.stderr))
        #expect(
            execution.result.status != 0,
            Comment(rawValue: execution.result.stderr + execution.result.stdout)
        )
        #expect(execution.result.stderr.contains("invalid_params: Surface is not a terminal"))
    }

    @Test func closeSurfaceRejectsMissingExplicitRefWithoutMutation() throws {
        let socketPath = Self.makeSocketPath("close")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "surface.list":
                return Self.v2Response(id: id, ok: true, result: ["surfaces": Self.reproSurfaceRows])
            case "surface.close":
                state.recordMutation()
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": Self.reproWorkspaceRef, "surface_id": Self.reproSelectedSurfaceId]
                )
            default:
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: [
                "close-surface",
                "--surface", "surface:99999",
                "--workspace", Self.reproWorkspaceRef,
            ],
            environment: cliEnvironment(socketPath: socketPath),
            timeout: Self.processTimeout
        )

        #expect(handled.wait(timeout: .now() + Self.serverTimeout) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status != 0, Comment(rawValue: result.stderr + result.stdout))
        #expect((result.stderr + result.stdout).contains("Surface ref not found: surface:99999"))
        #expect(state.mutationCountSnapshot() == 0)

        let requests = try state.requestObjects()
        #expect(requests.compactMap { $0["method"] as? String } == ["surface.list"])
        let listParams = try #require(requests.first?["params"] as? [String: Any])
        #expect(listParams["workspace_id"] as? String == Self.reproWorkspaceRef)
    }

    @Test func closeSurfaceRejectsExplicitTargetWithoutWorkspaceOrWindowWithoutMutation() throws {
        let socketPath = Self.makeSocketPath("close-noworkspace")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        var environment = cliEnvironment(socketPath: socketPath)
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")

        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            if method == "surface.close" {
                state.recordMutation()
            }
            return Self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected_method", "message": method]
            )
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: [
                "close-surface",
                "--surface", Self.missingSurfaceUUID,
            ],
            environment: environment,
            timeout: Self.processTimeout
        )

        #expect(handled.wait(timeout: .now() + Self.serverTimeout) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status != 0, Comment(rawValue: result.stderr + result.stdout))
        #expect((result.stderr + result.stdout).contains("close-surface requires --workspace or --window with explicit --surface"))
        #expect(state.mutationCountSnapshot() == 0)
        let requests = try state.requestObjects()
        #expect(requests.isEmpty, Comment(rawValue: String(describing: requests)))
    }

    @Test func closeSurfaceRejectsBlankExplicitTargetWithWindowWithoutMutation() throws {
        let socketPath = Self.makeSocketPath("close-blank")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        var environment = cliEnvironment(socketPath: socketPath)
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")

        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            if method == "surface.close" {
                state.recordMutation()
            }
            return Self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected_method", "message": method]
            )
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: [
                "close-surface",
                "--window", Self.reproWindowId,
                "--surface", "   ",
            ],
            environment: environment,
            timeout: Self.processTimeout
        )

        #expect(handled.wait(timeout: .now() + Self.serverTimeout) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status != 0, Comment(rawValue: result.stderr + result.stdout))
        #expect((result.stderr + result.stdout).contains("Surface handle is blank"))
        #expect(state.mutationCountSnapshot() == 0)
        let requests = try state.requestObjects()
        #expect(requests.isEmpty, Comment(rawValue: String(describing: requests)))
    }

    @Test func respawnPaneRejectsMissingExplicitUUIDWithoutMutation() throws {
        let socketPath = Self.makeSocketPath("respawn")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "window.list":
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: ["windows": [["id": Self.reproWindowId, "ref": "window:1", "index": 0]]]
                )
            case "workspace.list":
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspaces": [["id": Self.reproWorkspaceId, "ref": Self.reproWorkspaceRef, "index": 0]]]
                )
            case "surface.list":
                return Self.v2Response(id: id, ok: true, result: ["surfaces": Self.reproSurfaceRows])
            case "surface.respawn":
                state.recordMutation()
                return Self.v2Response(id: id, ok: true, result: ["surface_id": Self.reproSelectedSurfaceId])
            default:
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: [
                "respawn-pane",
                "--workspace", Self.reproWorkspaceRef,
                "--surface", Self.missingSurfaceUUID,
                "--command", "echo nope",
            ],
            environment: cliEnvironment(socketPath: socketPath),
            timeout: Self.processTimeout
        )

        #expect(handled.wait(timeout: .now() + Self.serverTimeout) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status != 0, Comment(rawValue: result.stderr + result.stdout))
        #expect((result.stderr + result.stdout).contains("Surface not found: \(Self.missingSurfaceUUID)"))
        #expect(state.mutationCountSnapshot() == 0)

        let requests = try state.requestObjects()
        #expect(requests.compactMap { $0["method"] as? String } == ["window.list", "workspace.list", "surface.list"])
        let listParams = try #require(requests.last?["params"] as? [String: Any])
        #expect(listParams["workspace_id"] as? String == Self.reproWorkspaceId)
    }

    private func assertExplicitSurfaceCommand(
        arguments: [String],
        expectedMethod: String,
        expectedText: String? = nil,
        expectedKey: String? = nil
    ) throws {
        let socketPath = Self.makeSocketPath(expectedMethod)
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "surface.read_text":
                return Self.v2Response(id: id, ok: true, result: ["text": "agent screen\n"])
            case "surface.read_selection":
                return Self.v2Response(id: id, ok: true, result: [
                    "has_selection": true,
                    "kind": "filepreview",
                    "text": "selected source",
                    "file_path": "/tmp/example.swift",
                    "line_range": ["start": 2, "end": 3],
                ])
            case "surface.send_text", "surface.send_key":
                return Self.v2Response(id: id, ok: true, result: ["surface_id": Self.targetSurfaceRef])
            default:
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: arguments,
            environment: cliEnvironment(socketPath: socketPath),
            timeout: Self.processTimeout
        )

        #expect(handled.wait(timeout: .now() + Self.serverTimeout) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))

        let requests = try state.requestObjects()
        #expect(requests.compactMap { $0["method"] as? String } == [expectedMethod])
        let request = try #require(requests.first)
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["surface_id"] as? String == Self.targetSurfaceRef)
        #expect(params["workspace_id"] == nil)
        #expect(params["window_id"] == nil)
        if let expectedText {
            #expect(params["text"] as? String == expectedText)
        }
        if let expectedKey {
            #expect(params["key"] as? String == expectedKey)
        }
    }

    private func runMockCommand(
        arguments: [String],
        socketName: String,
        environmentOverrides: [String: String] = [:],
        handler: @escaping @Sendable (String) -> String
    ) throws -> (result: ProcessRunResult, state: ServerState) {
        let socketPath = Self.makeSocketPath(socketName)
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = ServerState()
        let handled = Self.startMockServer(
            listenerFD: listenerFD,
            state: state,
            handler: handler
        )
        var environment = cliEnvironment(socketPath: socketPath)
        environment.merge(environmentOverrides) { _, replacement in replacement }
        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: arguments,
            environment: environment,
            timeout: Self.processTimeout
        )

        #expect(handled.wait(timeout: .now() + Self.serverTimeout) == .success)
        let errors = state.errorsSnapshot()
        #expect(errors.isEmpty, Comment(rawValue: errors.joined(separator: "\n")))
        return (result, state)
    }

    private func runSelectionCommand(
        name: String,
        arguments: [String],
        payload: [String: Any]
    ) throws -> (result: ProcessRunResult, requests: [[String: Any]]) {
        let socketPath = Self.makeSocketPath(name)
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = ServerState()
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadJSON = try #require(String(data: payloadData, encoding: .utf8))
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let request = Self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            guard method == "surface.read_selection" else {
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: Self.jsonObject(payloadJSON)
            )
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: arguments,
            environment: cliEnvironment(socketPath: socketPath),
            timeout: Self.processTimeout
        )

        #expect(handled.wait(timeout: .now() + Self.serverTimeout) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return (result, try state.requestObjects())
    }

    private func cliEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = Self.callerWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.callerSurfaceId
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        return environment
    }

    private static let callerWorkspaceId = "11111111-1111-1111-1111-111111111111"
    // CI runners can cold-start the bundled CLI and its Swift runtime in a few
    // seconds. Keep these waits bounded, but leave enough headroom that a slow
    // runner does not turn an otherwise handled socket response into a timeout.
    private static let processTimeout: TimeInterval = 60
    private static let serverTimeout: TimeInterval = 60
    private static let callerSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let targetSurfaceRef = "surface:11"
    private static let numericSurfaceId = "33333333-3333-3333-3333-333333333333"
    private static let reproWindowId = "44444444-4444-4444-4444-444444443001"
    private static let reproWorkspaceId = "44444444-4444-4444-4444-444444443071"
    private static let reproWorkspaceRef = "workspace:71"
    private static let reproSelectedSurfaceId = "44444444-4444-4444-4444-444444443222"
    private static let reproSecondSurfaceId = "44444444-4444-4444-4444-444444443223"
    private static let reproThirdSurfaceId = "44444444-4444-4444-4444-444444443224"
    private static let missingSurfaceUUID = "99999999-9999-9999-9999-999999999999"
    private static var selectedSourcePayload: [String: Any] {
        [
            "has_selection": true,
            "kind": "filepreview",
            "text": "selected source",
            "base64": "c2VsZWN0ZWQgc291cmNl",
            "file_path": "/tmp/example.swift",
            "line_range": ["start": 2, "end": 3],
            "workspace_id": callerWorkspaceId,
            "workspace_ref": "workspace:1",
            "surface_id": callerSurfaceId,
            "surface_ref": "surface:1",
        ]
    }
    private static var reproSurfaceRows: [[String: Any]] {
        [
            ["id": reproSelectedSurfaceId, "ref": "surface:3222", "index": 0, "focused": true],
            ["id": reproSecondSurfaceId, "ref": "surface:3223", "index": 1, "focused": false],
            ["id": reproThirdSurfaceId, "ref": "surface:3224", "index": 2, "focused": false],
        ]
    }

    private final class CLIExplicitSurfaceRoutingBundleToken {}

    // Records socket callbacks from a background queue; `lock` guards both arrays.
    private final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var requestLines: [String] = []
        private var errors: [String] = []
        private var mutationCount = 0

        func record(_ line: String) {
            lock.lock()
            requestLines.append(line)
            lock.unlock()
        }

        func recordError(_ message: String) {
            lock.lock()
            errors.append(message)
            lock.unlock()
        }

        func errorsSnapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return errors
        }

        func recordMutation() {
            lock.lock()
            mutationCount += 1
            lock.unlock()
        }

        func mutationCountSnapshot() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return mutationCount
        }

        func requestObjects() throws -> [[String: Any]] {
            lock.lock()
            let lines = requestLines
            lock.unlock()
            return try lines.map { line in
                try #require(CLIExplicitSurfaceRoutingTests.jsonObject(line))
            }
        }
    }

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private static func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: CLIExplicitSurfaceRoutingBundleToken.self)
    }

    private static func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG), userInfo: [
                NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)",
            ])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private static func startMockServer(
        listenerFD: Int32,
        state: ServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.signal() }

            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                state.recordError("mock socket server failed to accept a client")
                return
            }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    state.recordError("mock socket server read failed with errno \(errno)")
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    state.record(line)
                    let response = handler(line) + "\n"
                    _ = response.withCString { pointer in
                        Darwin.write(clientFD, pointer, strlen(pointer))
                    }
                }
            }
        }
        return handled
    }

    private static func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private static func malformedRequestResponse(id: String? = nil, raw: String) -> String {
        v2Response(
            id: id ?? "unknown",
            ok: false,
            error: ["code": "malformed_request", "message": "invalid or non-JSON payload", "raw": raw]
        )
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
