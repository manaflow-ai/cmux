import Darwin
import Foundation
import Testing

/// Exercises the bundled CLI's actual restore/fork exec boundaries. Each
/// invocation uses its own socket and home, and launches a signal probe rather
/// than a real agent, so it cannot read conversations or modify live terminals.
@Suite(.serialized)
struct CLIExecInheritedSignalStateTests {
    @Test(arguments: ["restore", "fork"], [false, true])
    func restoredAgentReceivesResizeSignals(verb: String, legacy: Bool) throws {
        let runner = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try runner.bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-signal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = """
        import json, os, signal
        blocked = sorted(int(s) for s in signal.pthread_sigmask(signal.SIG_BLOCK, []))
        ignored = signal.getsignal(signal.SIGWINCH) == signal.SIG_IGN
        delivered = []
        signal.signal(signal.SIGWINCH, lambda *args: delivered.append(True))
        os.kill(os.getpid(), signal.SIGWINCH)
        print(json.dumps(dict(blocked=blocked, ignored=ignored, delivered=bool(delivered))))
        """
        let probeURL = root.appendingPathComponent("probe.py")
        try probe.write(to: probeURL, atomically: true, encoding: .utf8)
        let arguments = ["/usr/bin/python3", probeURL.path]
        var record: [String: Any] = [
            "mode": legacy || verb == "fork" ? "resumeAgent" : "direct",
            "kind": "custom-agent",
            "checkpoint_id": "signal-fixture",
            "source": "session-snapshot",
            "working_directory": root.path,
            "environment": [:] as [String: String]
        ]
        if legacy {
            let command = "exec /usr/bin/python3 '" + probeURL.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            record[verb == "fork" ? "legacy_fork_command" : "legacy_command"] = command
        } else {
            record["launch_command"] = [
                "arguments": arguments, "executable_path": arguments[0]
            ] as [String: Any]
            record[verb == "fork" ? "fork_arguments" : "prepared_arguments"] = arguments
        }
        let response = try JSONSerialization.data(withJSONObject: [
            "ok": true, "result": ["restore_record": record]
        ])
        let socketPath = "/tmp/cmux-signal-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath, response: String(decoding: response, as: UTF8.self)
        )
        defer { responder.stop() }
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "SHELL": "/bin/sh",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_CLI_SENTRY_DISABLED": "1"
        ]
        let result = runner.runProcess(
            executablePath: cliPath,
            arguments: [verb, "--surface", UUID().uuidString, "custom-agent", "signal-fixture"],
            environment: environment,
            timeout: 10
        )
        try #require(!result.timedOut && result.status == 0, Comment(rawValue: result.diagnostics))
        let state = try JSONDecoder().decode(ChildSignalState.self, from: Data(result.stdout.utf8))
        #expect(state.blocked.isEmpty, "Inherited blocked signals: \(state.blocked)")
        #expect(!state.ignored)
        #expect(state.delivered, "The restored process must receive SIGWINCH")
        #expect(responder.receivedRequests.contains { $0.contains("surface.resume.get") })
    }

    /// The exec wrapper only protects the sites that call it. `cmux restore`
    /// and `cmux fork` exec the resumed agent from their own files, so one
    /// direct `execve` hands the agent the blocked mask again. Every exec under
    /// `CLI/` must run inside `cliExecFailureErrno`.
    @Test func everyCLIExecSiteStartsChildrenFromDefaultSignalState() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cliDirectory = repositoryRoot.appendingPathComponent("CLI", isDirectory: true)
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: cliDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        try #require(!fileNames.isEmpty, "no CLI sources under \(cliDirectory.path)")

        let execCall = try Regex(#"\b(execve|execv|execvp|execvP|execl|execle|execlp)\("#)
        var unguardedExecSites: [String] = []
        for fileName in fileNames {
            let path = cliDirectory.appendingPathComponent(fileName).path
            let lines = try String(contentsOfFile: path, encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains(execCall) {
                    let precedingLines = lines[max(0, index - 12)..<index]
                    if !precedingLines.contains(where: { $0.contains("cliExecFailureErrno") }) {
                        unguardedExecSites.append("\(fileName):\(index + 1)")
                    }
                }
            }
        }
        #expect(
            unguardedExecSites.isEmpty,
            "exec sites outside cliExecFailureErrno hand the child the thread's signal mask: \(unguardedExecSites)"
        )
    }

    /// A `posix_spawn` child inherits the calling thread's mask and the app's
    /// ignored signals. Every app, package and CLI source that spawns must
    /// configure its attributes through `POSIXSpawnSignalPolicy`, whose own
    /// tests (CmuxFoundation) spawn a probe and check the child's state.
    @Test func everyPOSIXSpawnSiteAppliesTheSignalPolicy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var sourcePaths: [String] = []
        for root in ["CLI", "Sources"] {
            sourcePaths += try Self.swiftSources(under: repositoryRoot.appendingPathComponent(root))
        }
        let packagesRoot = repositoryRoot.appendingPathComponent("Packages")
        for group in try FileManager.default.contentsOfDirectory(atPath: packagesRoot.path) {
            let groupURL = packagesRoot.appendingPathComponent(group)
            guard let packages = try? FileManager.default.contentsOfDirectory(atPath: groupURL.path) else {
                continue
            }
            for package in packages {
                let sources = groupURL.appendingPathComponent(package).appendingPathComponent("Sources")
                if FileManager.default.fileExists(atPath: sources.path) {
                    sourcePaths += try Self.swiftSources(under: sources)
                }
            }
        }
        try #require(sourcePaths.count > 100, "found only \(sourcePaths.count) Swift sources")

        let spawnCall = try Regex(#"\bposix_spawnp?\("#)
        var unguardedSpawnSites: [String] = []
        for path in sourcePaths {
            let lines = try String(contentsOfFile: path, encoding: .utf8)
                .components(separatedBy: "\n")
            let appliesPolicy = lines.contains { $0.contains("POSIXSpawnSignalPolicy(") }
            for (index, line) in lines.enumerated() where !appliesPolicy {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains(spawnCall) {
                    let relativePath = String(path.dropFirst(repositoryRoot.path.count + 1))
                    unguardedSpawnSites.append("\(relativePath):\(index + 1)")
                }
            }
        }
        #expect(
            unguardedSpawnSites.isEmpty,
            "posix_spawn sites without POSIXSpawnSignalPolicy hand the child the thread's signal mask: \(unguardedSpawnSites)"
        )
    }

    private static func swiftSources(under root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .map { root.appendingPathComponent($0).path }
    }

    private struct ChildSignalState: Decodable {
        let blocked: [Int32]
        let ignored: Bool
        let delivered: Bool
    }
}
