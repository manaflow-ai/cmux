import Darwin
import Foundation
import Testing

/// `cmux local-zellij` must keep every zellij call inside its private socket
/// directory and attach clients that detach, rather than quit, on force close.
/// A fake zellij records each invocation and keeps the session list in a file,
/// so these tests run without zellij installed.
@Suite(.serialized)
struct CLILocalZellijLifecycleTests {
    private static let timeout: TimeInterval = 30

    private struct Fixture {
        /// Temporary directory holding the fake zellij and its files.
        let base: URL
        /// `CMUX_LOCAL_ZELLIJ_STATE_DIR`.
        let root: URL
        let environment: [String: String]
        let logURL: URL
        let sessionsURL: URL
        let layoutCopyURL: URL

        var socketDirectory: String { root.appendingPathComponent("sock", isDirectory: true).path }

        /// `<ZELLIJ_SOCKET_DIR>|<arguments>` for each fake zellij call.
        func invocations() -> [String] {
            ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .map(String.init)
        }
    }

    @Test func detachedStartCreatesDetachingSessionInPrivateSocketDirectory() throws {
        let fixture = try makeFixture("start")
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let start = try runCLI(
            ["local-zellij", "start", "work", "--detached", "--cwd", fixture.base.path, "--command", "npm run \"dev\"", "--json"],
            fixture
        )
        #expect(start.status == 0, Comment(rawValue: start.stderr))
        let zellijName = try #require(try jsonObject(start.stdout)["zellij_session_name"] as? String)
        #expect(zellijName.range(of: "^work-[0-9a-f]{8}$", options: .regularExpression) != nil, "the zellij name carries the record's token")
        // Serialization stays off: a dead session must leave nothing that a
        // surface's `zellij attach` could resurrect into a new server that
        // inherits the surface's CMUX_* credentials and identity.
        let created = try #require(fixture.invocations().first { $0.contains("--create-background") })
        let expectedPrefix = "\(fixture.socketDirectory)|attach --create-background \(zellijName) options --default-cwd \(fixture.base.path) --on-force-close detach --session-serialization false --default-layout "
        #expect(created.hasPrefix(expectedPrefix), Comment(rawValue: created))
        let layout = try String(contentsOf: fixture.layoutCopyURL, encoding: .utf8)
        #expect(layout.contains(#"args "-lc" "npm run \"dev\"""#), Comment(rawValue: layout))
        let layoutPath = String(created.dropFirst(expectedPrefix.count))
        #expect(!FileManager.default.fileExists(atPath: layoutPath), "the generated layout is removed after creation")

        let list = try runCLI(["local-zellij", "list", "--json"], fixture)
        #expect(list.status == 0, Comment(rawValue: list.stderr))
        let sessions = try #require(try jsonObject(list.stdout)["sessions"] as? [[String: Any]])
        #expect(sessions.count == 1)
        #expect(sessions.first?["session_name"] as? String == "work")
        #expect(sessions.first?["state"] as? String == "live")
        #expect(sessions.first?["managed"] as? Bool == true)
    }

    @Test func headlessAttachUsesPrivateSocketAndDetachesOnForceClose() throws {
        let fixture = try makeFixture("attach")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let zellijName = try startSession("work", fixture).zellijName

        let attach = try runCLI(["local-zellij", "attach", "work", "--headless"], fixture)

        #expect(attach.status == 0, Comment(rawValue: attach.stderr))
        #expect(fixture.invocations().contains("\(fixture.socketDirectory)|attach \(zellijName) options --on-force-close detach"))
    }

    @Test func closeDeletesSessionAndResurrectionEntry() throws {
        let fixture = try makeFixture("close")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let zellijName = try startSession("work", fixture).zellijName

        let close = try runCLI(["local-zellij", "close", "work"], fixture)

        #expect(close.status == 0, Comment(rawValue: close.stderr))
        #expect(fixture.invocations().contains("\(fixture.socketDirectory)|delete-session --force \(zellijName)"))
        let list = try runCLI(["local-zellij", "list", "--json"], fixture)
        #expect(try jsonObject(list.stdout)["count"] as? Int == 0, Comment(rawValue: list.stdout))
    }

