import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Grok vault & session directory
extension PiVaultAgentPersistenceTests {
    func testGrokVaultLoadsNativeChatHistoryFromEncodedDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/grok repo"
        let sessionId = "grok-session-123"
        let grokHome = tempDir.appendingPathComponent("grok-home", isDirectory: true)
        let sessionsRoot = grokHome.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = sessionsRoot
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"assistant","content":"assistant preface"}
        {"type":"user","content":"Implement Grok Vault","model":"grok-4","permissionMode":"auto","sandboxMode":"danger-full-access","git":{"branch":"issue-4394-grok-vault-resume"}}
        {"type":"assistant","content":"done"}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInGrok
        registration.sessionDirectory = sessionsRoot.path
        let entries = await SessionIndexStore.loadGrokEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.agent, .grok)
        XCTAssertEqual(entry.sessionId, sessionId)
        XCTAssertEqual(entry.title, "Implement Grok Vault")
        XCTAssertEqual(entry.cwd, cwd)
        XCTAssertEqual(entry.gitBranch, "issue-4394-grok-vault-resume")
        XCTAssertEqual(entry.fileURL, historyURL)
        XCTAssertEqual(
            entry.resumeCommand,
            "{ cd -- '/tmp/grok repo' 2>/dev/null || [ ! -d '/tmp/grok repo' ]; } && 'env' 'GROK_HOME=\(grokHome.path)' 'grok' '-r' 'grok-session-123' '-m' 'grok-4' '--permission-mode' 'auto' '--sandbox' 'danger-full-access'"
        )
    }

    func testGrokVaultTitlePrefersUserQueryOverInjectedMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-metadata-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/grok metadata repo"
        let sessionId = "grok-metadata-session"
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = sessionsRoot
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let userContent = """
        <user_info>
        OS Version: macos 26.4
        </user_info>
        <git_status>
        Current branch: issue-4394-grok-vault-resume
        </git_status>
        <user_query>
        Implement native Vault metadata
        </user_query>
        """
        let records: [[String: Any]] = [
            ["type": "system", "content": "You are Grok"],
            ["type": "user", "content": userContent, "model": "grok-4"],
        ]
        let jsonLines = try records.map { record in
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
        try (jsonLines + "\n").write(to: historyURL, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInGrok
        registration.sessionDirectory = sessionsRoot.path
        let entries = await SessionIndexStore.loadGrokEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.title, "Implement native Vault metadata")
    }

    func testGrokVaultFindsBranchAfterStableMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-late-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/grok late branch"
        let sessionId = "grok-late-branch-session"
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = sessionsRoot
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","content":"Find late branch","model":"grok-4","permissionMode":"auto","sandboxMode":"danger-full-access"}
        {"type":"assistant","content":"Working","git":{"branch":"late-branch"}}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInGrok
        registration.sessionDirectory = sessionsRoot.path
        let entries = await SessionIndexStore.loadGrokEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.gitBranch, "late-branch")
    }

    func testGrokVaultLoadsHookObservedShellGrokHome() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-observed-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let homeDirectory = tempDir.appendingPathComponent("home", isDirectory: true)
        let hookStore = homeDirectory
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("grok-hook-sessions.json", isDirectory: false)
        try FileManager.default.createDirectory(at: hookStore.deletingLastPathComponent(), withIntermediateDirectories: true)

        let cwd = "/tmp/grok observed home"
        let sessionId = "grok-observed-home-session"
        let grokHome = tempDir.appendingPathComponent("shell-grok-home", isDirectory: true)
        let historyURL = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","content":"Find sessions under shell GROK_HOME","model":"grok-4","permissionMode":"auto","sandboxMode":"danger-full-access"}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        try """
        {
          "version": 1,
          "sessions": {
            "\(sessionId)": {
              "launchCommand": {
                "environment": {
                  "GROK_HOME": "\(grokHome.path)"
                }
              }
            }
          }
        }
        """.write(to: hookStore, atomically: true, encoding: .utf8)

        let entries = await SessionIndexStore.loadGrokEntries(
            registration: .builtInGrok,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            environment: [:],
            homeDirectory: homeDirectory.path
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.sessionId, sessionId)
        XCTAssertEqual(entry.title, "Find sessions under shell GROK_HOME")
        XCTAssertEqual(entry.cwd, cwd)
        XCTAssertEqual(
            entry.resumeCommand,
            "{ cd -- '/tmp/grok observed home' 2>/dev/null || [ ! -d '/tmp/grok observed home' ]; } && 'env' 'GROK_HOME=\(grokHome.path)' 'grok' '-r' '\(sessionId)' '-m' 'grok-4' '--permission-mode' 'auto' '--sandbox' 'danger-full-access'"
        )
    }

    func testGrokVaultLoadsHookObservedShellGrokHomeFromCustomStateDir() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-custom-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let homeDirectory = tempDir.appendingPathComponent("home", isDirectory: true)
        let hookStateDir = tempDir.appendingPathComponent("hook-state", isDirectory: true)
        let hookStore = hookStateDir.appendingPathComponent("grok-hook-sessions.json", isDirectory: false)
        try FileManager.default.createDirectory(at: hookStateDir, withIntermediateDirectories: true)

        let cwd = "/tmp/grok custom state"
        let sessionId = "grok-custom-state-session"
        let grokHome = tempDir.appendingPathComponent("custom-state-grok-home", isDirectory: true)
        let historyURL = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","content":"Find sessions under custom hook state","model":"grok-4"}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        try """
        {
          "version": 1,
          "sessions": {
            "\(sessionId)": {
              "launchCommand": {
                "environment": {
                  "GROK_HOME": "\(grokHome.path)"
                }
              }
            }
          }
        }
        """.write(to: hookStore, atomically: true, encoding: .utf8)

        let entries = await SessionIndexStore.loadGrokEntries(
            registration: .builtInGrok,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDir.path],
            homeDirectory: homeDirectory.path
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.sessionId, sessionId)
        XCTAssertEqual(entry.title, "Find sessions under custom hook state")
        XCTAssertEqual(
            entry.resumeCommand,
            "{ cd -- '/tmp/grok custom state' 2>/dev/null || [ ! -d '/tmp/grok custom state' ]; } && 'env' 'GROK_HOME=\(grokHome.path)' 'grok' '-r' '\(sessionId)' '-m' 'grok-4'"
        )
    }

    func testRegisteredGrokSessionDirectoryUsesNativeDirectoryLayout() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registered-grok-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/custom grok repo"
        let sessionId = "custom-grok-session-123"
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = sessionsRoot
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","content":"Resume a custom Grok-compatible agent","git":{"branch":"issue-4394-grok-vault-resume"}}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        let registration = CmuxVaultAgentRegistration(
            id: "custom-grok",
            name: "Custom Grok",
            detect: CmuxVaultAgentDetectRule(processName: "custom-grok"),
            sessionIdSource: .grokSessionDirectory,
            resumeCommand: "custom-grok -r {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: sessionsRoot.path
        )
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, "custom-grok:\(sessionId)")
        XCTAssertEqual(entry.agent, .registered(RegisteredSessionAgent(registration: registration)))
        XCTAssertEqual(entry.sessionId, sessionId)
        XCTAssertEqual(entry.title, "Resume a custom Grok-compatible agent")
        XCTAssertEqual(entry.cwd, cwd)
        XCTAssertEqual(entry.gitBranch, "issue-4394-grok-vault-resume")
        XCTAssertEqual(
            entry.resumeCommand,
            "{ cd -- '/tmp/custom grok repo' 2>/dev/null || [ ! -d '/tmp/custom grok repo' ]; } && 'env' 'GROK_HOME=\(tempDir.path)' 'custom-grok' '-r' '\(sessionId)'"
        )
    }

    func testGrokVaultCWDFilterUsesEncodedProjectDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        func writeHistory(cwd: String, sessionId: String, prompt: String) throws {
            let historyURL = sessionsRoot
                .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
                .appendingPathComponent("chat_history.jsonl", isDirectory: false)
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try #"{"type":"user","content":"\#(prompt)"}"#
                .write(to: historyURL, atomically: true, encoding: .utf8)
        }

        try writeHistory(cwd: "/tmp/current grok repo", sessionId: "current-session", prompt: "current")
        try writeHistory(cwd: "/tmp/current grok repo/../current grok repo", sessionId: "current-session", prompt: "duplicate")
        try writeHistory(cwd: "/tmp/other grok repo", sessionId: "other-session", prompt: "other")

        var registration = CmuxVaultAgentRegistration.builtInGrok
        registration.sessionDirectory = sessionsRoot.path
        let entries = await SessionIndexStore.loadGrokEntries(
            registration: registration,
            needle: "",
            cwdFilter: "/tmp/current grok repo/../current grok repo",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries.map(\.sessionId), ["current-session"])
        XCTAssertEqual(entries.first?.cwd, "/tmp/current grok repo")
    }

    @MainActor
    func testGrokAgentSearchScopeUsesCurrentDirectoryCWDFilter() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-agent-scope-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let previousGrokHome = getenv("GROK_HOME").map { String(cString: $0) }
        let grokHome = tempDir.appendingPathComponent("grok-home", isDirectory: true)
        setenv("GROK_HOME", grokHome.path, 1)
        defer {
            if let previousGrokHome {
                setenv("GROK_HOME", previousGrokHome, 1)
            } else {
                unsetenv("GROK_HOME")
            }
        }

        let sessionsRoot = grokHome.appendingPathComponent("sessions", isDirectory: true)
        func writeHistory(cwd: String, sessionId: String, prompt: String) throws {
            let historyURL = sessionsRoot
                .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
                .appendingPathComponent("chat_history.jsonl", isDirectory: false)
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try #"{"type":"user","content":"\#(prompt)","model":"grok-4"}"#
                .write(to: historyURL, atomically: true, encoding: .utf8)
        }

        try writeHistory(cwd: "/tmp/current grok search", sessionId: "current-session", prompt: "current")
        try writeHistory(cwd: "/tmp/other grok search", sessionId: "other-session", prompt: "other")

        let store = SessionIndexStore()
        store.setCurrentDirectoryIfChanged("/tmp/current grok search")
        let outcome = await store.searchSessions(
            query: "",
            scope: .agent(.grok),
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(outcome.entries.map(\.sessionId), ["current-session"])
        XCTAssertEqual(outcome.entries.first?.cwd, "/tmp/current grok search")
    }

}
