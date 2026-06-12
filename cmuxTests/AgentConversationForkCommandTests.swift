import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentConversationForkCommandTests: XCTestCase {
    func testPiOmpAndDroidForkCommandsUseNativeForkFlags() {
        let pi = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-session-123",
            workingDirectory: "/tmp/pi repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "/Users/example/.bun/bin/pi",
                arguments: [
                    "/Users/example/.bun/bin/pi",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "--session",
                    "old-pi-session"
                ],
                workingDirectory: "/tmp/pi repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            ),
            registration: .builtInPi
        )
        XCTAssertEqual(
            pi.forkCommand,
            "{ cd -- '/tmp/pi repo' 2>/dev/null || [ ! -d '/tmp/pi repo' ]; } && '/Users/example/.bun/bin/pi' '--fork' 'pi-session-123' '--model' 'anthropic/claude-sonnet-4-6'"
        )

        // Scanner-detected pi sessions carry kind .custom("pi") (see
        // VaultAgentProcessScanner) and fork through the registration's
        // forkCommand template instead of the built-in .pi branch.
        let scannerPi = SessionRestorableAgentSnapshot(
            kind: .custom("pi"),
            sessionId: "pi-session-123",
            workingDirectory: "/tmp/pi repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "/Users/example/.bun/bin/pi",
                arguments: ["/Users/example/.bun/bin/pi"],
                workingDirectory: "/tmp/pi repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            ),
            registration: .builtInPi
        )
        XCTAssertEqual(
            scannerPi.forkCommand,
            "{ cd -- '/tmp/pi repo' 2>/dev/null || [ ! -d '/tmp/pi repo' ]; } && '/Users/example/.bun/bin/pi' '--fork' 'pi-session-123'"
        )

        let omp = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: "omp-session-789",
            workingDirectory: "/tmp/omp repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: "/Users/example/.bun/bin/omp",
                arguments: ["/Users/example/.bun/bin/omp"],
                workingDirectory: "/tmp/omp repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            ),
            registration: .builtInOmp
        )
        XCTAssertEqual(
            omp.forkCommand,
            "{ cd -- '/tmp/omp repo' 2>/dev/null || [ ! -d '/tmp/omp repo' ]; } && '/Users/example/.bun/bin/omp' '--fork' 'omp-session-789'"
        )

        let droid = SessionRestorableAgentSnapshot(
            kind: .factory,
            sessionId: "droid-session-456",
            workingDirectory: "/tmp/droid repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "factory",
                executablePath: "/usr/local/bin/droid",
                arguments: [
                    "/usr/local/bin/droid",
                    "--settings",
                    "/tmp/droid-settings.json",
                    "--resume",
                    "old-droid-session"
                ],
                workingDirectory: "/tmp/droid repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
        XCTAssertEqual(
            droid.forkCommand,
            "{ cd -- '/tmp/droid repo' 2>/dev/null || [ ! -d '/tmp/droid repo' ]; } && '/usr/local/bin/droid' '--fork' 'droid-session-456' '--settings' '/tmp/droid-settings.json'"
        )
    }

    func testVaultAgentRegistrationForkCommandDecoding() throws {
        func registrationJSON(forkCommandLine: String) -> Data {
            Data("""
            {
              "id": "acme-agent",
              "name": "Acme Agent",
              "detect": { "processName": "acme" },
              "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
              "resumeCommand": "acme --session {{sessionId}}"\(forkCommandLine)
            }
            """.utf8)
        }

        let withoutFork = try JSONDecoder().decode(
            CmuxVaultAgentRegistration.self,
            from: registrationJSON(forkCommandLine: "")
        )
        XCTAssertNil(withoutFork.forkCommand)

        let withFork = try JSONDecoder().decode(
            CmuxVaultAgentRegistration.self,
            from: registrationJSON(forkCommandLine: ",\n  \"forkCommand\": \"acme --fork {{sessionId}}\"")
        )
        XCTAssertEqual(withFork.forkCommand, "acme --fork {{sessionId}}")

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CmuxVaultAgentRegistration.self,
                from: registrationJSON(forkCommandLine: ",\n  \"forkCommand\": \"acme --fork\"")
            )
        )
    }

    func testCustomRegistrationForkCommandRequiresForkTemplate() {
        func acmeSnapshot(forkTemplate: String?) -> SessionRestorableAgentSnapshot {
            SessionRestorableAgentSnapshot(
                kind: .custom("acme-agent"),
                sessionId: "acme-session-1",
                workingDirectory: "/tmp/acme repo",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: nil,
                    executablePath: "/usr/local/bin/acme",
                    arguments: ["/usr/local/bin/acme"],
                    workingDirectory: "/tmp/acme repo",
                    environment: nil,
                    capturedAt: 123,
                    source: "process"
                ),
                registration: CmuxVaultAgentRegistration(
                    id: "acme-agent",
                    name: "Acme Agent",
                    detect: CmuxVaultAgentDetectRule(processName: "acme"),
                    sessionIdSource: .argvOption("--session"),
                    resumeCommand: "{{executable}} --resume {{sessionId}}",
                    forkCommand: forkTemplate
                )
            )
        }

        XCTAssertNil(acmeSnapshot(forkTemplate: nil).forkCommand)
        XCTAssertEqual(
            acmeSnapshot(forkTemplate: "{{executable}} --branch {{sessionId}}").forkCommand,
            "{ cd -- '/tmp/acme repo' 2>/dev/null || [ ! -d '/tmp/acme repo' ]; } && '/usr/local/bin/acme' '--branch' 'acme-session-1'"
        )

        let hermes = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "hermes-session-1",
            workingDirectory: "/tmp/hermes repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "hermes-agent",
                executablePath: "/usr/local/bin/hermes",
                arguments: ["/usr/local/bin/hermes"],
                workingDirectory: "/tmp/hermes repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
        XCTAssertNil(hermes.forkCommand)
    }
}