    @Test func failedDeleteKeepsTheRecordOfASessionThatIsStillListed() throws {
        let fixture = try makeFixture("delete-fails", deleteFails: true)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        _ = try startSession("work", fixture)

        // delete-session fails with unrelated "not found" output; the session
        // is still listed, so close must fail and keep managing it.
        let close = try runCLI(["local-zellij", "close", "work"], fixture)
        let status = try runCLI(["local-zellij", "status", "work", "--json"], fixture)

        #expect(close.status != 0, Comment(rawValue: close.stdout))
        #expect(status.status == 0, Comment(rawValue: status.stderr))
        #expect(try jsonObject(status.stdout)["state"] as? String == "live", Comment(rawValue: status.stdout))
    }

    @Test func staleRecordNeverTouchesAnUnrelatedExitedSessionWithTheSameName() throws {
        let fixture = try makeFixture("stale")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let start = try runCLI(["local-zellij", "start", "work", "--detached", "--cwd", fixture.base.path], fixture)
        #expect(start.status == 0, Comment(rawValue: start.stderr))
        // cmux's session ends, then another zellij session named `work`
        // exits and lands in zellij's global resurrection cache.
        try Data("work [Created 1m ago] (EXITED - attach to resurrect)\n".utf8).write(to: fixture.sessionsURL)
        let before = fixture.invocations().count

        let status = try runCLI(["local-zellij", "status", "work", "--json"], fixture)
        let attach = try runCLI(["local-zellij", "attach", "work", "--headless"], fixture)
        let close = try runCLI(["local-zellij", "close", "work"], fixture)

        #expect(try jsonObject(status.stdout)["state"] as? String == "stale", Comment(rawValue: status.stdout + status.stderr))
        #expect(attach.status != 0, "attach must not resurrect a session cmux did not create")
        #expect(close.status == 0, Comment(rawValue: close.stderr))
        let touched = fixture.invocations().dropFirst(before).filter {
            $0.hasSuffix("|attach work options --on-force-close detach") || $0.hasSuffix("|delete-session --force work")
        }
        #expect(touched.isEmpty, Comment(rawValue: touched.joined(separator: "\n")))
    }

    @Test func startDuringCloseKeepsTheNewSessionRegistered() throws {
        let fixture = try makeFixture("race", holdDelete: true)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let original = try startSession("work", fixture)

        let close = try launchCLI(["local-zellij", "close", "work"], fixture)
        // Handshake: close has deleted the zellij session and is held there,
        // before it removes the record.
        #expect(waitFor { FileManager.default.fileExists(atPath: fixture.sessionsURL.path + ".deleted") })
        let start = try launchCLI(["local-zellij", "start", "work", "--detached", "--cwd", fixture.base.path, "--json"], fixture)
        // Without serialization start finishes inside this window and reuses
        // the record close is about to remove; with it, start waits for close.
        _ = waitFor(seconds: 2) { !start.process.isRunning }
        FileManager.default.createFile(atPath: fixture.sessionsURL.path + ".release", contents: nil)
        close.process.waitUntilExit()
        start.process.waitUntilExit()

        #expect(close.process.terminationStatus == 0, Comment(rawValue: close.stderr()))
        #expect(start.process.terminationStatus == 0, Comment(rawValue: start.stderr()))
        let list = try runCLI(["local-zellij", "list", "--json"], fixture)
        let sessions = try #require(try jsonObject(list.stdout)["sessions"] as? [[String: Any]])
        #expect(sessions.count == 1, Comment(rawValue: list.stdout))
        #expect(sessions.first?["managed"] as? Bool == true, Comment(rawValue: list.stdout))
        #expect(sessions.first?["state"] as? String == "live", Comment(rawValue: list.stdout))
        #expect(sessions.first?["id"] as? String != original.id, "start after close creates a new identity")
    }

