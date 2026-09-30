import Darwin
import Foundation
import Testing

/// `cmux send`, `send-panel`, `paste` and `send-key` must not type into an
/// agent prompt that holds a human's half-typed draft, or into an open
/// question or permission dialog. The CLI asks `surface.input_state` first
/// and refuses unless `--force` is given.
@Suite(.serialized)
struct CLISendDraftGuardTests {
    private static let callerWorkspaceID = "11111111-1111-1111-1111-111111111111"
    private static let callerSurfaceID = "22222222-2222-2222-2222-222222222222"
    private static let targetSurfaceRef = "surface:11"
    private static let timeout: TimeInterval = 60

    private static let draft: [String: Any] = [
        "state": "draft", "draft_length": 10, "agent": true, "terminal": true,
        "lifecycle": "idle", "waiting_on_human": false, "blocks_typing": true,
    ]
    private static let dialog: [String: Any] = [
        "state": "dialog", "agent": true, "terminal": true,
        "lifecycle": "needsInput", "waiting_on_human": true, "blocks_typing": true,
    ]
    private static let empty: [String: Any] = [
        "state": "empty", "agent": true, "terminal": true,
        "lifecycle": "idle", "waiting_on_human": false, "blocks_typing": false,
    ]

    /// The lifecycle says the agent waits on a human, but nothing is open on
    /// screen: after an interrupt or an API error, typing is how to recover.
    private static let staleWaiting: [String: Any] = [
        "state": "empty", "agent": true, "terminal": true,
        "lifecycle": "needsInput", "waiting_on_human": true, "blocks_typing": false,
    ]

    private static let writeMethods: Set<String> = ["surface.send_text", "terminal.paste", "surface.send_key"]

    private func writes(_ run: Run) -> [String] {
        run.requests.compactMap { $0["method"] as? String }.filter { Self.writeMethods.contains($0) }
    }

    @Test func sendRefusesToTypeOverADraft() throws {
        let run = try runCLI(arguments: ["send", "--surface", Self.targetSurfaceRef, "hello"], inputState: Self.draft)

        #expect(run.result.status != 0)
        #expect(writes(run).isEmpty, Comment(rawValue: "\(writes(run))"))
        #expect(run.result.stderr.contains("--force"), Comment(rawValue: run.result.stderr))
        let probe = try #require(run.requests.first { $0["method"] as? String == "surface.input_state" })
        let params = try #require(probe["params"] as? [String: Any])
        #expect(params["surface_id"] as? String == Self.targetSurfaceRef)
    }

    @Test func textCommandsRefuseDraftsAndDialogs() throws {
        for state in [Self.draft, Self.dialog] {
            for arguments in [
                ["send", "--surface", Self.targetSurfaceRef, "hello"],
                ["send", "--paste", "--surface", Self.targetSurfaceRef, "hello"],
                ["send-panel", "--panel", Self.targetSurfaceRef, "hello"],
                ["paste", "--surface", Self.targetSurfaceRef, "hello"],
            ] {
                let run = try runCLI(arguments: arguments, inputState: state)
                let label = "\(arguments.joined(separator: " ")) / \(state["state"] ?? "")"
                #expect(run.result.status != 0, Comment(rawValue: label))
                #expect(writes(run).isEmpty, Comment(rawValue: label))
            }
        }
    }

    @Test func forceSkipsTheCheck() throws {
        for arguments in [
            ["send", "--force", "--surface", Self.targetSurfaceRef, "hello"],
            ["send", "--surface", Self.targetSurfaceRef, "--force", "--", "hello"],
            ["paste", "--force", "--surface", Self.targetSurfaceRef, "hello"],
            ["send-key", "--force", "--surface", Self.targetSurfaceRef, "enter"],
        ] {
            let run = try runCLI(arguments: arguments, inputState: Self.dialog)
            let label = arguments.joined(separator: " ")
            #expect(run.result.status == 0, Comment(rawValue: label + ": " + run.result.stderr))
            #expect(writes(run).count == 1, Comment(rawValue: label))
            #expect(run.requests.contains { $0["method"] as? String == "surface.input_state" } == false)
        }
        let typed = try runCLI(arguments: ["send", "--force", "--surface", Self.targetSurfaceRef, "hello"], inputState: Self.draft)
        let params = try #require(typed.requests.last?["params"] as? [String: Any])
        #expect(params["text"] as? String == "hello")
    }

    @Test func forceAfterTheTextIsTypedAsText() throws {
        let run = try runCLI(arguments: ["send", "--surface", Self.targetSurfaceRef, "echo", "--force"], inputState: Self.empty)

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let params = try #require(run.requests.last?["params"] as? [String: Any])
        #expect(params["text"] as? String == "echo --force")
    }

    @Test func sendTypesIntoAnEmptyPrompt() throws {
        let run = try runCLI(arguments: ["send", "--surface", Self.targetSurfaceRef, "hello"], inputState: Self.empty)

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(writes(run) == ["surface.send_text"])
    }

