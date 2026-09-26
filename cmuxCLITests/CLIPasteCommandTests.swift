import Darwin
import Foundation
import Testing

/// `cmux paste` and `cmux paste-buffer --bracketed` must hand the text to the
/// terminal's paste path (`terminal.paste`) byte for byte, instead of the
/// keystroke path (`surface.send_text`) that turns newlines into Enter.
@Suite(.serialized)
struct CLIPasteCommandTests {
    private static let callerWorkspaceID = "11111111-1111-1111-1111-111111111111"
    private static let callerSurfaceID = "22222222-2222-2222-2222-222222222222"
    private static let targetSurfaceRef = "surface:11"
    private static let timeout: TimeInterval = 60

    @Test func pasteArgumentIsSentVerbatimThroughTerminalPaste() throws {
        let text = "first line\nsecond line with a literal \\n escape\n"
        let run = try runCLI(arguments: ["paste", "--surface", Self.targetSurfaceRef, "--", text])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let request = try #require(run.requests.last)
        #expect(request["method"] as? String == "terminal.paste")
        #expect(run.requests.compactMap { $0["method"] as? String }.contains("surface.send_text") == false)
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["text"] as? String == text)
        #expect(params["submit_key"] as? String == "none")
        #expect(params["surface_id"] as? String == Self.targetSurfaceRef)
    }

    @Test func pasteReadsStandardInputWhenNoTextIsGiven() throws {
        let text = "diff --git a/x b/x\n+added\n\n"
        let run = try runCLI(
            arguments: ["paste", "--surface", Self.targetSurfaceRef],
            standardInput: text
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let request = try #require(run.requests.last)
        #expect(request["method"] as? String == "terminal.paste")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["text"] as? String == text)
    }

    @Test func pasteDashReadsStandardInput() throws {
        let run = try runCLI(
            arguments: ["paste", "--surface", Self.targetSurfaceRef, "-"],
            standardInput: "from stdin"
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(run.requests.last?["params"] as? [String: Any])
        #expect(params["text"] as? String == "from stdin")
    }

    @Test func pasteSubmitAsksForTheAgentAwareSubmitKey() throws {
        let run = try runCLI(arguments: ["paste", "--surface", Self.targetSurfaceRef, "--submit", "hello"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(run.requests.last?["params"] as? [String: Any])
        #expect(params["text"] as? String == "hello")
        #expect(params["submit_key"] as? String == "return")
    }

    @Test func pasteWithoutTextFailsWithoutWriting() throws {
        let run = try runCLI(
            arguments: ["paste", "--surface", Self.targetSurfaceRef],
            standardInput: ""
        )

        #expect(run.result.status != 0)
        #expect(run.requests.compactMap { $0["method"] as? String }.contains("terminal.paste") == false)
    }

    @Test func pasteBufferBracketedUsesThePastePath() throws {
        let buffer = "line one\nline two\n"
        let run = try runCLI(
            arguments: ["paste-buffer", "--name", "notes", "--bracketed", "--surface", Self.targetSurfaceRef],
            buffers: ["notes": buffer]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let request = try #require(run.requests.last)
        #expect(request["method"] as? String == "terminal.paste")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["text"] as? String == buffer)
        #expect(params["submit_key"] as? String == "none")
    }

    @Test func pasteBufferWithoutBracketedKeepsTheKeystrokePath() throws {
        let run = try runCLI(
            arguments: ["paste-buffer", "--name", "notes", "--surface", Self.targetSurfaceRef],
            buffers: ["notes": "echo hi"]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(run.requests.last?["method"] as? String == "surface.send_text")
    }

    // MARK: - Harness

    private struct Run {
        let result: CLIHookProcessRunner.Result
        let requests: [[String: Any]]
    }

    private func runCLI(
        arguments: [String],
        standardInput: String? = nil,
        buffers: [String: String]? = nil
    ) throws -> Run {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-paste-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if let buffers {
            let storeURL = home
                .appendingPathComponent(".cmuxterm", isDirectory: true)
                .appendingPathComponent("tmux-compat-store.json", isDirectory: false)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: ["buffers": buffers], options: [])
            try data.write(to: storeURL, options: .atomic)
        }

        let socketPath = makeCodexHookSocketPath("paste")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let recorder = RequestRecorder()
        let server = Self.startMockServer(listenerFD: listenerFD, recorder: recorder)
        defer {
            server.stop.set()
            _ = server.done.wait(timeout: .now() + 5)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let result = CLIHookProcessRunner.run(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self),
            arguments: arguments,
            environment: [
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SOCKET_PASSWORD": "",
                "CMUX_WORKSPACE_ID": Self.callerWorkspaceID,
                "CMUX_SURFACE_ID": Self.callerSurfaceID,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CFFIXED_USER_HOME": home.path,
                "HOME": home.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ],
            standardInput: standardInput,
            timeout: Self.timeout
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return Run(result: result, requests: recorder.requests())
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func record(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        func requests() -> [[String: Any]] {
            lock.lock()
            let snapshot = lines
            lock.unlock()
            return snapshot.compactMap(codexHookJSONObject)
        }
    }

    /// Accepts clients until `stop` is set and answers every v2 request with
    /// a successful paste/send result. Polls instead of blocking in accept so
    /// the loop exits deterministically when the test finishes.
    private static func startMockServer(
        listenerFD: Int32,
        recorder: RequestRecorder
    ) -> (done: DispatchSemaphore, stop: StopFlag) {
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            while !stop.isSet {
                var pollFD = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pollFD, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard ready > 0 else { continue }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                serve(clientFD: clientFD, recorder: recorder)
            }
        }
        return (done, stop)
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private static func serve(clientFD: Int32, recorder: RequestRecorder) {
        defer { Darwin.close(clientFD) }
        guard ignoreSIGPIPE(onAcceptedFixtureSocket: clientFD) else { return }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newline.lowerBound)
                pending.removeSubrange(0...newline.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                recorder.record(line)
                let id = (codexHookJSONObject(line)?["id"] as? String) ?? "unknown"
                let response = codexHookV2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": callerWorkspaceID,
                        "surface_id": callerSurfaceID,
                        "delivery": "delivered",
                        "submitted": true,
                    ]
                )
                guard writeAllToFixtureSocket(response + "\n", fd: clientFD) else { return }
            }
        }
    }
}