    @Test func retryAfterAnUncertainStartReusesTheSameSession() throws {
        let fixture = try makeFixture("uncertain", failListAfterFirstCreate: true)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let arguments = ["local-zellij", "start", "work", "--detached", "--cwd", fixture.base.path, "--command", "make deploy"]

        let first = try runCLI(arguments, fixture)
        let retry = try runCLI(arguments, fixture)
        let plain = try runCLI(["local-zellij", "start", "work", "--detached", "--json"], fixture)

        #expect(first.status != 0, "the listing after creation failed")
        #expect(retry.status != 0, "the command must not run a second time")
        #expect(plain.status == 0, Comment(rawValue: plain.stderr))
        #expect(fixture.invocations().filter { $0.contains("--create-background") }.count == 1)
        let list = try runCLI(["local-zellij", "list", "--json"], fixture)
        let sessions = try #require(try jsonObject(list.stdout)["sessions"] as? [[String: Any]])
        #expect(sessions.count == 1, Comment(rawValue: list.stdout))
        #expect(sessions.first?["managed"] as? Bool == true, Comment(rawValue: list.stdout))
        #expect(sessions.first?["id"] as? String == (try jsonObject(plain.stdout)["id"] as? String))
    }

    @Test func sessionThatExitsBeforeVerificationStaysOwned() throws {
        // The zellij server can stop between creation and cmux's check; the
        // session is then listed as exited and can still be resurrected.
        let fixture = try makeFixture("exited-early", createdSessionsExit: true)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let arguments = ["local-zellij", "start", "work", "--detached", "--cwd", fixture.base.path, "--command", "make deploy"]

        let first = try runCLI(arguments, fixture)
        let status = try runCLI(["local-zellij", "status", "work", "--json"], fixture)
        let retry = try runCLI(arguments, fixture)
        let close = try runCLI(["local-zellij", "close", "work"], fixture)

        #expect(first.status != 0)
        #expect(first.stderr.contains("has exited"), Comment(rawValue: first.stderr))
        #expect(status.status == 0, Comment(rawValue: status.stderr))
        let zellijName = try #require(try jsonObject(status.stdout)["zellij_session_name"] as? String)
        #expect(try jsonObject(status.stdout)["state"] as? String == "exited", Comment(rawValue: status.stdout))
        #expect(retry.status != 0, "the command must not run in a second session")
        #expect(fixture.invocations().filter { $0.contains("--create-background") }.count == 1)
        #expect(close.status == 0, Comment(rawValue: close.stderr))
        #expect(fixture.invocations().contains { $0.hasSuffix("|delete-session --force \(zellijName)") })
    }

    @Test func attachNeverResurrectsAnExitedSession() throws {
        // Resurrecting from a client would start a zellij server that
        // inherits that client's environment, so only live sessions attach.
        let fixture = try makeFixture("attach-exited", createdSessionsExit: true)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        _ = try runCLI(["local-zellij", "start", "work", "--detached", "--cwd", fixture.base.path], fixture)
        let before = fixture.invocations().count

        let attach = try runCLI(["local-zellij", "attach", "work", "--headless"], fixture)

        #expect(attach.status != 0)
        #expect(attach.stderr.contains("has exited"), Comment(rawValue: attach.stderr))
        let attaches = fixture.invocations().dropFirst(before).filter { $0.contains("|attach work-") }
        #expect(attaches.isEmpty, Comment(rawValue: attaches.joined(separator: "\n")))
    }

