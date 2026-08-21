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

    private static func startMockServer(
        listenerFD: Int32,
        response: @escaping ([String: Any]) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        Thread {
            defer { handled.signal() }

            var address = sockaddr_un()
            var addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.accept(listenerFD, socketAddress, &addressLength)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    return Self.errorResponse(id: "unknown", code: "malformed_request")
                }
                return response(request)
            }
        }.start()
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