    /// `cmux send "text"` followed by `cmux send-key enter` is the usual way to
    /// submit, so a draft must not block keys; an open dialog does.
    @Test func sendKeyIsBlockedByDialogsButNotDrafts() throws {
        let afterSend = try runCLI(arguments: ["send-key", "--surface", Self.targetSurfaceRef, "enter"], inputState: Self.draft)
        #expect(afterSend.result.status == 0, Comment(rawValue: afterSend.result.stderr))
        #expect(writes(afterSend) == ["surface.send_key"])

        for arguments in [
            ["send-key", "--surface", Self.targetSurfaceRef, "enter"],
            ["send-key-panel", "--panel", Self.targetSurfaceRef, "enter"],
        ] {
            let run = try runCLI(arguments: arguments, inputState: Self.dialog)
            #expect(run.result.status != 0, Comment(rawValue: arguments.joined(separator: " ")))
            #expect(writes(run).isEmpty)
        }
    }

    @Test func staleWaitingStateDoesNotBlock() throws {
        for arguments in [
            ["send", "--surface", Self.targetSurfaceRef, "continue"],
            ["send-key", "--surface", Self.targetSurfaceRef, "enter"],
        ] {
            let run = try runCLI(arguments: arguments, inputState: Self.staleWaiting)
            #expect(run.result.status == 0, Comment(rawValue: arguments.joined(separator: " ") + ": " + run.result.stderr))
            #expect(writes(run).count == 1)
        }
    }

    /// `cmux send "text"` then `cmux send "\n"` submits like send-key enter.
    @Test func sendingOnlyEnterIsCheckedAsAKey() throws {
        for text in ["\\n", "\\r"] {
            let run = try runCLI(arguments: ["send", "--surface", Self.targetSurfaceRef, text], inputState: Self.draft)
            #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
            #expect(writes(run) == ["surface.send_text"])
        }
        let intoDialog = try runCLI(arguments: ["send", "--surface", Self.targetSurfaceRef, "\\n"], inputState: Self.dialog)
        #expect(intoDialog.result.status != 0)
        #expect(writes(intoDialog).isEmpty)
    }

    /// An app without `surface.input_state` (older build, or a relay that
    /// denies it) keeps the previous behavior.
    @Test func sendProceedsWhenTheAppCannotReportInputState() throws {
        let run = try runCLI(arguments: ["send", "--surface", Self.targetSurfaceRef, "hello"], inputState: nil)

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(writes(run) == ["surface.send_text"])
    }

    @Test func sendSubmitPastesThenSendsASeparateSubmitKey() throws {
        let run = try runCLI(
            arguments: ["send", "--submit", "--surface", Self.targetSurfaceRef, "hello"],
            inputStates: [Self.empty, Self.empty]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.result.stdout.contains("submitted"), Comment(rawValue: run.result.stdout))
        let methods = run.requests.compactMap { $0["method"] as? String }
        #expect(methods.contains("terminal.paste"))
        #expect(methods.contains("surface.send_key"))
        let pasteIndex = try #require(methods.firstIndex(of: "terminal.paste"))
        let keyIndex = try #require(methods.firstIndex(of: "surface.send_key"))
        #expect(pasteIndex < keyIndex)
        let paste = try #require(run.requests[pasteIndex]["params"] as? [String: Any])
        #expect(paste["submit_key"] as? String == "none")
        let key = try #require(run.requests[keyIndex]["params"] as? [String: Any])
        #expect(key["key"] as? String == "return")
    }

    @Test func sendSubmitQueuesBusyCodexWithTab() throws {
        let busyCodex: [String: Any] = [
            "state": "empty", "agent": true, "terminal": true,
            "lifecycle": "running", "waiting_on_human": false, "blocks_typing": false,
        ]
        let run = try runCLI(
            arguments: ["send", "--submit", "--surface", Self.targetSurfaceRef, "hello"],
            inputStates: [busyCodex, Self.empty],
            screenText: "› hello\nWorking…"
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.result.stdout.contains("queued"), Comment(rawValue: run.result.stdout))
        let keyRequest = try #require(run.requests.first { $0["method"] as? String == "surface.send_key" })
        let params = try #require(keyRequest["params"] as? [String: Any])
        #expect(params["key"] as? String == "tab")
    }

