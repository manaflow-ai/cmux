import Foundation
import Testing

final class CLIArtifactsCommandBundleMarker: NSObject {}

@Suite(.serialized)
struct CLIArtifactsCommandTests {
    @Test
    func artifactAddResolvesWorkspaceRefToUUIDBeforeV2Request() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: CLIArtifactsCommandBundleMarker.self
        )
        let socketPath = "/tmp/cmux-artifacts-cli-\(UUID().uuidString.prefix(8)).sock"
        let windowID = UUID().uuidString
        let workspaceID = UUID().uuidString
        let artifactID = UUID().uuidString
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [
                #"{"ok":true,"result":{"windows":[{"id":"\#(windowID)","ref":"window:1"}]}}"#,
                #"{"ok":true,"result":{"workspaces":[{"id":"\#(workspaceID)","ref":"workspace:1","index":0}]}}"#,
                #"{"ok":true,"result":{"artifact":{"id":"\#(artifactID)","kind":"url","value":"https://example.com/artifact","workspace_id":"\#(workspaceID)"}}}"#,
            ]
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = try runCLI(
            cliPath: cliPath,
            arguments: [
                "--socket", socketPath,
                "artifacts", "add",
                "--workspace", "workspace:1",
                "--url", "https://example.com/artifact",
                "--json",
            ],
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        let requests = try responder.receivedRequests.map { request in
            try #require(
                JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
            )
        }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "window.list",
            "workspace.list",
            "artifacts.add",
        ])
        let addRequest = try #require(requests.last)
        let params = try #require(addRequest["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == workspaceID)
    }

    private func runCLI(
        cliPath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> CLIProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let timedOut = exited.wait(timeout: .now() + 5) != .success
        if timedOut {
            process.terminate()
            process.waitUntilExit()
        }
        let stdoutText = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let stderrText = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return CLIProcessResult(
            status: process.terminationStatus,
            stdout: stdoutText,
            stderr: stderrText,
            timedOut: timedOut
        )
    }
}

private struct CLIProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var diagnostics: String {
        "status=\(status) timedOut=\(timedOut) stdout=\(stdout) stderr=\(stderr)"
    }
}
