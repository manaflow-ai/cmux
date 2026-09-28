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
        let created = try #require(fixture.invocations().first { $0.contains("--create-background") })
        let expectedPrefix = "\(fixture.socketDirectory)|attach --create-background work options --default-cwd \(fixture.base.path) --on-force-close detach --default-layout "
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
        _ = try runCLI(["local-zellij", "start", "work", "--detached", "--cwd", fixture.base.path], fixture)

        let attach = try runCLI(["local-zellij", "attach", "work", "--headless"], fixture)

        #expect(attach.status == 0, Comment(rawValue: attach.stderr))
        #expect(fixture.invocations().contains("\(fixture.socketDirectory)|attach work options --on-force-close detach"))
    }

    @Test func closeDeletesSessionAndResurrectionEntry() throws {
        let fixture = try makeFixture("close")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        _ = try runCLI(["local-zellij", "start", "work", "--detached", "--cwd", fixture.base.path], fixture)

        let close = try runCLI(["local-zellij", "close", "work"], fixture)

        #expect(close.status == 0, Comment(rawValue: close.stderr))
        #expect(fixture.invocations().contains("\(fixture.socketDirectory)|delete-session --force work"))
        let list = try runCLI(["local-zellij", "list", "--json"], fixture)
        #expect(try jsonObject(list.stdout)["count"] as? Int == 0, Comment(rawValue: list.stdout))
    }

    @Test func startRefusesAnExitedSessionCmuxDidNotCreate() throws {
        let fixture = try makeFixture("exited")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try Data("personal [Created 2days ago] (EXITED - attach to resurrect)\n".utf8).write(to: fixture.sessionsURL)

        let start = try runCLI(["local-zellij", "start", "personal", "--detached"], fixture)
        let list = try runCLI(["local-zellij", "list", "--json"], fixture)

        #expect(start.status != 0)
        #expect(start.stderr.contains("zellij delete-session personal"), Comment(rawValue: start.stderr))
        #expect(!fixture.invocations().contains { $0.contains("--create-background") })
        #expect(try jsonObject(list.stdout)["count"] as? Int == 0, "another zellij's exited session is not listed")
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

    private func makeFixture(_ label: String) throws -> Fixture {
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
            if [ -s "$FAKE_ZELLIJ_SESSIONS" ]; then cat "$FAKE_ZELLIJ_SESSIONS"; exit 0; fi
            echo "No active zellij sessions found." >&2
            exit 1 ;;
          attach)
            if [ "$2" = "--create-background" ]; then
              printf '%s [Created 0s ago] \\n' "$3" >> "$FAKE_ZELLIJ_SESSIONS"
              previous=
              for argument in "$@"; do
                if [ "$previous" = "--default-layout" ]; then cp "$argument" "$FAKE_ZELLIJ_LAYOUT_COPY"; fi
                previous=$argument
              done
            fi
            exit 0 ;;
          delete-session)
            grep -v "^$3 " "$FAKE_ZELLIJ_SESSIONS" > "$FAKE_ZELLIJ_SESSIONS.next"
            mv "$FAKE_ZELLIJ_SESSIONS.next" "$FAKE_ZELLIJ_SESSIONS"
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