    @Test func sendSubmitRetriesSlashPopupWithAnExtraSubmit() throws {
        let run = try runCLI(
            arguments: ["send", "--submit", "--surface", Self.targetSurfaceRef, "/goal resume"],
            inputStates: [Self.empty, Self.draft, Self.empty],
            screenText: "❯ /goal resume\n/goal  resume"
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let keys = run.requests.compactMap { request -> String? in
            guard request["method"] as? String == "surface.send_key",
                  let params = request["params"] as? [String: Any] else { return nil }
            return params["key"] as? String
        }
        #expect(keys == ["return", "return"])
    }

    @Test func sendSubmitFailsAfterBoundedRetriesWhenComposerNeverClears() throws {
        let run = try runCLI(
            arguments: ["send", "--submit", "--surface", Self.targetSurfaceRef, "hello"],
            inputStates: [Self.empty, Self.draft, Self.draft, Self.draft, Self.draft]
        )

        #expect(run.result.status != 0)
        #expect(run.result.stderr.contains("submit"), Comment(rawValue: run.result.stderr))
        let keys = run.requests.filter { $0["method"] as? String == "surface.send_key" }
        #expect(keys.count == 3)
    }

    @Test func sendSubmitUsesReturnForShellTargets() throws {
        let shell: [String: Any] = [
            "state": "unknown", "agent": false, "terminal": true,
            "lifecycle": "unknown", "waiting_on_human": false, "blocks_typing": false,
        ]
        let run = try runCLI(
            arguments: ["send", "--submit", "--surface", Self.targetSurfaceRef, "echo hello"],
            inputStates: [shell, shell]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.result.stdout.contains("submitted"))
        let keyRequest = try #require(run.requests.first { $0["method"] as? String == "surface.send_key" })
        let params = try #require(keyRequest["params"] as? [String: Any])
        #expect(params["key"] as? String == "return")
    }

    @Test func sendSubmitStopsWhenADialogOpensAfterSubmitKey() throws {
        let run = try runCLI(
            arguments: ["send", "--submit", "--surface", Self.targetSurfaceRef, "hello"],
            inputStates: [Self.empty, Self.dialog]
        )

        #expect(run.result.status != 0, Comment(rawValue: run.result.stderr))
        #expect(run.requests.filter { $0["method"] as? String == "surface.send_key" }.count == 1)
    }

    @Test func sendSubmitRejectsAStaleEmptySnapshotAfterPaste() throws {
        let run = try runCLI(
            arguments: ["send", "--submit", "--surface", Self.targetSurfaceRef, "hello"],
            inputStates: [Self.empty, Self.empty, Self.empty, Self.empty]
        )

        #expect(run.result.status != 0, Comment(rawValue: run.result.stderr))
        #expect(run.requests.contains { $0["method"] as? String == "surface.send_key" } == false)
    }

    // MARK: - Harness

    private struct Run {
        let result: CLIHookProcessRunner.Result
        let requests: [[String: Any]]
    }

    /// - Parameter inputState: The `surface.input_state` result, or nil to
    ///   answer it with `method_not_found`.
    private func runCLI(
        arguments: [String],
        inputState: [String: Any]? = nil,
        inputStates: [[String: Any]]? = nil,
        screenText: String? = nil
    ) throws -> Run {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-send-guard-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = makeCodexHookSocketPath("sendguard")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let recorder = RequestRecorder()
        let server = Self.startMockServer(
            listenerFD: listenerFD,
            recorder: recorder,
            inputStates: inputStates ?? inputState.map { [$0] },
            screenText: screenText
        )
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

    private static func startMockServer(
        listenerFD: Int32,
        recorder: RequestRecorder,
        inputStates: [[String: Any]]?,
        screenText: String?
    ) -> (done: DispatchSemaphore, stop: StopFlag) {
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        let inputStateData = inputStates?.compactMap { try? JSONSerialization.data(withJSONObject: $0) } ?? []
        let stateIndex = LockedCounter()
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
                serve(
                    clientFD: clientFD,
                    recorder: recorder,
                    inputStateData: inputStateData,
                    stateIndex: stateIndex,
                    screenText: screenText
                )
            }
        }
        return (done, stop)
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }
    }

    private static func response(
        for line: String,
        inputStateData: [Data],
        stateIndex: LockedCounter,
        screenText: String?
    ) -> String {
        let request = codexHookJSONObject(line)
        let id = (request?["id"] as? String) ?? "unknown"
        if request?["method"] as? String == "surface.read_text", let screenText {
            return codexHookV2Response(id: id, ok: true, result: ["text": screenText])
        }
        guard request?["method"] as? String == "surface.input_state" else {
            return codexHookV2Response(id: id, ok: true, result: [
                "workspace_id": callerWorkspaceID,
                "surface_id": callerSurfaceID,
                "delivery": "delivered",
                "submitted": true,
            ])
        }
        guard !inputStateData.isEmpty,
              let state = try? JSONSerialization.jsonObject(
                with: inputStateData[min(stateIndex.next(), inputStateData.count - 1)]
              ) as? [String: Any] else {
            let payload: [String: Any] = [
                "id": id,
                "ok": false,
                "error": ["code": "method_not_found", "message": "Unknown method"],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        return codexHookV2Response(id: id, ok: true, result: state)
    }

    private static func serve(
        clientFD: Int32,
        recorder: RequestRecorder,
        inputStateData: [Data],
        stateIndex: LockedCounter,
        screenText: String?
    ) {
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
                let reply = response(
                    for: line,
                    inputStateData: inputStateData,
                    stateIndex: stateIndex,
                    screenText: screenText
                )
                guard writeAllToFixtureSocket(reply + "\n", fd: clientFD) else { return }
            }
        }
    }
}
