import Darwin
import Foundation
import Testing

/// Shared socket/process harness for agent-message command behavior.
extension CLIAgentMessageCommandTests {
    // MARK: - Harness

    struct Run {
        let result: CLIHookProcessRunner.Result
        let requests: [[String: Any]]

        func request(_ method: String) -> [String: Any]? {
            requests.last { $0["method"] as? String == method }
        }
    }

    static func sendResult(hasAgent: Bool = true) -> [String: Any] {
        [
            "id": "msg-1",
            "state": "queued",
            "recipient_workspace_title": "cmux-remote-status",
            "recipient_surface_ref": "surface:4",
            "recipient_has_agent": hasAgent,
        ]
    }

    func runCLI(
        arguments: [String],
        kiroProcess: Bool = false,
        standardInput: String? = nil,
        surfaceID: String? = callerSurfaceID,
        extraEnvironment: [String: String] = [:],
        responses: [String: [String: Any]] = [:],
        pollResponsesAfterFirst: [String: Any]? = nil
    ) throws -> Run {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-agent-message-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var canned: [String: [String: Any]] = ["agent.message.send": Self.sendResult()]
        if kiroProcess, let surfaceID {
            canned["agent.resolve_delivery_target"] = ["surface_id": surfaceID.uppercased()]
        }
        canned.merge(responses) { _, new in new }
        let socketPath = makeCodexHookSocketPath("agentmsg")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let recorder = RequestRecorder()
        let server = Self.startMockServer(
            listenerFD: listenerFD,
            recorder: recorder,
            responses: canned,
            laterPoll: pollResponsesAfterFirst
        )
        defer {
            server.stop.set()
            _ = server.done.wait(timeout: .now() + 5)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        var environment = [
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_SOCKET_PASSWORD": "",
            "CMUX_WORKSPACE_ID": Self.callerWorkspaceID,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CFFIXED_USER_HOME": home.path,
            "HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        if let surfaceID {
            environment["CMUX_SURFACE_ID"] = surfaceID
        }
        environment.merge(extraEnvironment) { _, new in new }
        let cli = try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self)
        let executable = kiroProcess ? try makeKiroProcess(at: root) : cli
        let result = CLIHookProcessRunner.run(
            executablePath: executable,
            arguments: kiroProcess ? [cli] + arguments : arguments,
            environment: environment,
            standardInput: standardInput ?? "",
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

    private final class CannedResponses: @unchecked Sendable {
        private let lock = NSLock()
        private let byMethod: [String: [String: Any]]
        /// Answers every `agent.message.poll` after the first, when set.
        private let laterPoll: [String: Any]?
        private var polls = 0

        init(_ byMethod: [String: [String: Any]], laterPoll: [String: Any]?) {
            self.byMethod = byMethod
            self.laterPoll = laterPoll
        }

        func result(for method: String) -> [String: Any] {
            lock.lock()
            defer { lock.unlock() }
            if method == "agent.message.poll" {
                polls += 1
                if polls > 1, let laterPoll { return laterPoll }
            }
            return byMethod[method] ?? [:]
        }
    }

    private static func startMockServer(
        listenerFD: Int32,
        recorder: RequestRecorder,
        responses: [String: [String: Any]],
        laterPoll: [String: Any]?
    ) -> (done: DispatchSemaphore, stop: StopFlag) {
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        let canned = CannedResponses(responses, laterPoll: laterPoll)
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
                serve(clientFD: clientFD, recorder: recorder, canned: canned)
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

    private static func serve(clientFD: Int32, recorder: RequestRecorder, canned: CannedResponses) {
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
                let request = codexHookJSONObject(line)
                let id = (request?["id"] as? String) ?? "unknown"
                let method = request?["method"] as? String ?? ""
                let result = canned.result(for: method)
                let response = codexHookV2Response(id: id, ok: true, result: result)
                guard writeAllToFixtureSocket(response + "\n", fd: clientFD) else { return }
            }
        }
    }
}
