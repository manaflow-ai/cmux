import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Hermes agent hook resume bootstrap
extension SessionPersistenceTests {
    func testHermesAgentHookSurfaceResumeBootstrapsSubrouterAndRewritesStaleCodexProvider() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-surface-resume-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        model = "gpt-5.5"
        openai_base_url = "http://subrouter-team:31415/v1"
        chatgpt_base_url = "http://subrouter-team:31415/backend-api"
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd '/tmp/project' && 'hermes' '--provider' 'openai-codex' '--resume' 'hermes-session-123'",
            cwd: "/tmp/project",
            source: "agent-hook",
            environment: [
                "CODEX_HOME": codexHome.path,
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        XCTAssertTrue(input.contains("config set model.provider"))
        XCTAssertTrue(input.contains("config set model.base_url"))
        XCTAssertTrue(input.contains("config set model.api_mode"))
        XCTAssertTrue(input.contains("codex_responses"))
        XCTAssertTrue(input.contains("gpt-5.5"))
        XCTAssertTrue(input.contains("'--provider' '\\''custom'\\'''") || input.contains("'--provider' 'custom'"))
        XCTAssertFalse(input.contains("openai-codex"))
    }

    func testHermesAgentHookSurfaceResumeBootstrapUsesCapturedExecutable() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd '/tmp/hermes' && '/opt/homebrew/bin/hermes' '--provider' 'custom' '--resume' 'hermes-session-123'",
            cwd: "/tmp/hermes",
            source: "agent-hook",
            environment: [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        XCTAssertTrue(input.contains("'/opt/homebrew/bin/hermes' config set model.provider"))
        XCTAssertTrue(input.contains("'/opt/homebrew/bin/hermes' config set model.base_url"))
    }

    func testHermesAgentHookSurfaceResumeBootstrapStaysInsideCwdGuard() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "{ cd -- '/tmp/hermes project' 2>/dev/null || [ ! -d '/tmp/hermes project' ]; } && './hermes' '--provider' 'custom' '--resume' 'hermes-session-123'",
            cwd: "/tmp/hermes project",
            source: "agent-hook",
            environment: [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        let cdRange = try XCTUnwrap(input.range(of: "cd --"))
        let bootstrapRange = try XCTUnwrap(input.range(of: "config set model.provider"))
        XCTAssertLessThan(cdRange.lowerBound, bootstrapRange.lowerBound)
        XCTAssertTrue(input.contains("'./hermes' config set model.provider"))
        XCTAssertTrue(input.contains("'./hermes' '--provider' 'custom' '--resume'"))
    }

    func testHermesAgentHookSurfaceResumeReplacesExistingBootstrap() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd '/tmp/project' && '/opt/homebrew/bin/hermes' config set model.provider 'custom' >/dev/null && '/opt/homebrew/bin/hermes' config set model.base_url 'http://old-subrouter:9999/v1' >/dev/null && '/opt/homebrew/bin/hermes' config set model.api_mode 'codex_responses' >/dev/null && '/opt/homebrew/bin/hermes' '--provider' 'custom' '--resume' 'hermes-session-123'",
            cwd: "/tmp/project",
            source: "agent-hook",
            environment: [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        XCTAssertEqual(input.components(separatedBy: "config set model.provider").count - 1, 1)
        XCTAssertTrue(input.contains("http://subrouter-team:31415/v1"))
        XCTAssertFalse(input.contains("http://old-subrouter:9999/v1"))
    }

    func testHermesAgentHookSurfaceResumeHandlesMalformedTrailingEscape() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd '/tmp/project' && '/opt/homebrew/bin/hermes' \\",
            cwd: "/tmp/project",
            source: "agent-hook",
            environment: [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        XCTAssertTrue(input.contains("config set model.provider"))
    }

    func testHermesAgentHookSurfaceResumeSkipsCodexBootstrapForExplicitProvider() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd '/tmp/project' && '/opt/homebrew/bin/hermes' '--provider' 'anthropic' '--resume' 'hermes-session-123'",
            cwd: "/tmp/project",
            source: "agent-hook",
            environment: [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        XCTAssertFalse(input.contains("config set model.provider"))
        XCTAssertTrue(input.contains("'--provider' '\\''anthropic'\\'''") || input.contains("'--provider' 'anthropic'"))
    }

}
