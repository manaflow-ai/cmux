import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Registered agent command templates & CWD handling
extension PiVaultAgentPersistenceTests {
    func testRegisteredAgentTemplateFailsClosedWhenPlaceholderIsUnavailable() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: nil,
            registrationOverride: registration
        )

        XCTAssertNil(command)
    }

    func testRegisteredAgentTemplateUsesExplicitWorkingDirectoryForCWDPlaceholder() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: false
        )

        XCTAssertEqual(command, "'acme-agent' '--cwd' '/tmp/acme' '--session' 'session-123'")
    }

    func testRegisteredAgentTemplatePreservesCWDArgumentWithWorkingDirectoryPrefix() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration
        )

        XCTAssertEqual(
            command,
            "{ cd -- '/tmp/acme' 2>/dev/null || [ ! -d '/tmp/acme' ]; } && 'acme-agent' '--cwd' '/tmp/acme' '--session' 'session-123'"
        )
    }

    func testRegisteredAgentTemplateDoesNotExpandPlaceholdersInsideReplacementValues() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}} --cwd {{cwd}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-{{cwd}}",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: false
        )

        XCTAssertEqual(command, "'acme-agent' '--session' 'session-{{cwd}}' '--cwd' '/tmp/acme'")
    }

    func testRegisteredAgentCWDIgnoreSuppressesResumeWorkingDirectory() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .ignore
        )
        let entry = SessionEntry(
            id: "acme-agent:session-123",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "session-123",
            title: "Acme",
            cwd: "/tmp/acme",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1),
            fileURL: nil,
            specifics: .registered(registration)
        )

        XCTAssertNil(entry.resumeWorkingDirectory)
        XCTAssertEqual(entry.resumeCommand, "'acme-agent' '--session' 'session-123'")
    }

}