    @Test func attachFinishingAfterTheRecordChangedKeepsTheRegistryValid() throws {
        let fixture = try makeFixture("attach-renamed")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let original = try startSession("work", fixture)
        let app = try AttachHoldingCmuxSocket()
        defer { app.stop() }
        let attach = try launchGUIAttach("work", fixture, app)
        #expect(app.respawnArrived.wait(timeout: .now() + 20) == .success, "attach reached surface.respawn")

        // While attach waits on the app, its record is renamed and a new
        // record takes the name it read.
        let registryURL = fixture.root.appendingPathComponent("sessions.json")
        var registry = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any])
        var records = try #require(registry["sessions"] as? [[String: Any]])
        records[0]["name"] = "renamed"
        var newcomer = records[0]
        newcomer["id"] = UUID().uuidString
        newcomer["name"] = "work"
        records.append(newcomer)
        registry["sessions"] = records
        try JSONSerialization.data(withJSONObject: registry, options: [.sortedKeys]).write(to: registryURL)
        #expect(chmod(registryURL.path, 0o600) == 0)
        app.releaseRespawn.signal()
        attach.waitUntilExit()

        let list = try runCLI(["local-zellij", "list", "--json"], fixture)
        #expect(list.status == 0, Comment(rawValue: list.stderr))
        let sessions = try #require(try jsonObject(list.stdout)["sessions"] as? [[String: Any]])
        let attached = try #require(sessions.first { $0["id"] as? String == original.id })
        #expect(attached["session_name"] as? String == "renamed", "attach must not restore the name it read")
        #expect(attached["workspace_id"] as? String == AttachHoldingCmuxSocket.workspaceID, "attach still records where it attached")
    }

    @Test func sessionNamesStartingWithADashAreRejectedBeforeZellijRuns() throws {
        let fixture = try makeFixture("dash")
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let start = try runCLI(["local-zellij", "start", "--name=-work", "--detached"], fixture)

        #expect(start.status != 0)
        #expect(start.stderr.contains("must start with a letter, number, or underscore"), Comment(rawValue: start.stderr))
        #expect(fixture.invocations().isEmpty, "zellij would parse the name as an option")
    }

    @Test func closeDuringGUIAttachIsNotUndoneWhenTheAttachFinishes() throws {
        let fixture = try makeFixture("attach-race")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        _ = try startSession("work", fixture)
        let app = try AttachHoldingCmuxSocket()
        defer { app.stop() }

        // GUI attach reads the record, then blocks in surface.respawn.
        let attach = try launchGUIAttach("work", fixture, app)
        #expect(app.respawnArrived.wait(timeout: .now() + 20) == .success, "attach reached surface.respawn")

        let close = try runCLI(["local-zellij", "close", "work"], fixture)
        app.releaseRespawn.signal()
        attach.waitUntilExit()

        #expect(close.status == 0, Comment(rawValue: close.stderr))
        let list = try runCLI(["local-zellij", "list", "--json"], fixture)
        #expect(try jsonObject(list.stdout)["count"] as? Int == 0, Comment(rawValue: list.stdout))
    }

    @Test func nameTooLongForTheSocketPathIsRejectedBeforeZellijRuns() throws {
        let fixture = try makeFixture("long")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let name = String(repeating: "n", count: 100)

        let start = try runCLI(["local-zellij", "start", name, "--detached"], fixture)

        #expect(start.status != 0)
        #expect(start.stderr.contains("Unix socket path"), Comment(rawValue: start.stderr))
        #expect(fixture.invocations().isEmpty)
    }

    private func makeFixture(
        _ label: String,
        holdDelete: Bool = false,
        failListAfterFirstCreate: Bool = false,
        createdSessionsExit: Bool = false,
        deleteFails: Bool = false
    ) throws -> Fixture {
        // Keep the root short: zellij sockets live below it.
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-lz-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o700) == 0)
        let fakeZellij = root.appendingPathComponent("fake-zellij", isDirectory: false)
        let script = """
        #!/bin/sh
        printf '%s|%s\\n' "$ZELLIJ_SOCKET_DIR" "$*" >> "$FAKE_ZELLIJ_LOG"
        case "$1" in
          list-sessions)
            if [ -e "$FAKE_ZELLIJ_SESSIONS.fail-next-list" ]; then
              rm "$FAKE_ZELLIJ_SESSIONS.fail-next-list"
              echo "listing failed" >&2
              exit 1
            fi
            if [ -s "$FAKE_ZELLIJ_SESSIONS" ]; then cat "$FAKE_ZELLIJ_SESSIONS"; exit 0; fi
            echo "No active zellij sessions found." >&2
            exit 1 ;;
          attach)
            if [ "$2" = "--create-background" ]; then
              if [ -n "$FAKE_ZELLIJ_CREATED_SESSIONS_EXIT" ]; then
                printf '%s [Created 0s ago] (EXITED - attach to resurrect)\\n' "$3" >> "$FAKE_ZELLIJ_SESSIONS"
              else
                printf '%s [Created 0s ago] \\n' "$3" >> "$FAKE_ZELLIJ_SESSIONS"
              fi
              if [ -n "$FAKE_ZELLIJ_FAIL_LIST_AFTER_FIRST_CREATE" ] && [ ! -e "$FAKE_ZELLIJ_SESSIONS.created-once" ]; then
                touch "$FAKE_ZELLIJ_SESSIONS.created-once" "$FAKE_ZELLIJ_SESSIONS.fail-next-list"
              fi
              previous=
              for argument in "$@"; do
                if [ "$previous" = "--default-layout" ]; then cp "$argument" "$FAKE_ZELLIJ_LAYOUT_COPY"; fi
                previous=$argument
              done
            fi
            exit 0 ;;
          delete-session)
            if [ -n "$FAKE_ZELLIJ_DELETE_FAILS" ]; then
              echo "Error: config file not found" >&2
              exit 1
            fi
            grep -v "^$3 " "$FAKE_ZELLIJ_SESSIONS" > "$FAKE_ZELLIJ_SESSIONS.next"
            mv "$FAKE_ZELLIJ_SESSIONS.next" "$FAKE_ZELLIJ_SESSIONS"
            if [ -n "$FAKE_ZELLIJ_HOLD_DELETE" ]; then
              touch "$FAKE_ZELLIJ_SESSIONS.deleted"
              waited=0
              while [ ! -e "$FAKE_ZELLIJ_SESSIONS.release" ] && [ $waited -lt 600 ]; do sleep 0.05; waited=$((waited + 1)); done
            fi
            exit 0 ;;
        esac
        exit 0
        """
        try Data(script.utf8).write(to: fakeZellij)
        #expect(chmod(fakeZellij.path, 0o755) == 0)

        let logURL = root.appendingPathComponent("zellij.log", isDirectory: false)
        let sessionsURL = root.appendingPathComponent("sessions.txt", isDirectory: false)
        let layoutCopyURL = root.appendingPathComponent("layout-copy.kdl", isDirectory: false)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_LOCAL_ZELLIJ_BIN"] = fakeZellij.path
        environment["CMUX_LOCAL_ZELLIJ_STATE_DIR"] = root.appendingPathComponent("state", isDirectory: true).path
        environment["FAKE_ZELLIJ_LOG"] = logURL.path
        environment["FAKE_ZELLIJ_SESSIONS"] = sessionsURL.path
        environment["FAKE_ZELLIJ_LAYOUT_COPY"] = layoutCopyURL.path
        if holdDelete { environment["FAKE_ZELLIJ_HOLD_DELETE"] = "1" }
        if failListAfterFirstCreate { environment["FAKE_ZELLIJ_FAIL_LIST_AFTER_FIRST_CREATE"] = "1" }
        if createdSessionsExit { environment["FAKE_ZELLIJ_CREATED_SESSIONS_EXIT"] = "1" }
        if deleteFails { environment["FAKE_ZELLIJ_DELETE_FAILS"] = "1" }
        for key in ["CMUX_SOCKET", "CMUX_SOCKET_PATH", "CMUX_WORKSPACE_ID", "ZELLIJ", "ZELLIJ_SESSION_NAME"] {
            environment.removeValue(forKey: key)
        }
        return Fixture(
            base: root,
            root: root.appendingPathComponent("state", isDirectory: true),
            environment: environment,
            logURL: logURL,
            sessionsURL: sessionsURL,
            layoutCopyURL: layoutCopyURL
        )
    }

    /// Starts a detached session and returns its registry ID and zellij name.
    private func startSession(_ name: String, _ fixture: Fixture) throws -> (id: String, zellijName: String) {
        let start = try runCLI(["local-zellij", "start", name, "--detached", "--cwd", fixture.base.path, "--json"], fixture)
        try #require(start.status == 0, Comment(rawValue: start.stderr))
        let payload = try jsonObject(start.stdout)
        return (
            try #require(payload["id"] as? String),
            try #require(payload["zellij_session_name"] as? String)
        )
    }

    private struct Launched {
        let process: Process
        let stderrURL: URL
        func stderr() -> String { (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "" }
    }

    /// Runs the CLI in the background, keeping stderr for assertions.
    private func launchCLI(_ arguments: [String], _ fixture: Fixture) throws -> Launched {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try BundledCLITestSupport.bundledCLIPath())
        process.arguments = arguments
        process.environment = fixture.environment
        let stderrURL = fixture.base.appendingPathComponent("stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        try process.run()
        return Launched(process: process, stderrURL: stderrURL)
    }

    private func launchGUIAttach(_ name: String, _ fixture: Fixture, _ app: AttachHoldingCmuxSocket) throws -> Process {
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: try BundledCLITestSupport.bundledCLIPath())
        attach.arguments = [
            "local-zellij", "attach", name,
            "--workspace", AttachHoldingCmuxSocket.workspaceID,
            "--surface", AttachHoldingCmuxSocket.surfaceID,
        ]
        var environment = fixture.environment
        environment["CMUX_SOCKET_PATH"] = app.socketPath
        environment["CMUX_SOCKET_PASSWORD"] = ""
        attach.environment = environment
        attach.standardOutput = FileHandle.nullDevice
        attach.standardError = FileHandle.nullDevice
        try attach.run()
        return attach
    }

    /// Polls `condition` until it holds or `seconds` pass.
    @discardableResult
    private func waitFor(seconds: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            usleep(20_000)
        }
        return true
    }

    private func runCLI(_ arguments: [String], _ fixture: Fixture) throws -> CLIHookProcessRunner.Result {
        let result = CLIHookProcessRunner.run(
            executablePath: try BundledCLITestSupport.bundledCLIPath(),
            arguments: arguments,
            environment: fixture.environment,
            timeout: Self.timeout
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return result
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

/// A cmux control socket that answers the lookups a GUI attach makes and
/// holds `surface.respawn` until the test releases it.
private final class AttachHoldingCmuxSocket: @unchecked Sendable {
    static let windowID = "0A000000-0000-0000-0000-000000000001"
    static let workspaceID = "0B000000-0000-0000-0000-000000000002"
    static let surfaceID = "0C000000-0000-0000-0000-000000000003"

    let socketPath = makeCodexHookSocketPath("zjrace")
    let respawnArrived = DispatchSemaphore(value: 0)
    let releaseRespawn = DispatchSemaphore(value: 0)
    private let listenerFD: Int32
    private let stopped = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isStopping = false

    init() throws {
        listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let listenerFD = listenerFD
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { stopped.signal() }
            while !stopping {
                var pollFD = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&pollFD, 1, 100) > 0 else { continue }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                guard clientFD >= 0 else { continue }
                DispatchQueue.global(qos: .userInitiated).async { [self] in serve(clientFD) }
            }
        }
    }

    private var stopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return isStopping
    }

    func stop() {
        lock.lock(); isStopping = true; lock.unlock()
        releaseRespawn.signal()
        _ = stopped.wait(timeout: .now() + 5)
        Darwin.close(listenerFD)
        unlink(socketPath)
    }

    private func serve(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        guard ignoreSIGPIPE(onAcceptedFixtureSocket: clientFD) else { return }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let line = String(decoding: pending.subdata(in: 0..<newline.lowerBound), as: UTF8.self)
                pending.removeSubrange(0...newline.lowerBound)
                let request = codexHookJSONObject(line) ?? [:]
                let id = request["id"] as? String ?? "unknown"
                let result = response(to: request["method"] as? String ?? "")
                guard writeAllToFixtureSocket(codexHookV2Response(id: id, ok: true, result: result) + "\n", fd: clientFD) else { return }
            }
        }
    }

    private func response(to method: String) -> [String: Any] {
        let workspace: [String: Any] = ["id": Self.workspaceID, "ref": "workspace:1", "index": 0, "title": "work"]
        let surface: [String: Any] = ["id": Self.surfaceID, "ref": "surface:1", "index": 0, "type": "terminal"]
        switch method {
        case "window.list":
            return ["windows": [["id": Self.windowID, "ref": "window:1", "index": 0]]]
        case "workspace.list":
            return ["workspaces": [workspace]]
        case "surface.list":
            return ["surfaces": [surface]]
        case "surface.respawn":
            respawnArrived.signal()
            _ = releaseRespawn.wait(timeout: .now() + 30)
            return ["workspace_id": Self.workspaceID, "surface_id": Self.surfaceID]
        default:
            return ["workspace_id": Self.workspaceID, "surface_id": Self.surfaceID, "window_id": Self.windowID]
        }
    }
}
