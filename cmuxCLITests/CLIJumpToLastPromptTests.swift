import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLIJumpToLastPromptTests {
    @Test(arguments: [false, true], [false, true])
    func reportsWhetherAPromptWasOpened(opened: Bool, json: Bool) async throws {
        let socketPath = Self.makeSocketPath()
        let listener = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listener)
            unlink(socketPath)
        }
        let server = Task.detached { () -> [String] in
            var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&readiness, 1, 30_000) > 0 else { return [] }
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return [] }
            defer { Darwin.close(client) }
            var methods: [String] = []
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                pending.append(buffer, count: count)
                while let newline = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newline.lowerBound)
                    pending.removeSubrange(0...newline.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8),
                          let data = line.data(using: .utf8),
                          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let id = request["id"] as? String,
                          let method = request["method"] as? String else { continue }
                    methods.append(method)
                    let result: [String: Any] = opened
                        ? ["opened": true, "surface_ref": "surface:11", "workspace_ref": "workspace:7"]
                        : ["opened": false]
                    let reply: [String: Any] = ["id": id, "ok": true, "result": result]
                    guard let bytes = try? JSONSerialization.data(withJSONObject: reply) else { continue }
                    var response = bytes
                    response.append(0x0A)
                    response.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        _ = Darwin.write(client, base, raw.count)
                    }
                }
            }
            return methods
        }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        let result = CLIHookProcessRunner.run(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self),
            arguments: (json ? ["--json"] : []) + ["jump-to-last-prompt"],
            environment: environment,
            timeout: 30
        )
        #expect(await server.value == ["surface.jump_to_last_prompt"])
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        if json {
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            #expect(payload["opened"] as? Bool == opened)
            #expect(payload["surface_ref"] as? String == (opened ? "surface:11" : nil))
        } else {
            #expect(result.stdout == (opened ? "OK surface:11 workspace:7\n" : "No prompt target\n"))
        }
    }

    private static func makeSocketPath() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-last-prompt-\(suffix).sock")
            .path
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                let buffer = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, source, capacity - 1)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        return fd
    }
}
