import Darwin
import Foundation
import Testing

/// A CLI that sends a method the connected app does not have must explain the
/// skew (both builds and the fix) instead of a bare `method_not_found`.
@Suite(.serialized)
struct CLIVersionSkewErrorTests {
    @Test("A socket owned by another cmux app names that app and its CLI")
    func otherProductNamesItsCLI() throws {
        let peerCLI = "/Applications/cmux-next.app/Contents/Resources/bin/cmux"
        let outcome = try run(identify: [
            "app": "cmux-next",
            "version": "0.3.0",
            "build": "42",
            "app_cli_path": peerCLI,
            "methods": ["system.identify", "action.run"],
        ])
        let rejected = try #require(outcome.rejected.last, Comment(rawValue: outcome.stderr))
        #expect(outcome.status != 0)
        #expect(outcome.stderr.contains("\(rejected) is not supported by the app on"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains(outcome.cliVersion), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("cmux-next 0.3.0 (42)"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains(peerCLI), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("method_not_found"), Comment(rawValue: outcome.stderr))
    }

    @Test("An older cmux app that does not report a version gets the relaunch fix")
    func olderAppWithoutVersionSaysRelaunch() throws {
        let outcome = try run(identify: [
            "app_bundle_path": "/Applications/cmux.app",
            "app_cli_path": "/Applications/cmux.app/Contents/Resources/bin/cmux",
        ])
        let rejected = try #require(outcome.rejected.last, Comment(rawValue: outcome.stderr))
        #expect(outcome.status != 0)
        #expect(outcome.stderr.contains("\(rejected) is not supported by the app on"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains(outcome.cliVersion), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("does not report its version"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("Quit and reopen cmux"), Comment(rawValue: outcome.stderr))
    }

    @Test("The same build keeps the plain method_not_found error")
    func sameBuildKeepsOriginalError() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self)
        let version = try BundledCLITestSupport.appVersion(cliPath: cliPath)
        let outcome = try run(identify: ["app": "cmux", "version": version, "build": "1"])
        #expect(outcome.status != 0)
        #expect(outcome.stderr.contains("method_not_found"), Comment(rawValue: outcome.stderr))
        #expect(!outcome.stderr.contains("is not supported by the app on"), Comment(rawValue: outcome.stderr))
    }

    @Test("Command help pinned to another build's socket says which commands may not work")
    func helpMarksSkewedApp() throws {
        let peerCLI = "/Applications/cmux-next.app/Contents/Resources/bin/cmux"
        let outcome = try run(
            identify: ["app": "cmux-next", "version": "0.3.0", "build": "42", "app_cli_path": peerCLI],
            arguments: ["workspace", "--help"]
        )
        #expect(outcome.status == 0, Comment(rawValue: outcome.stderr))
        #expect(outcome.stdout.contains("Subcommands:"), Comment(rawValue: outcome.stdout))
        #expect(outcome.stdout.contains("is a different build from this CLI"), Comment(rawValue: outcome.stdout))
        #expect(outcome.stdout.contains("cmux-next 0.3.0 (42)"), Comment(rawValue: outcome.stdout))
        #expect(outcome.stdout.contains(peerCLI), Comment(rawValue: outcome.stdout))
    }

    @Test("Command help for the same build adds no note")
    func helpForSameBuildHasNoNote() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self)
        let version = try BundledCLITestSupport.appVersion(cliPath: cliPath)
        let outcome = try run(identify: ["app": "cmux", "version": version], arguments: ["workspace", "--help"])
        #expect(outcome.status == 0, Comment(rawValue: outcome.stderr))
        #expect(outcome.stdout.contains("Subcommands:"), Comment(rawValue: outcome.stdout))
        #expect(!outcome.stdout.contains("is a different build from this CLI"), Comment(rawValue: outcome.stdout))
    }

    // MARK: - Harness

    private struct Outcome {
        let status: Int32
        let stdout: String
        let stderr: String
        let cliVersion: String
        /// Methods the fixture answered with `method_not_found`, in order.
        let rejected: [String]
    }

    private func run(identify: [String: Any], arguments: [String] = ["workspace", "create"]) throws -> Outcome {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self)
        let version = CLIHookProcessRunner.run(
            executablePath: cliPath,
            arguments: ["--version"],
            environment: [:],
            timeout: 10
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-skew-\(UUID().uuidString.prefix(8)).sock").path
        let fixture = try SkewFixture(socketPath: socketPath, identify: identify)
        let served = fixture.start()

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "2"
        let result = CLIHookProcessRunner.run(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 10
        )
        fixture.stop()
        let rejected = served.wait()
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return Outcome(status: result.status, stdout: result.stdout, stderr: result.stderr, cliVersion: version, rejected: rejected)
    }
}

/// Control-socket fixture: answers `system.identify` with a fixed payload and
/// every other v2 method with the cmux-next style `method_not_found`.
private final class SkewFixture: @unchecked Sendable {
    final class Served: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var rejected: [String] = []

        func record(_ method: String) { lock.withLock { rejected.append(method) } }
        func finish() { done.signal() }
        func wait() -> [String] {
            _ = done.wait(timeout: .now() + 10)
            return lock.withLock { rejected }
        }
    }

    private let socketPath: String
    private let listener: Int32
    private let identify: [String: Any]
    private let stopped = NSLock()
    private var isStopped = false

    init(socketPath: String, identify: [String: Any]) throws {
        self.socketPath = socketPath
        self.identify = identify
        unlink(socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, capacity - 1)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        listener = descriptor
    }

    func stop() {
        stopped.withLock { isStopped = true }
    }

    func start() -> Served {
        let served = Served()
        Thread.detachNewThread { [self] in
            defer {
                close(listener)
                unlink(socketPath)
                served.finish()
            }
            // Serve connections until the CLI exits and the test stops us.
            while !stopped.withLock({ isStopped }) {
                var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 100) > 0 else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                guard ignoreSIGPIPE(onAcceptedFixtureSocket: client) else { close(client); continue }
                serve(client, served)
                close(client)
            }
        }
        return served
    }

    private func serve(_ client: Int32, _ served: Served) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                guard writeAllToFixtureSocket(response(for: line, served) + "\n", fd: client) else { return }
            }
        }
    }

    private func response(for line: String, _ served: Served) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let method = object["method"] as? String else {
            return line.lowercased().hasPrefix("ping") ? "PONG" : "ERROR: Unknown command"
        }
        let id = object["id"] ?? NSNull()
        let payload: [String: Any]
        if method == "system.identify" {
            payload = ["id": id, "ok": true, "result": identify]
        } else {
            served.record(method)
            payload = [
                "id": id,
                "ok": false,
                "error": ["code": "method_not_found", "message": "Unknown method \(method)", "data": ["method": method]],
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
