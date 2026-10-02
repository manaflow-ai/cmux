import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLICompletionCandidateLiveTests {
    @Test("completion offers workspace refs returned by cmux in order")
    func completionOffersLiveWorkspaceRefsInOrder() throws {
        let socketPath = Self.socketPath()
        let listenerFD = try Self.bindSocket(at: socketPath)
        let serverHandled = Self.startMockServer(
            listenerFD: listenerFD,
            response: { request in
                guard let id = request["id"] as? String,
                      request["method"] as? String == "workspace.list" else {
                    return Self.errorResponse(
                        id: request["id"] as? String ?? "unknown",
                        code: "unexpected_request"
                    )
                }
                return Self.successResponse(
                    id: id,
                    result: [
                        "workspaces": [
                            [
                                "id": "6E079F88-C679-4DFE-A92D-B7DD4C31B69E",
                                "ref": "workspace:1",
                                "index": 1,
                                "title": "Editor",
                                "selected": true,
                            ],
                            [
                                "id": "6B135E84-618F-4E1F-9318-3FDCB2C14A66",
                                "ref": "workspace:2",
                                "index": 2,
                                "title": "Server",
                                "selected": false,
                            ],
                        ],
                    ]
                )
            }
        )

        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = try runCLI(
            cliPath,
            arguments: ["__complete-candidates", "workspaces"],
            environment: ["CMUX_SOCKET_PATH": socketPath]
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(result.exitCode == 0, "completion must not make the shell report an error")
        #expect(
            result.stdout.split(separator: "\n").map(String.init) == ["workspace:1", "workspace:2"],
            "completion must offer the refs the app reported, in order"
        )
        #expect(result.stderr.isEmpty, "completion must not write to stderr")
    }

    @Test("completion quietly ignores a v2 error envelope")
    func completionQuietlyIgnoresV2ErrorEnvelope() throws {
        let socketPath = Self.socketPath()
        let listenerFD = try Self.bindSocket(at: socketPath)
        let serverHandled = Self.startMockServer(
            listenerFD: listenerFD,
            response: { request in
                Self.errorResponse(
                    id: request["id"] as? String ?? "unknown",
                    code: "app_unavailable"
                )
            }
        )

        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = try runCLI(
            cliPath,
            arguments: ["__complete-candidates", "workspaces"],
            environment: ["CMUX_SOCKET_PATH": socketPath]
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(result.exitCode == 0, "completion must degrade successfully after an app error")
        #expect(result.stdout.isEmpty, "an app error must yield no candidates")
        #expect(result.stderr.isEmpty, "an app error must not corrupt the prompt")
    }

    @Test("completion falls back to a list entry's id when it carries no ref")
    func completionFallsBackToIdWhenRefIsMissing() throws {
        let socketPath = Self.socketPath()
        let listenerFD = try Self.bindSocket(at: socketPath)
        let serverHandled = Self.startMockServer(
            listenerFD: listenerFD,
            response: { request in
                guard let id = request["id"] as? String,
                      request["method"] as? String == "workspace.list" else {
                    return Self.errorResponse(
                        id: request["id"] as? String ?? "unknown",
                        code: "unexpected_request"
                    )
                }
                return Self.successResponse(
                    id: id,
                    result: [
                        "workspaces": [
                            ["id": "6E079F88-C679-4DFE-A92D-B7DD4C31B69E", "ref": "workspace:1"],
                            // No `ref`: `vm.list` publishes only `id`, and the rest
                            // of the CLI reads these lists with an `id ?? ref`
                            // fallback. Reading `ref` alone dropped the entry and
                            // silently shrank the candidate set.
                            ["id": "6B135E84-618F-4E1F-9318-3FDCB2C14A66"],
                        ],
                    ]
                )
            }
        )

        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = try runCLI(
            cliPath,
            arguments: ["__complete-candidates", "workspaces"],
            environment: ["CMUX_SOCKET_PATH": socketPath]
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(result.exitCode == 0)
        #expect(
            result.stdout.split(separator: "\n").map(String.init) == [
                "workspace:1",
                "6B135E84-618F-4E1F-9318-3FDCB2C14A66",
            ],
            "an entry without a ref must complete as its id, not vanish"
        )
    }

    @Test("completion drops a candidate carrying a control character")
    func completionDropsCandidatesWithControlCharacters() throws {
        let socketPath = Self.socketPath()
        let listenerFD = try Self.bindSocket(at: socketPath)
        let serverHandled = Self.startMockServer(
            listenerFD: listenerFD,
            response: { request in
                guard let id = request["id"] as? String,
                      request["method"] as? String == "workspace.list" else {
                    return Self.errorResponse(
                        id: request["id"] as? String ?? "unknown",
                        code: "unexpected_request"
                    )
                }
                return Self.successResponse(
                    id: id,
                    result: [
                        "workspaces": [
                            ["ref": "workspace:1"],
                            // Candidates are newline-delimited, so an embedded
                            // newline would split one name into two bogus
                            // candidates; an escape sequence would drive the
                            // completing terminal.
                            ["ref": "workspace:2\ninjected"],
                            ["ref": "workspace:3\u{1B}[31m"],
                            ["ref": "workspace:4"],
                        ],
                    ]
                )
            }
        )

        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = try runCLI(
            cliPath,
            arguments: ["__complete-candidates", "workspaces"],
            environment: ["CMUX_SOCKET_PATH": socketPath]
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(result.exitCode == 0)
        #expect(
            result.stdout.split(separator: "\n").map(String.init) == ["workspace:1", "workspace:4"],
            "a name that cannot be represented in the newline-delimited protocol must be dropped, not emitted"
        )
        #expect(!result.stdout.contains("injected"), "a newline must not become a second candidate")
    }

    @Test("completion scopes surface, pane and window candidates to the selectors on the line")
    func completionHonorsExplicitWorkspaceAndWindowSelectors() throws {
        // The app answers for its *selected* workspace (A) when no workspace_id is
        // sent. Typing `--workspace B` must list B's entries, or the suggestion
        // disagrees with the command it completes.
        let cases: [(kind: String, method: String, listKey: String, words: [String], expected: [String])] = [
            ("surfaces", "surface.list", "surfaces",
             ["--workspace", "workspace:2", "--surface", ""], ["surface:B1"]),
            ("surfaces", "surface.list", "surfaces",
             ["--workspace=workspace:2", "--surface", ""], ["surface:B1"]),
            ("surfaces", "surface.list", "surfaces",
             ["--window", "window:2", "--workspace", "workspace:2", "--surface", ""], ["surface:B1"]),
            ("surfaces", "surface.list", "surfaces", ["--surface", ""], ["surface:A1"]),
            ("panes", "pane.list", "panes",
             ["--workspace", "workspace:2", "--pane", ""], ["pane:B1"]),
            ("panes", "pane.list", "panes",
             ["--window=window:2", "--pane", ""], ["pane:W2"]),
            ("panes", "pane.list", "panes", ["--pane", ""], ["pane:A1"]),
        ]

        for entry in cases {
            let socketPath = Self.socketPath()
            let listenerFD = try Self.bindSocket(at: socketPath)
            let serverHandled = Self.startMockServer(
                listenerFD: listenerFD,
                response: { request in
                    let id = request["id"] as? String ?? "unknown"
                    guard request["method"] as? String == entry.method else {
                        return Self.errorResponse(id: id, code: "unexpected_request")
                    }
                    let params = request["params"] as? [String: Any] ?? [:]
                    let ref: String
                    switch (params["workspace_id"] as? String, params["window_id"] as? String) {
                    case ("workspace:2"?, _): ref = entry.kind == "panes" ? "pane:B1" : "surface:B1"
                    case (nil, "window:2"?): ref = "pane:W2"
                    default: ref = entry.kind == "panes" ? "pane:A1" : "surface:A1"
                    }
                    return Self.successResponse(id: id, result: [entry.listKey: [["ref": ref]]])
                }
            )
            defer {
                CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
                shutdown(listenerFD, SHUT_RDWR)
                Darwin.close(listenerFD)
                unlink(socketPath)
            }

            let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
            let result = try runCLI(
                cliPath,
                arguments: ["__complete-candidates", entry.kind] + entry.words,
                environment: ["CMUX_SOCKET_PATH": socketPath]
            )

            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(result.exitCode == 0)
            #expect(
                result.stdout.split(separator: "\n").map(String.init) == entry.expected,
                "\(entry.kind) after \(entry.words) must list the requested scope, not the selected one"
            )
        }
    }

    private static func startMockServer(
        listenerFD: Int32,
        response: @escaping @Sendable ([String: Any]) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        // The registry's poll loop retries EINTR and can be stopped from each
        // test's `defer`; a raw thread parked in `accept` is not woken by
        // closing the listener on Darwin and would outlive a failed test.
        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: listenerFD,
            onConnection: { clientFD in
                defer { handled.signal() }
                defer { Darwin.close(clientFD) }

                cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                    guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                        return Self.errorResponse(id: "unknown", code: "malformed_request")
                    }
                    return response(request)
                }
            },
            onListenerClosed: {}
        )
        return handled
    }

    private static func successResponse(id: String, result: [String: Any]) -> String {
        jsonResponse(["id": id, "ok": true, "result": result])
    }

    private static func errorResponse(id: String, code: String) -> String {
        jsonResponse([
            "id": id,
            "ok": false,
            "error": ["code": code, "message": "completion source unavailable"],
        ])
    }

    private static func jsonResponse(_ payload: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data ?? Data("{}".utf8), as: UTF8.self)
    }

    private static func socketPath() -> String {
        "/tmp/cmux-completion-live-\(UUID().uuidString).sock"
    }

    private static func bindSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                strcpy(UnsafeMutableRawPointer(pathPointer).assumingMemoryBound(to: CChar.self), pointer)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }
        return fd
    }
}
